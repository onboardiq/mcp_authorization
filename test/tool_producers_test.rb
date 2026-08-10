require_relative "test_helper"

# Tests for config.tool_producers (issue #35): a supported seam for tool
# classes the host generates at runtime instead of defining in a file under
# tool_paths.
#
# The registry is process-global and shared with every other test file, so
# each test snapshots and restores both @registered_tools and the configured
# producers rather than calling reset! on a registry other files have already
# populated.
#
# Producers here register plain Class objects, not Tool subclasses: Tool's
# inherited hook registers on definition, which would pollute the shared
# registry before the producer ever runs and hide the behavior under test.
class ToolProducersTest < Minitest::Test
  R = McpAuthorization::ToolRegistry

  def setup
    @saved_tools = R.instance_variable_get(:@registered_tools)&.dup
    @saved_producers = McpAuthorization.config.tool_producers
    R.instance_variable_set(:@registered_tools, [])
    R.instance_variable_set(:@loading_tools, false)
  end

  def teardown
    McpAuthorization.config.tool_producers = @saved_producers
    R.instance_variable_set(:@registered_tools, @saved_tools)
    R.instance_variable_set(:@loading_tools, false)
  end

  def generated_tool(name)
    Class.new do
      define_singleton_method(:tool_name) { name }
      define_singleton_method(:_tags) { ["generated"] }
    end
  end

  def test_defaults_to_no_producers
    assert_equal [], McpAuthorization::Configuration.new.tool_producers
  end

  def test_producer_output_appears_in_the_registry
    tool = generated_tool("generated_widget")
    McpAuthorization.config.tool_producers = [-> { R.register(tool) }]

    assert_includes R.registered_tools, tool
    assert_equal tool, R.find_tool("generated_widget")
  end

  # The ordering that makes the seam safe: tool_paths is eager-loaded before a
  # producer can make the registry non-empty. A host registering first would
  # trip ensure_tools_loaded!'s `return if @registered_tools&.any?` guard and
  # silently suppress the load of every file-defined tool.
  def test_eager_loads_tool_paths_before_running_producers
    order = []
    McpAuthorization.config.tool_producers = [-> { order << :producer }]

    with_tool_paths_spy(-> { order << :tool_paths }) { R.ensure_tools_loaded! }

    assert_equal %i[tool_paths producer], order
  end

  # Swaps the private tool_paths loader for the duration of a block and puts
  # the real one back. $VERBOSE is silenced around both swaps: redefining a
  # method Ruby already knows about warns, and `rake test` runs warnings on.
  def with_tool_paths_spy(spy)
    original = R.singleton_class.instance_method(:eager_load_tool_paths!)
    was_verbose = $VERBOSE
    $VERBOSE = nil
    R.define_singleton_method(:eager_load_tool_paths!) { spy.call }
    $VERBOSE = was_verbose
    yield
  ensure
    $VERBOSE = nil
    R.singleton_class.send(:define_method, :eager_load_tool_paths!, original)
    R.singleton_class.send(:private, :eager_load_tool_paths!)
    $VERBOSE = was_verbose
  end

  # Producers are not behind the autoloader's Rails guard — that guard belongs
  # to the tool_paths load, and a producer is host code that may need no
  # autoloader at all. This test process is exactly that case: a bare `Rails`
  # module with no `.root`, which the guard has to survive.
  def test_producers_run_when_the_tool_paths_load_is_skipped
    ran = false
    McpAuthorization.config.tool_producers = [-> { ran = true }]

    R.ensure_tools_loaded!

    assert ran
  end

  # Same contract the tool_paths load has always had: a non-empty registry
  # means loading already happened.
  def test_producers_do_not_run_when_the_registry_is_already_populated
    calls = 0
    McpAuthorization.config.tool_producers = [-> { calls += 1 }]
    R.register(generated_tool("pre_existing"))

    R.ensure_tools_loaded!
    R.registered_tools

    assert_equal 0, calls
  end

  # The Engine resets the registry on every code reload; generated tools have
  # to come back with the file-defined ones.
  def test_producers_re_run_after_reset
    calls = 0
    McpAuthorization.config.tool_producers = [-> { calls += 1; R.register(generated_tool("regenerated")) }]

    R.registered_tools
    assert_equal 1, calls

    R.reset!
    R.registered_tools

    assert_equal 2, calls
  end

  def test_every_producer_runs
    ran = []
    McpAuthorization.config.tool_producers = [-> { ran << :first }, -> { ran << :second }]

    R.ensure_tools_loaded!

    assert_equal %i[first second], ran
  end

  # A producer may want to see what is already registered (to skip tools a
  # file already defines, say). On a still-empty registry that read re-enters
  # ensure_tools_loaded!, which would recurse without the guard.
  def test_a_producer_may_read_the_registry_without_recursing
    calls = 0
    McpAuthorization.config.tool_producers = [lambda {
      calls += 1
      R.registered_tools
      R.register(generated_tool("reentrant"))
    }]

    R.registered_tools

    assert_equal 1, calls
    assert_equal "reentrant", R.find_tool("reentrant").tool_name
  end

  # A malformed generated tool should fail the read loudly, not disappear.
  def test_producer_exceptions_propagate
    McpAuthorization.config.tool_producers = [-> { raise ArgumentError, "bad wrapper" }]

    error = assert_raises(ArgumentError) { R.registered_tools }
    assert_equal "bad wrapper", error.message
  end

  # A raising producer must not wedge the registry: the guard has to be
  # cleared on the way out, or every later read silently returns empty.
  def test_a_raising_producer_leaves_the_registry_readable
    McpAuthorization.config.tool_producers = [-> { raise ArgumentError, "bad wrapper" }]
    assert_raises(ArgumentError) { R.registered_tools }

    tool = generated_tool("recovered")
    McpAuthorization.config.tool_producers = [-> { R.register(tool) }]

    assert_includes R.registered_tools, tool
  end
end
