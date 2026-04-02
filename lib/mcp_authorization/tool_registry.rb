module McpAuthorization
  # Global registry of all McpAuthorization::Tool subclasses.
  #
  # Tools self-register via the +inherited+ hook in Tool, so there is no
  # manual registration step — defining a class that inherits from Tool is
  # enough.
  #
  # The registry is the entry point for two main operations:
  #
  # * *Listing* — +list_tools+ returns JSON-serialisable tool definitions
  #   filtered by domain and the current user's permissions.
  #
  # * *Materializing* — +tool_classes_for+ returns concrete MCP::Tool
  #   subclasses with per-user schemas baked in, ready to be handed to an
  #   MCP::Server for request handling.
  #
  class ToolRegistry
    class << self
      # Register a tool class. Called automatically by Tool.inherited.
      #: (Class) -> void
      def register(tool_class)
        tools = (@registered_tools ||= [])
        tools << tool_class unless tools.include?(tool_class)
      end

      # All registered tool classes. Triggers eager loading on first access.
      #: () -> Array[singleton(McpAuthorization::Tool)]
      def registered_tools
        tools = (@registered_tools ||= [])
        ensure_tools_loaded! if tools.empty?
        tools
      end

      # Force-loads tool directories so tool classes self-register.
      #: () -> void
      def ensure_tools_loaded!
        return if @registered_tools&.any?
        return unless defined?(Rails)

        McpAuthorization.config.tool_paths.each do |path|
          full_path = Rails.root.join(path)
          Rails.autoloaders.main.eager_load_dir(full_path) if File.directory?(full_path)
        end
      end

      # Groups registered tools by their domain tags.
      #: () -> Hash[String, Array[singleton(McpAuthorization::Tool)]]
      def tools_by_domain
        initial = Hash.new { |h, k| h[k] = [] } #: Hash[String, Array[singleton(McpAuthorization::Tool)]]
        registered_tools.each_with_object(initial) do |tool_class, map|
          (tool_class._tags || ["default"]).each do |tag|
            map[tag] << tool_class
          end
        end
      end

      # Tool definitions for +tools/list+, filtered by domain and permissions.
      #: (domain: String, server_context: untyped) -> Array[Hash[Symbol, untyped]]
      def list_tools(domain:, server_context:)
        candidates = tools_by_domain[domain] || []
        candidates.filter_map do |tool_class|
          tool_class.to_mcp_definition(server_context: server_context)
        end
      end

      # Concrete MCP::Tool subclasses with per-user schemas baked in.
      #: (domain: String, server_context: untyped) -> Array[singleton(MCP::Tool)]
      def tool_classes_for(domain:, server_context:)
        candidates = tools_by_domain[domain] || []
        candidates.filter_map do |tool_class|
          next unless tool_class.permitted?(server_context)
          tool_class.materialize_for(server_context)
        end
      end

      # Look up a tool by its MCP tool name across all domains.
      #: (String) -> singleton(McpAuthorization::Tool)?
      def find_tool(name)
        registered_tools.find { |t| t.tool_name == name }
      end

      # Clear the registry. Called by the Engine's reloader on code change.
      #: () -> void
      def reset!
        @registered_tools = []
      end
    end
  end
end
