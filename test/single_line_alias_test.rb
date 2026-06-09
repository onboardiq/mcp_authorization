require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Regression: a record alias written on a single line —
# `# @rbs type ok = { a: String, b: Integer }` — must be collected into
# the type map just like its multi-line equivalent. Before the fix,
# `collect_inline_aliases` truncated the body to a bare `{` and only the
# closing brace on a *following* line ever balanced it, so single-line
# records were silently dropped: any union/field referencing one resolved
# to the bare `{type: "object"}` fallback (no properties, no gating).
class SingleLineAliasTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def resolve(node, schema)
    return node unless node.is_a?(Hash)
    ref = node[:"$ref"] || node["$ref"]
    return node unless ref
    name = ref.to_s.split("/").last
    (schema[:"$defs"] || {})[name.to_sym] || (schema[:"$defs"] || {})[name] || node
  end

  def test_single_line_record_alias_resolves_in_output_union
    handler = build_handler(<<~SRC)
      # @rbs type success = { ok: true, total: Integer }
      # @rbs type error   = { ok: false, message: String }
      class <%= klass_name %>
        #: (?q: String?) -> untyped
        def call(**); end
      end
      # @rbs type output = success | error
    SRC

    schema = C.compile_output(handler, server_context: StubContext.new([]))
    variants = schema[:oneOf].map { |v| resolve(v, schema) }
    success = variants.find { |v| v.dig(:properties, :total) }

    refute_nil success, "single-line `success` record must resolve to its fields, not a bare object"
    assert_equal "integer", success.dig(:properties, :total, :type)
    assert success.dig(:properties, :ok, :const), "literal `true` should compile to a const"
  end

  def test_single_line_alias_equivalent_to_multiline
    single = build_handler(<<~SRC)
      # @rbs type row = { id: String, count: Integer }
      class <%= klass_name %>
        #: (rows: Array[row]) -> untyped
        def call(**); end
      end
    SRC

    multi = build_handler(<<~SRC)
      # @rbs type row = {
      #   id: String,
      #   count: Integer
      # }
      class <%= klass_name %>
        #: (rows: Array[row]) -> untyped
        def call(**); end
      end
    SRC

    ctx = StubContext.new([])
    s = C.compile_input(single, server_context: ctx)
    m = C.compile_input(multi, server_context: ctx)
    item_s = resolve(s.dig(:properties, :rows, :items), s)
    item_m = resolve(m.dig(:properties, :rows, :items), m)

    assert_equal item_m[:properties], item_s[:properties],
      "single-line and multi-line record aliases must compile to the same shape"
    assert item_s[:properties].key?(:count), "single-line alias field must be present"
  end

  def test_single_line_alias_carries_per_member_gating_tag
    # A single-line variant carrying a variant-level @requires must gate
    # per request, exactly as the multi-line form does.
    handler = build_handler(<<~SRC)
      # @rbs type pii = { id: String, email: String }
      # @rbs type plain = { id: String }
      class <%= klass_name %>
        #: (?q: String?) -> untyped
        def call(**); end
      end
      # @rbs type output = pii @requires(:view_pii) | plain
    SRC

    denied  = C.compile_output(handler, server_context: StubContext.new([]))
    granted = C.compile_output(handler, server_context: StubContext.new([:view_pii]))

    # Denied: only `plain` survives, so the union collapses to that single
    # record (no oneOf wrapper). Granted: both variants are present.
    denied_variants  = denied[:oneOf]  || [denied]
    granted_variants = granted[:oneOf] || [granted]

    assert_equal 1, denied_variants.size, "gated variant must be dropped for denied user"
    refute denied_variants.first.dig(:properties, :email),
      "denied user must not see the PII variant's fields"
    assert_equal 2, granted_variants.size, "gated variant must appear for granted user"
  end

  def test_column_aligned_aliases_resolve
    # Authors often pad `=` to align a block of aliases. The padding must
    # not stop the alias from being collected.
    handler = build_handler(<<~SRC)
      # @rbs type ok      = { success: true, total: Integer }
      # @rbs type failure = { success: false, message: String }
      class <%= klass_name %>
        #: (?q: String?) -> untyped
        def call(**); end
      end
      # @rbs type output = ok | failure
    SRC

    schema = C.compile_output(handler, server_context: StubContext.new([]))
    variants = schema[:oneOf].map { |v| resolve(v, schema) }
    ok = variants.find { |v| v.dig(:properties, :total) }

    refute_nil ok, "column-aligned `ok` alias must resolve to its fields"
    assert_equal "integer", ok.dig(:properties, :total, :type)
  end

  def build_handler(template)
    klass_name = "SingleLineAliasHandler_#{self.class.next_serial}"
    src = template.gsub("<%= klass_name %>", klass_name)
    dir = File.join(Dir.tmpdir, "mcp_auth_single_line_#{Process.pid}")
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
