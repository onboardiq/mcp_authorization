module McpAuthorization
  class Engine < ::Rails::Engine
    isolate_namespace McpAuthorization

    initializer "mcp_authorization.autoload_paths", before: :set_autoload_paths do |app|
      McpAuthorization.config.tool_paths.each do |path|
        full_path = Rails.root.join(path).to_s
        if File.directory?(full_path)
          app.config.autoload_paths << full_path
          app.config.eager_load_paths << full_path
        end
      end
    end

    # Clear the tool registry on code reload so stale class references
    # are dropped and tools re-register via the inherited hook.
    initializer "mcp_authorization.reloader" do |app|
      app.reloader.to_prepare do
        McpAuthorization::ToolRegistry.reset!
      end
    end

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
