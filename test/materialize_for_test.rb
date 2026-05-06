require "minitest/autorun"
require "ostruct"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../lib/mcp_authorization/configuration"
require_relative "../lib/mcp_authorization/rbs_schema_compiler"

# ---------------------------------------------------------------------------
# Minimal MCP gem stubs for testing McpAuthorization::Tool#materialize_for
# without requiring the real MCP gem to be installed.
# ---------------------------------------------------------------------------

module MCP
  class Tool
    class << self
      def tool_name(name = nil)
        @tool_name = name if name
        @tool_name
      end

      def description(desc = nil)
        @description = desc if desc
        @description
      end

      def input_schema(schema = nil)
        @input_schema = schema if schema
        @input_schema
      end

      def output_schema(schema = nil)
        @output_schema = schema if schema
        @output_schema
      end

      def annotations(**hints)
        @annotations = hints
      end
    end

    # Records the arguments it was called with for test inspection.
    class Response
      attr_reader :content, :structured_content

      def initialize(content, structured_content: nil)
        @content = content
        @structured_content = structured_content
      end
    end
  end
end

module McpAuthorization
  def self.config
    @config ||= Configuration.new
  end

  module DSL; end

  class ToolRegistry
    def self.register(_); end
  end
end

require_relative "../lib/mcp_authorization/tool"

# ---------------------------------------------------------------------------
# Shared stubs for server context / user
# ---------------------------------------------------------------------------

class StubUser
  def initialize(permissions = [])
    @permissions = permissions.map(&:to_sym)
  end

  def can?(flag)
    @permissions.include?(flag.to_sym)
  end

  def default_for(_); nil; end
end

class StubContext
  attr_reader :current_user

  def initialize(permissions = [])
    @current_user = StubUser.new(permissions)
  end
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

class MaterializeForTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # Handler fixture with an output schema (union of named types as the framework expects)
  HANDLER_WITH_OUTPUT = <<~RUBY
    class FixtureHandlerWithOutput
      # @rbs type result = {
      #   success: bool,
      #   id: String
      # }

      # @rbs type output = result

      def initialize(server_context:)
        @ctx = server_context
      end

      def description
        "A fixture tool with an output schema"
      end

      #: (id: String) -> Hash[Symbol, untyped]
      def call(id:)
        { success: true, id: id }
      end
    end
  RUBY

  def setup
    @tmpdir = Dir.mktmpdir
    C.reset_cache!
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    Object.send(:remove_const, :FixtureHandlerWithOutput) if Object.const_defined?(:FixtureHandlerWithOutput)
    C.reset_cache!
  end

  def load_handler(fixture, filename)
    path = File.join(@tmpdir, filename)
    File.write(path, fixture)
    load path
  end

  def test_structured_content_present_when_output_schema_declared
    load_handler(HANDLER_WITH_OUTPUT, "fixture_handler_with_output.rb")
    handler_class = FixtureHandlerWithOutput

    tool_class = Class.new(McpAuthorization::Tool) do
      tool_name "fixture_with_output"
      dynamic_contract handler_class
    end

    ctx = StubContext.new([:admin])
    materialized = tool_class.materialize_for(ctx)
    refute_nil materialized, "materialize_for should return a class"

    response = materialized.call(server_context: ctx, id: "abc")

    assert_instance_of MCP::Tool::Response, response
    refute_nil response.structured_content,
      "structured_content must be set when the tool has an outputSchema"
    assert_equal true,  response.structured_content[:success]
    assert_equal "abc", response.structured_content[:id]
  end

  # --------------------------------------------------------------------------
  # structured_content payload matches the JSON-serialisable text content
  # --------------------------------------------------------------------------

  def test_structured_content_matches_text_content
    load_handler(HANDLER_WITH_OUTPUT, "fixture_handler_with_output.rb")
    handler_class = FixtureHandlerWithOutput

    tool_class = Class.new(McpAuthorization::Tool) do
      tool_name "fixture_with_output"
      dynamic_contract handler_class
    end

    ctx = StubContext.new([:admin])
    materialized = tool_class.materialize_for(ctx)
    response = materialized.call(server_context: ctx, id: "xyz")

    text_body = response.content.first[:text]
    assert_equal response.structured_content, JSON.parse(text_body, symbolize_names: true)
  end
end
