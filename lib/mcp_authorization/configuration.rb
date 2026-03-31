module McpAuthorization
  class Configuration
    # Name and version reported in MCP server handshake
    attr_accessor :server_name, :server_version

    # Paths (relative to Rails.root) where tool classes live
    attr_accessor :tool_paths

    # Default domain when no :domain param is present
    attr_accessor :default_domain

    # Mount path for the engine (used by rake tasks to build URLs)
    attr_accessor :mount_path

    # Lambda: (request) -> context
    # The returned object must respond to .current_user, which must respond to .can?(symbol)
    attr_accessor :context_builder

    # Lambda: (domain:, role:) -> context (same duck type, used by rake tasks)
    attr_accessor :cli_context_builder

    def initialize
      @server_name = "mcp-authorization"
      @server_version = "1.0.0"
      @tool_paths = %w[app/mcp]
      @default_domain = "default"
      @mount_path = "/mcp"
      @context_builder = nil
      @cli_context_builder = nil
    end
  end
end
