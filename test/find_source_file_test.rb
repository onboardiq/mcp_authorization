require_relative "test_helper"
require "tempfile"

# Tests that find_source_file resolves to the handler's own source even when
# the host application wraps #call via prepended modules (param coercion,
# instrumentation, error mapping, ActiveSupport::Concern patterns,
# observability/tracing libraries that wrap method dispatch).
class FindSourceFileTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def setup
    C.reset_cache!
    @tmpfile = Tempfile.new(["handler", ".rb"])
    @tmpfile.write(<<~RUBY)
      # @rbs type success = { ok: bool }
      # @rbs type output = success

      class FindSourceFileHandler
        #: (name: String) -> output
        def call(name:)
          { ok: true }
        end
      end
    RUBY
    @tmpfile.flush
    load @tmpfile.path
    @handler = Object.const_get(:FindSourceFileHandler)
  end

  def teardown
    @tmpfile.close
    @tmpfile.unlink
    Object.send(:remove_const, :FindSourceFileHandler) if Object.const_defined?(:FindSourceFileHandler)
    Object.send(:remove_const, :CallWrapper) if Object.const_defined?(:CallWrapper)
  end

  def test_returns_handler_source_when_unprepended
    assert_equal @tmpfile.path, C.send(:find_source_file, @handler)
  end

  def test_walks_past_prepended_module
    Object.const_set(:CallWrapper, Module.new {
      def call(**kwargs)
        super
      end
    })
    @handler.prepend(CallWrapper)

    # Sanity: the topmost source_location now points at this test file (where
    # CallWrapper is defined), not the handler's tempfile.
    refute_equal @tmpfile.path,
      @handler.instance_method(:call).source_location&.first,
      "precondition: prepend must change the topmost source_location"

    # find_source_file should walk past the prepended module.
    assert_equal @tmpfile.path, C.send(:find_source_file, @handler)
  end

  def test_walks_past_multiple_prepended_modules
    Object.const_set(:CallWrapper, Module.new {
      def call(**kwargs)
        super
      end
    })
    second_wrapper = Module.new {
      def call(**kwargs)
        super
      end
    }
    @handler.prepend(CallWrapper)
    @handler.prepend(second_wrapper)

    assert_equal @tmpfile.path, C.send(:find_source_file, @handler)
  end

  def test_build_cache_finds_annotations_through_prepend
    Object.const_set(:CallWrapper, Module.new {
      def call(**kwargs)
        super
      end
    })
    @handler.prepend(CallWrapper)

    cached = C.send(:build_cache, @handler)
    assert_equal @tmpfile.path, cached[:source_file]
    refute_nil cached[:raw_output], "should parse output type annotation from handler source"
    assert_equal :union, cached[:raw_output][:kind]
    refute_empty cached[:call_params], "should parse #: annotation from handler source"
    assert_equal "name", cached[:call_params].first[:name]
  end
end
