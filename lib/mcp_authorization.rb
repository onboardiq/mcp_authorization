require "mcp"
require_relative "mcp_authorization/version"
require_relative "mcp_authorization/configuration"
require_relative "mcp_authorization/rbs_schema_compiler"
require_relative "mcp_authorization/tool_registry"
require_relative "mcp_authorization/tool"
require_relative "mcp_authorization/engine" if defined?(Rails)

module McpAuthorization
  class << self
    def configure
      yield configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end
    alias_method :config, :configuration
  end
end
