require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "json_schemer"

# A nil-able type admits null in a tool's output, where a handler may return
# nil as its contract says. On input it stays non-null unless the field opts
# in with @nullable(): for an optional param, an explicit null and an omitted
# key are different requests, and most handlers only handle the omission.
class NullableDirectionTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def setup
    @dir = Dir.mktmpdir("mcp_auth_nullable")
    @shared = File.join(@dir, "shared")
    FileUtils.mkdir_p(@shared)
    @prev_paths = McpAuthorization.config.shared_type_paths
    McpAuthorization.config.shared_type_paths = [@shared]
    File.write(File.join(@shared, "note.rbs"), <<~RBS)
      type note = {
        body: String?,
        ?label: String? @nullable(),
        ?owner: { id: String }?
      }
    RBS
  end

  def teardown
    McpAuthorization.config.shared_type_paths = @prev_paths
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    C.reset_cache!
  end

  def test_input_keeps_nilable_params_non_null_and_optional
    handler = load_handler(<<~SRC)
      class <%= klass %>
        #: (?query: String?, ?filter: { id: String } | nil) -> untyped
        def call(**); end
      end
    SRC
    schema = C.compile_input(handler, server_context: ctx)

    assert_valid schema, {}
    assert_valid schema, { query: "abc", filter: { id: "f1" } }
    refute_valid schema, { query: nil }
    refute_valid schema, { filter: nil }
  end

  # `#: (key: T | nil)` is the union spelling of `key: T?`; it must leave the
  # key optional the same way, rather than demand a value the caller lacks.
  def test_union_with_nil_call_param_is_optional_like_the_question_mark_form
    handler = load_handler(<<~SRC)
      class <%= klass %>
        #: (a: String?, b: String | nil, c: String | nil @nullable()) -> untyped
        def call(**); end
      end
    SRC
    schema = C.compile_input(handler, server_context: ctx)

    assert_nil schema[:required]
    assert_valid schema, {}
    assert_valid schema, { b: "x" }
    refute_valid schema, { b: nil }
    assert_valid schema, { c: nil }
  end

  def test_nullable_tag_admits_null_on_that_input_param_only
    handler = load_handler(<<~SRC)
      class <%= klass %>
        #: (?hire_by: String? @nullable() @desc(Pass null to clear), ?page: Integer?) -> untyped
        def call(**); end
      end
    SRC
    schema = C.compile_input(handler, server_context: ctx)

    assert_valid schema, { hire_by: nil }
    assert_valid schema, { hire_by: "2026-12-31" }
    refute_valid schema, { hire_by: 3 }
    refute_valid schema, { page: nil }
    assert_equal "Pass null to clear", schema.dig(:properties, :hire_by, :description)
    refute_includes JSON.generate(schema), "x-mcp-nullable-input"
  end

  def test_shared_type_is_nullable_in_output_and_strict_in_input_except_tagged_fields
    handler = load_handler(<<~SRC)
      # @rbs import note
      class <%= klass %>
        # @rbs type result = { success: true, note: note }
        # @rbs type output = result
        #: (note: note) -> output
        def call(**); end
      end
    SRC
    input = C.compile_input(handler, server_context: ctx)
    output = C.compile_output(handler, server_context: ctx)

    assert_valid output, { success: true, note: { body: nil, label: nil, owner: nil } }
    assert_valid input, { note: { body: "b", label: nil } }
    refute_valid input, { note: { body: nil } }
    refute_valid input, { note: { body: "b", owner: nil } }
    assert_valid input, { note: { body: "b", owner: { id: "o1" } } }
    refute_includes JSON.generate(output), "x-mcp-nullable-input"
  end

  def test_nullable_tag_on_a_non_nilable_type_raises
    handler = load_handler(<<~SRC)
      class <%= klass %>
        #: (?query: String @nullable()) -> untyped
        def call(**); end
      end
    SRC

    error = assert_raises(ArgumentError) { C.compile_input(handler, server_context: ctx) }
    assert_match(/@nullable\(\) needs a nil-able type/, error.message)
  end

  def test_input_projection_still_drops_undeclared_keys_inside_a_tagged_nullable_object
    handler = load_handler(<<~SRC)
      class <%= klass %>
        #: (?owner: { id: String }? @nullable()) -> untyped
        def call(**); end
      end
    SRC

    assert_equal({ owner: { id: "u1" } }, C.filter_input(handler, { owner: { id: "u1", secret: "x" } }, server_context: ctx))
    assert_equal({ owner: nil }, C.filter_input(handler, { owner: nil }, server_context: ctx))
  end

  private

  def load_handler(src)
    klass = "NullableDirHandler#{rand(1_000_000)}"
    path = File.join(@dir, "#{klass.downcase}.rb")
    File.write(path, src.gsub("<%= klass %>", klass))
    load path
    C.reset_cache!
    Object.const_get(klass)
  end

  def ctx
    o = Object.new
    def o.requires?(_) = true
    def o.feature?(_) = true
    def o.hidden?(_) = false
    def o.current_user = nil
    o
  end

  def errors(schema, value)
    JSONSchemer.schema(JSON.parse(JSON.generate(schema))).validate(JSON.parse(JSON.generate(value))).to_a
  end

  def assert_valid(schema, value)
    errs = errors(schema, value)
    assert_empty errs, "expected #{value.inspect} to validate, got: #{errs.map { |e| e["error"] }.join("; ")}"
  end

  def refute_valid(schema, value)
    refute_empty errors(schema, value), "expected #{value.inspect} to be rejected"
  end
end
