module McpAuthorization
  # Holds gem-wide settings. A single global instance is created lazily by
  # McpAuthorization.configuration and configured in a Rails initializer:
  #
  #   McpAuthorization.configure do |c|
  #     c.server_name      = "my-app"
  #     c.server_version   = MyApp::VERSION
  #     c.tool_paths       = %w[app/mcp]
  #     c.context_builder  = ->(request) { ... }
  #   end
  #
  # == Required settings
  #
  # +context_builder+ must be set before the first MCP request. Everything
  # else has sensible defaults.
  #
  # == The context contract
  #
  # Both +context_builder+ and +cli_context_builder+ must return an object
  # whose +current_user+ responds to:
  #
  #   current_user.can?(:symbol)              # required — gates field/tool visibility
  #   current_user.default_for(:symbol)       # optional — populates @default_for tags
  #
  class Configuration
    # Server name reported in the MCP +initialize+ handshake.
    #: String
    attr_accessor :server_name

    # Server version reported in the MCP +initialize+ handshake.
    #: String
    attr_accessor :server_version

    # Directories (relative to +Rails.root+) that contain tool classes.
    # Added to +autoload_paths+ and +eager_load_paths+ by the Engine.
    #: Array[String]
    attr_accessor :tool_paths

    # Directories (relative to +Rails.root+) where shared +.rbs+ type
    # files live. Used by RbsSchemaCompiler to resolve +# @rbs import+.
    #: Array[String]
    attr_accessor :shared_type_paths

    # Domain name used when the request URL has no +:domain+ segment.
    #: String
    attr_accessor :default_domain

    # URL prefix where the Engine mounts its routes.
    #: String
    attr_accessor :mount_path

    # Lambda that builds a server context from a Rack request.
    # The returned object must satisfy the context contract above.
    #: (^(untyped) -> untyped)?
    attr_accessor :context_builder

    # Lambda that builds a server context for CLI/rake usage.
    # Same duck-type contract as +context_builder+.
    #: (^(domain: String, role: String) -> untyped)?
    attr_accessor :cli_context_builder

    # When true, strips JSON Schema keywords that cause 400 errors in
    # Anthropic's strict tool use mode (minLength, maximum, maxItems, etc.)
    # and adds additionalProperties: false to all objects.
    #: bool
    attr_accessor :strict_schema

    #: () -> void
    def initialize
      @server_name = "mcp-authorization"
      @server_version = "1.0.0"
      @tool_paths = %w[app/mcp]
      @shared_type_paths = %w[sig/shared]
      @default_domain = "default"
      @mount_path = "/mcp"
      @context_builder = nil
      @cli_context_builder = nil
      @strict_schema = false
    end
  end
end
