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
    @saved_loaded = R.instance_variable_get(:@tools_loaded)
    @saved_producers = McpAuthorization.config.tool_producers
    R.instance_variable_set(:@registered_tools, [])
    R.instance_variable_set(:@loading_tools, false)
    R.instance_variable_set(:@tools_loaded, false)
  end

  def teardown
    McpAuthorization.config.tool_producers = @saved_producers
    R.instance_variable_set(:@registered_tools, @saved_tools)
    R.instance_variable_set(:@loading_tools, false)
    R.instance_variable_set(:@tools_loaded, @saved_loaded)
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

  # The ordering that makes the seam safe: tool_paths is eager-loaded before any
  # producer runs, so a host cannot register a generated tool ahead of the
  # file-defined ones.
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

  # Loading is not repeated once it has completed.
  def test_a_completed_load_is_not_repeated
    calls = 0
    McpAuthorization.config.tool_producers = [-> { calls += 1 }]

    R.ensure_tools_loaded!
    R.ensure_tools_loaded!
    R.registered_tools

    assert_equal 1, calls
  end

  # "The array has entries" is NOT "loading finished". Guarding on the former
  # would let a host that registers a tool before the first read suppress the
  # tool_paths load entirely — the silent-erasure hazard producers exist to
  # remove. A pre-populated registry must not short-circuit the load.
  def test_a_pre_populated_registry_does_not_suppress_loading
    calls = 0
    McpAuthorization.config.tool_producers = [-> { calls += 1 }]
    R.register(generated_tool("registered_by_hand"))

    R.registered_tools

    assert_equal 1, calls
  end

  # The contract is that a bad producer fails EVERY read until it is fixed.
  # Guarding on a non-empty registry would break this: by the time a producer
  # raises, the file-defined tools are already registered (here, the hand-written
  # stand-in), so the next read would silently no-op and the surface would stay
  # permanently incomplete.
  def test_a_raising_producer_is_retried_on_every_read
    hand_written = generated_tool("hand_written")
    calls = 0
    McpAuthorization.config.tool_producers = [lambda {
      calls += 1
      raise ArgumentError, "bad wrapper"
    }]
    R.register(hand_written) # stands in for the tool_paths eager-load

    assert_raises(ArgumentError) { R.registered_tools }
    assert_equal 1, calls

    assert_raises(ArgumentError) { R.registered_tools }
    assert_equal 2, calls, "a broken producer must be retried, not silently skipped"
  end

  # The partial-failure case with no file-defined tools at all: a producer that
  # registers some of its tools and then raises leaves the registry non-empty
  # from its own work.
  def test_a_partially_succeeding_producer_is_retried
    calls = 0
    McpAuthorization.config.tool_producers = [lambda {
      calls += 1
      R.register(generated_tool("row_1"))
      raise ArgumentError, "row 2 is malformed"
    }]

    assert_raises(ArgumentError) { R.registered_tools }
    assert_raises(ArgumentError) { R.registered_tools }

    assert_equal 2, calls
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

  # A raising producer must not wedge the registry: the reentrancy guard has to
  # be cleared on the way out, or every later read silently returns empty. Seeded
  # with an already-registered tool so the recovery is not an artifact of the
  # registry happening to be empty.
  def test_a_raising_producer_leaves_the_registry_readable
    R.register(generated_tool("hand_written"))
    McpAuthorization.config.tool_producers = [-> { raise ArgumentError, "bad wrapper" }]
    assert_raises(ArgumentError) { R.registered_tools }

    tool = generated_tool("recovered")
    McpAuthorization.config.tool_producers = [-> { R.register(tool) }]

    assert_includes R.registered_tools, tool
  end
end
