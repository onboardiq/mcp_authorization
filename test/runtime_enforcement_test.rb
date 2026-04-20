require_relative "test_helper"
require "tmpdir"
require "fileutils"

# Runtime enforcement tests: filter_input and filter_output project values
# against the user's compiled schema so that @requires-gated fields are
# dropped even if the caller sends them anyway (attacker / stale client /
# buggy handler).
class RuntimeEnforcementTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # ---------------------------------------------------------------
  # project_against_schema — the core projection primitive
  # ---------------------------------------------------------------

  def test_object_drops_unknown_keys
    schema = {
      type: "object",
      properties: { a: { type: "string" }, b: { type: "integer" } }
    }
    result = C.send(:project_against_schema, { a: "x", b: 1, c: "leak" }, schema, {})
    assert_equal({ a: "x", b: 1 }, result)
  end

  def test_object_handles_string_keys
    schema = {
      type: "object",
      properties: { a: { type: "string" } }
    }
    result = C.send(:project_against_schema, { "a" => "x", "b" => "drop" }, schema, {})
    assert_equal({ "a" => "x" }, result)
  end

  def test_array_recurses_items
    schema = {
      type: "array",
      items: { type: "object", properties: { keep: { type: "string" } } }
    }
    result = C.send(:project_against_schema, [{ keep: "a", drop: "b" }], schema, {})
    assert_equal([{ keep: "a" }], result)
  end

  def test_one_of_picks_best_matching_variant
    schema = {
      oneOf: [
        { type: "object", properties: { success: { type: "boolean" }, id: { type: "string" } }, required: ["success"] },
        { type: "object", properties: { success: { type: "boolean" }, error: { type: "string" } }, required: ["success"] }
      ]
    }
    success = C.send(:project_against_schema, { success: true, id: "abc", sneaky: "x" }, schema, {})
    assert_equal({ success: true, id: "abc" }, success)

    err = C.send(:project_against_schema, { success: false, error: "nope", sneaky: "x" }, schema, {})
    assert_equal({ success: false, error: "nope" }, err)
  end

  def test_one_of_returns_value_unchanged_when_no_variant_matches
    # Required field missing from all variants — defensive pass-through
    schema = {
      oneOf: [
        { type: "object", properties: { a: { type: "string" } }, required: ["a"] }
      ]
    }
    val = { b: 1 }
    assert_equal val, C.send(:project_against_schema, val, schema, {})
  end

  def test_ref_resolution_via_defs
    defs = { "user" => { type: "object", properties: { name: { type: "string" } } } }
    schema = { "$ref": "#/$defs/user" }
    result = C.send(:project_against_schema, { name: "ada", leak: "x" }, schema, defs)
    assert_equal({ name: "ada" }, result)
  end

  def test_nil_schema_passes_through
    assert_equal({ anything: 1 }, C.send(:project_against_schema, { anything: 1 }, nil, {}))
  end

  def test_primitive_passes_through
    schema = { type: "string" }
    assert_equal "hello", C.send(:project_against_schema, "hello", schema, {})
  end

  # ---------------------------------------------------------------
  # filter_input / filter_output — end-to-end via a real handler
  # ---------------------------------------------------------------

  HANDLER_FIXTURE = <<~RUBY
    class FixtureHandler
      # @rbs type public_result = {
      #   kind: String,
      #   id: String
      # }

      # @rbs type admin_detail = {
      #   kind: String,
      #   secret: String
      # }

      # @rbs type output = public_result
      #                  | admin_detail @requires(:admin)

      #: (
      #:   id: String,
      #:   ?force: bool @requires(:admin)
      #: ) -> Hash[Symbol, untyped]
      def call(id:, force: false)
      end
    end
  RUBY

  def setup_fixture
    @tmpdir = Dir.mktmpdir
    path = File.join(@tmpdir, "fixture_handler.rb")
    File.write(path, HANDLER_FIXTURE)
    load path
    C.reset_cache!
    FixtureHandler
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    Object.send(:remove_const, :FixtureHandler) if Object.const_defined?(:FixtureHandler)
    C.reset_cache!
  end

  def test_filter_input_drops_gated_param_for_unprivileged_user
    handler = setup_fixture

    ctx = StubContext.new([])  # no :admin
    filtered = C.filter_input(handler, { id: "x", force: true }, server_context: ctx)
    assert_equal({ id: "x" }, filtered)
  end

  def test_filter_input_keeps_gated_param_for_privileged_user
    handler = setup_fixture

    ctx = StubContext.new([:admin])
    filtered = C.filter_input(handler, { id: "x", force: true }, server_context: ctx)
    assert_equal({ id: "x", force: true }, filtered)
  end

  def test_filter_input_drops_unknown_keys
    handler = setup_fixture

    ctx = StubContext.new([:admin])
    filtered = C.filter_input(handler, { id: "x", unknown: "leak" }, server_context: ctx)
    assert_equal({ id: "x" }, filtered)
  end

  def test_filter_output_drops_gated_variant_shape
    handler = setup_fixture

    # Non-admin — even if handler erroneously returns admin_detail variant,
    # projection falls back to public variant (the only one visible).
    ctx = StubContext.new([])
    result = C.filter_output(handler, { kind: "admin", secret: "shh", id: "x" }, server_context: ctx)
    # Projected onto public variant { kind, id } — secret is stripped.
    assert_equal({ kind: "admin", id: "x" }, result)
  end

  def test_filter_output_preserves_visible_variant
    handler = setup_fixture

    ctx = StubContext.new([:admin])
    result = C.filter_output(handler, { kind: "admin", secret: "shh" }, server_context: ctx)
    assert_equal({ kind: "admin", secret: "shh" }, result)
  end
end
