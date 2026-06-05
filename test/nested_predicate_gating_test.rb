require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Regression tests for issue #23: predicate gating (@requires/@feature/...)
# must recurse into nested record-type aliases, not just the top-level
# fields of a handler's own input/output. Before the fix, a gated field
# inside a `# @rbs type foo = { ... }` referenced as `Array[foo]` (or as a
# nested property) was resolved from the statically-compiled type_map and
# never filtered against server_context — so it leaked into every user's
# schema.
class NestedPredicateGatingTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # Resolve a possibly-$ref'd node against the schema's $defs so assertions
  # don't depend on whether ref injection fired.
  def resolve(node, schema)
    return node unless node.is_a?(Hash)
    ref = node[:"$ref"] || node["$ref"]
    return node unless ref
    name = ref.to_s.split("/").last
    (schema[:"$defs"] || {})[name.to_sym] || (schema[:"$defs"] || {})[name] || node
  end

  # --- Input: nested alias via Array[line_item] (the issue's repro) ---

  def test_nested_record_alias_strips_gated_fields_for_denied_user
    handler = build_handler(<<~SRC)
      # @rbs type line_item = {
      #   label: String,
      #   ?secret_note: String? @requires(:admin),
      #   ?beta_field: String? @feature(:beta_widgets)
      # }
      class <%= klass_name %>
        #: (
        #:   items: Array[line_item],
        #:   ?top_secret: String? @requires(:admin)
        #: ) -> untyped
        def call(**); end
      end
    SRC

    ctx = StubContext.new([], features: [])
    schema = C.compile_input(handler, server_context: ctx)

    refute schema[:properties].key?(:top_secret), "top-level gate should strip top_secret"

    item = resolve(schema.dig(:properties, :items, :items), schema)
    assert item[:properties].key?(:label), "ungated nested field must remain"
    refute item[:properties].key?(:secret_note), "@requires nested field must be stripped"
    refute item[:properties].key?(:beta_field), "@feature nested field must be stripped"
  end

  def test_nested_record_alias_keeps_gated_fields_for_granted_user
    handler = build_handler(<<~SRC)
      # @rbs type line_item = {
      #   label: String,
      #   ?secret_note: String? @requires(:admin),
      #   ?beta_field: String? @feature(:beta_widgets)
      # }
      class <%= klass_name %>
        #: (items: Array[line_item]) -> untyped
        def call(**); end
      end
    SRC

    ctx = StubContext.new([:admin], features: ["beta_widgets"])
    schema = C.compile_input(handler, server_context: ctx)

    item = resolve(schema.dig(:properties, :items, :items), schema)
    assert item[:properties].key?(:secret_note), "granted @requires field must appear"
    assert item[:properties].key?(:beta_field), "granted @feature field must appear"
  end

  # --- Input: nested alias via a record-style `# @rbs type input` ---

  def test_nested_alias_as_property_of_input_record
    handler = build_handler(<<~SRC)
      # @rbs type address = {
      #   city: String,
      #   ?internal_code: String? @requires(:admin)
      # }
      # @rbs type input = {
      #   name: String,
      #   home: address
      # }
      class <%= klass_name %>
        def call(**); end
      end
    SRC

    ctx = StubContext.new([], features: [])
    schema = C.compile_input(handler, server_context: ctx)

    home = resolve(schema.dig(:properties, :home), schema)
    assert home[:properties].key?(:city)
    refute home[:properties].key?(:internal_code), "nested @requires must be stripped one level down"
  end

  # --- Output: nested record inside a union variant ---

  def test_nested_alias_in_output_union_is_filtered
    handler = build_handler(<<~SRC)
      # @rbs type detail = {
      #   id: Integer,
      #   ?audit: String? @requires(:admin)
      # }
      # @rbs type output = detail
      class <%= klass_name %>
        def call(**); end
      end
    SRC

    denied = C.compile_output(handler, server_context: StubContext.new([]))
    refute denied[:properties].key?(:audit), "nested output @requires must be stripped"

    granted = C.compile_output(handler, server_context: StubContext.new([:admin]))
    assert granted[:properties].key?(:audit), "granted nested output field must appear"
  end

  # --- Runtime enforcement projects nested gating too ---

  def test_filter_input_drops_nested_gated_field_at_runtime
    handler = build_handler(<<~SRC)
      # @rbs type line_item = {
      #   label: String,
      #   ?secret_note: String? @requires(:admin)
      # }
      class <%= klass_name %>
        #: (items: Array[line_item]) -> untyped
        def call(**); end
      end
    SRC

    payload = { "items" => [{ "label" => "x", "secret_note" => "leak" }] }
    filtered = C.filter_input(handler, payload, server_context: StubContext.new([]))

    assert_equal [{ "label" => "x" }], filtered["items"]
  end

  # --- Predicate-free aliases still dedupe via $defs (no regression) ---

  def test_predicate_free_alias_still_compiles
    handler = build_handler(<<~SRC)
      # @rbs type point = {
      #   x: Integer,
      #   y: Integer
      # }
      class <%= klass_name %>
        #: (a: point, b: point) -> untyped
        def call(**); end
      end
    SRC

    schema = C.compile_input(handler, server_context: StubContext.new([]))
    a = resolve(schema.dig(:properties, :a), schema)
    assert_equal %i[x y], a[:properties].keys
  end

  # --- Tagged union nested in a record field: per-member gating ---

  def test_tagged_union_field_drops_unavailable_members
    handler = build_handler(<<~SRC)
      # @rbs type alpha = {
      #   type: "Alpha",
      #   a: String
      # }
      # @rbs type beta = {
      #   type: "Beta",
      #   b: String
      # }
      class <%= klass_name %>
        # @rbs type input = {
        #   workflow_id: String,
        #   stage: alpha @stage_ok(Alpha) | beta @stage_ok(Beta)
        # }
        #: (**untyped) -> untyped
        def call(**); end
      end
    SRC

    ctx = Object.new
    def ctx.requires?(_) = true
    def ctx.feature?(_) = true
    def ctx.hidden?(_) = false
    def ctx.current_user = nil
    def ctx.stage_ok?(name) = name.to_s == "Alpha"

    schema = C.compile_input(handler, server_context: ctx)
    stage = resolve(schema.dig(:properties, :stage), schema)
    members = stage[:oneOf] || stage[:anyOf]
    if members
      consts = members.map { |m| resolve(m, schema).dig(:properties, :type, :const) }.compact
      assert_equal ["Alpha"], consts, "only the available member should remain"
    else
      assert_equal "Alpha", stage.dig(:properties, :type, :const),
        "single surviving member should not be wrapped in oneOf"
    end
  end

  def test_tagged_union_field_keeps_all_members_when_all_available
    handler = build_handler(<<~SRC)
      # @rbs type alpha = {
      #   type: "Alpha",
      #   a: String
      # }
      # @rbs type beta = {
      #   type: "Beta",
      #   b: String
      # }
      class <%= klass_name %>
        # @rbs type input = {
        #   workflow_id: String,
        #   stage: alpha @stage_ok(Alpha) | beta @stage_ok(Beta)
        # }
        #: (**untyped) -> untyped
        def call(**); end
      end
    SRC

    ctx = Object.new
    def ctx.requires?(_) = true
    def ctx.feature?(_) = true
    def ctx.hidden?(_) = false
    def ctx.current_user = nil
    def ctx.stage_ok?(_) = true

    schema = C.compile_input(handler, server_context: ctx)
    stage = resolve(schema.dig(:properties, :stage), schema)
    members = stage[:oneOf] || stage[:anyOf]
    consts = members.map { |m| resolve(m, schema).dig(:properties, :type, :const) }.compact.sort
    assert_equal %w[Alpha Beta], consts
  end

  private

  def build_handler(template)
    klass_name = "NestedGatingHandler_#{self.class.next_serial}"
    src = template.gsub("<%= klass_name %>", klass_name)
    dir = File.join(Dir.tmpdir, "mcp_auth_nested_#{Process.pid}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{klass_name.downcase}.rb")
    File.write(path, src)
    load path
    C.reset_cache!
    Object.const_get(klass_name)
  end

  @@serial = 0
  def self.next_serial
    @@serial += 1
  end
end
