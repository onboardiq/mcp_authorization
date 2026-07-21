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

      def meta(value = nil)
        @meta = value if value
        @meta
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
end

# Load the real ToolRegistry (a plain class — no superclass to mismatch).
# Tool's inherited hook registers every subclass here; facade tests exercise
# the real grouping/lookup paths (tools_by_domain, tool_class_for, find_tool).
# Tests that define tools must use per-test-unique domain tags so the shared
# registry never routes one file's tools into another file's assertions.
require_relative "../lib/mcp_authorization/tool_registry"

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

  def initialize(permissions = [], defaults: {}, features: [])
    @current_user = StubUser.new(permissions, defaults: defaults)
    @features = features.map(&:to_s)
  end

  def requires?(flag)
    current_user.can?(flag.to_sym)
  end

  def feature?(flag)
    @features.include?(flag.to_s)
  end
end

# Stub context with a custom predicate (tier?) to test generic metaprogramming path
class StubContextWithTier < StubContext
  def initialize(permissions = [], tier: nil, **kwargs)
    super(permissions, **kwargs)
    @tier = tier
  end

  def tier?(value)
    @tier == value.to_s
  end
end

# Stub context with a predicate that raises, to test error isolation
class StubContextWithBrokenPredicate
  attr_reader :current_user

  def initialize
    @current_user = StubUser.new
  end

  def broken?(_value)
    raise "boom"
  end
end
