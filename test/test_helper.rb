require "minitest/autorun"
require "ostruct"
require_relative "../lib/mcp_authorization/configuration"
require_relative "../lib/mcp_authorization/rbs_schema_compiler"

# Minimum MCP gem surface used by lib/mcp_authorization/tool.rb.
# Defined here (not per-file) so every test file shares one MCP::Tool
# constant — a per-file stub would collide the moment `rake test` loads
# more than one file into the same Ruby process.
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

# Load the real Tool class once. Tests that need to subclass it
# (e.g. materialize_for_test.rb) get the real superclass chain; tests
# that only exercise RbsSchemaCompiler ignore it. Defining a bare
# `class Tool` here would cause a superclass mismatch the moment this
# file is loaded.
require_relative "../lib/mcp_authorization/tool"

class StubUser
  def initialize(permissions = [], defaults: {})
    @permissions = permissions.map(&:to_sym)
    @defaults = defaults
  end

  def can?(flag)
    @permissions.include?(flag.to_sym)
  end

  def default_for(key)
    @defaults[key.to_sym]
  end
end

class StubContext
  attr_reader :current_user

  def initialize(permissions = [], defaults: {})
    @current_user = StubUser.new(permissions, defaults: defaults)
  end
end
