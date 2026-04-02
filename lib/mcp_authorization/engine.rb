module McpAuthorization
  # Rails Engine that wires the gem into a host application.
  #
  # The engine handles three things automatically so the host app doesn't
  # have to:
  #
  # 1. *Autoload paths* — tool directories (default +app/mcp+) are added to
  #    the Rails autoloader so tool and handler classes are discovered
  #    without explicit requires.
  #
  # 2. *Cache invalidation* — on code reload (development mode) the
  #    ToolRegistry and RbsSchemaCompiler caches are cleared. Tools
  #    re-register themselves via the +inherited+ hook when their classes
  #    are reloaded.
  #
  # 3. *Route mounting* — MCP endpoints are prepended to the host app's
  #    router at +config.mount_path+ (default +/mcp+). The routes support
  #    multi-domain routing via an optional +:domain+ segment:
  #
  #      POST /mcp              → default domain
  #      POST /mcp/operator     → "operator" domain
  #      POST /mcp/recruiting   → "recruiting" domain
  #
  #    All three HTTP methods required by the MCP StreamableHTTP transport
  #    (GET, POST, DELETE) are accepted.
  #
  class Engine < ::Rails::Engine
    isolate_namespace McpAuthorization

    # Add configured tool_paths to the Rails autoloader so tool classes
    # (and their handler classes) are discovered without manual requires.
    initializer "mcp_authorization.autoload_paths", before: :set_autoload_paths do |app|
      McpAuthorization.config.tool_paths.each do |path|
        full_path = Rails.root.join(path).to_s
        if File.directory?(full_path)
          app.config.autoload_paths << full_path
          app.config.eager_load_paths << full_path
        end
      end
    end

    # Clear caches on code reload so stale class references and parsed
    # schemas are dropped. Tools re-register via the inherited hook when
    # their classes are reloaded by Zeitwerk.
    initializer "mcp_authorization.reloader" do |app|
      app.reloader.to_prepare do
        McpAuthorization::ToolRegistry.reset!
        McpAuthorization::RbsSchemaCompiler.reset_cache!
      end
    end

    # Prepend MCP routes into the host app's router. Uses +prepend+ so the
    # MCP endpoint is available before any catch-all routes the host may
    # define. Supports both domain-scoped and bare paths.
    initializer "mcp_authorization.routes", before: :finisher_hook do |app|
      default_domain = McpAuthorization.config.default_domain
      mount_path = McpAuthorization.config.mount_path

      app.routes.prepend do
        scope mount_path, module: :mcp_authorization do
          match ":domain", to: "mcp#handle", via: [ :get, :post, :delete ]
          match "/", to: "mcp#handle", via: [ :get, :post, :delete ],
                defaults: { domain: default_domain }
        end
      end
    end
  end
end
