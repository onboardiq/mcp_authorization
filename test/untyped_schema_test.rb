require_relative "test_helper"
require "tmpdir"
require "fileutils"

# Regression tests for issue #22: `untyped` (RBS Bases::Any/Void/Nil) must
# compile to the empty schema {} ("any value"), not {type: "string"}. The
# old mapping silently rejected nested objects/arrays at tools/call — most
# visibly for `Hash[K, untyped]` params, which became
# {type: "object", additionalProperties: {type: "string"}} and forced every
# property value to be a string.
class UntypedSchemaTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def test_bare_untyped_is_empty_schema
    assert_equal({}, C.send(:rbs_type_to_json_schema, "untyped"))
  end

  def test_hash_symbol_untyped_allows_any_value
    schema = C.send(:rbs_type_to_json_schema, "Hash[Symbol, untyped]")
    assert_equal "object", schema[:type]
    assert_equal({}, schema[:additionalProperties], "any property value type allowed")
  end

  def test_array_untyped_items_are_unconstrained
    schema = C.send(:rbs_type_to_json_schema, "Array[untyped]")
    assert_equal "array", schema[:type]
    assert_equal({}, schema[:items])
  end

  # Round-trip: a Hash[Symbol, untyped] param must accept a nested
  # object/array value through the gem's own runtime projection, instead
  # of being emptied before the handler sees it.
  def test_filter_input_preserves_nested_value_under_untyped_hash
    handler = build_handler(<<~SRC)
      class <%= klass_name %>
        #: (rule: Hash[Symbol, untyped]) -> untyped
        def call(**); end
      end
    SRC

    payload = { "rule" => { "conditions" => { "a" => 1 }, "actions" => [1, 2] } }
    filtered = C.filter_input(handler, payload, server_context: StubContext.new([]))

    assert_equal payload, filtered, "nested object/array under untyped hash must pass through"
  end

  # additionalProperties: false (e.g. a @closed record) still drops
  # undeclared keys — the open behavior is only for explicitly-open schemas.
  def test_closed_object_still_drops_undeclared_keys
    schema = { type: "object", properties: { a: { type: "string" } }, additionalProperties: false }
    projected = C.send(:project_against_schema, { "a" => "x", "b" => "y" }, schema, {})
    assert_equal({ "a" => "x" }, projected)
  end

  # A record with no additionalProperties key keeps the closed-by-default
  # projection that enforces @requires gating.
  def test_object_without_additional_properties_drops_undeclared_keys
    schema = { type: "object", properties: { a: { type: "string" } } }
    projected = C.send(:project_against_schema, { "a" => "x", "b" => "y" }, schema, {})
    assert_equal({ "a" => "x" }, projected)
  end

  private

  def build_handler(template)
    klass_name = "UntypedSchemaHandler_#{self.class.next_serial}"
    src = template.gsub("<%= klass_name %>", klass_name)
    dir = File.join(Dir.tmpdir, "mcp_auth_untyped_#{Process.pid}")
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
