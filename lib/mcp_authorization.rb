require "mcp"
require_relative "mcp_authorization/version"
require_relative "mcp_authorization/configuration"
require_relative "mcp_authorization/dsl"
require_relative "mcp_authorization/rbs_schema_compiler"
require_relative "mcp_authorization/tool_registry"
require_relative "mcp_authorization/tool"
require_relative "mcp_authorization/engine" if defined?(Rails)

# MCP Authorization — schema-shaping authorization for MCP tool servers.
#
# Instead of rejecting unauthorized requests after the fact, this gem shapes
# the JSON Schema that each user sees so that fields and output variants they
# are not permitted to use never appear in the schema at all. The LLM (or
# any MCP client) therefore never knows those options exist.
#
# == Quick start (Rails)
#
#   # config/initializers/mcp_authorization.rb
#   McpAuthorization.configure do |c|
#     c.server_name    = "my-app"
#     c.server_version = "1.0.0"
#     c.context_builder = ->(request) {
#       ServerContext.new(current_user: current_user_from(request))
#     }
#   end
#
# == How it works
#
# 1. Tool classes inherit from McpAuthorization::Tool and declare a handler
#    class via +dynamic_contract+.
# 2. Handler classes use +@rbs type+ comments and +#:+ annotations to define
#    input/output schemas. Fields can be tagged with +@requires(:flag)+ to
#    gate them on user permissions.
# 3. On each request the RbsSchemaCompiler compiles a per-user JSON Schema
#    by filtering out fields whose +@requires+ flag the user lacks.
# 4. A fresh set of MCP::Tool subclasses is materialized with the filtered
#    schemas baked in, and handed to a stateless MCP::Server.
#
# See CLAUDE.md for the full architecture walkthrough.
module McpAuthorization
  class << self
    # Yields the global Configuration instance for block-style setup.
    #: () { (Configuration) -> void } -> void
    def configure
      yield configuration
    end

    # Returns the global Configuration instance, creating it with defaults
    # on first access.
    #: () -> Configuration
    def configuration
      @configuration ||= Configuration.new
    end
    alias_method :config, :configuration
  end
end
