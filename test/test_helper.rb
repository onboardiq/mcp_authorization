require "minitest/autorun"
require "ostruct"
require_relative "../lib/mcp_authorization/configuration"
require_relative "../lib/mcp_authorization/rbs_schema_compiler"

# Minimal stubs so the compiler can be tested in isolation without Rails or the MCP gem.

module McpAuthorization
  def self.config
    @config ||= Configuration.new
  end

  module DSL; end

  class Tool
    def self.inherited(_); end
  end

  class ToolRegistry
    def self.register(_); end
  end
end

# Stub user for authorization-filtered compilation
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
