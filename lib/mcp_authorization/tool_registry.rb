module McpAuthorization
  class ToolRegistry
    class << self
      def register(tool_class)
        @registered_tools ||= []
        @registered_tools << tool_class unless @registered_tools.include?(tool_class)
      end

      def registered_tools
        @registered_tools ||= []
        ensure_tools_loaded! if @registered_tools.empty?
        @registered_tools
      end

      def ensure_tools_loaded!
        return if @registered_tools&.any?
        return unless defined?(Rails)

        McpAuthorization.config.tool_paths.each do |path|
          full_path = Rails.root.join(path)
          Rails.autoloaders.main.eager_load_dir(full_path) if File.directory?(full_path)
        end
      end

      # All registered tool classes, keyed by domain tag
      def tools_by_domain
        registered_tools.each_with_object(Hash.new { |h, k| h[k] = [] }) do |tool_class, map|
          (tool_class._tags || ["default"]).each do |tag|
            map[tag] << tool_class
          end
        end
      end

      # Filtered list_tools output for a given domain and server_context
      def list_tools(domain:, server_context:)
        candidates = tools_by_domain[domain] || []
        candidates.filter_map do |tool_class|
          tool_class.to_mcp_definition(server_context: server_context)
        end
      end

      # Return MCP::Tool subclasses materialized for this user's context
      def tool_classes_for(domain:, server_context:)
        candidates = tools_by_domain[domain] || []
        candidates.filter_map do |tool_class|
          next unless tool_class.permitted?(server_context)
          tool_class.materialize_for(server_context)
        end
      end

      # Find a tool by name across all domains
      def find_tool(name)
        registered_tools.find { |t| t.tool_name == name }
      end

      def reset!
        @registered_tools = []
      end
    end
  end
end
