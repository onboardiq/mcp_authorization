module McpAuthorization
  class Tool < MCP::Tool
    class NotAuthorizedError < StandardError; end

    class << self
      attr_reader :_permission, :_tags, :_contract_handler

      def inherited(subclass)
        super
        McpAuthorization::ToolRegistry.register(subclass)
      end

      def authorization(permission)
        @_permission = permission
      end

      # Legacy alias
      alias_method :requires_permission, :authorization

      def tags(*list)
        @_tags = list.flatten
      end

      def dynamic_contract(handler_class)
        @_contract_handler = handler_class
      end

      # Resolved per request -- description and schema are never static
      def dynamic_description(server_context:)
        _contract_handler.description(server_context: server_context)
      end

      def dynamic_input_schema(server_context:)
        McpAuthorization::RbsSchemaCompiler.compile_input(
          _contract_handler,
          server_context: server_context
        )
      end

      def dynamic_output_schema(server_context:)
        McpAuthorization::RbsSchemaCompiler.compile_output(
          _contract_handler,
          server_context: server_context
        )
      end

      def permitted?(server_context)
        return true if _permission.nil?
        server_context.current_user.can?(_permission)
      end

      # What list_tools asks each registered tool class
      def to_mcp_definition(server_context:)
        return nil unless permitted?(server_context)

        {
          name: tool_name,
          description: dynamic_description(server_context: server_context),
          inputSchema: dynamic_input_schema(server_context: server_context),
          outputSchema: dynamic_output_schema(server_context: server_context),
          annotations: @_annotations_hash || {}
        }
      end

      # Default execution -- delegate to the handler
      def call(server_context: nil, **params)
        raise NotAuthorizedError unless server_context && permitted?(server_context)
        _contract_handler.call(server_context: server_context, **params)
      end

      # Materialize a concrete MCP::Tool subclass with schemas baked in
      def materialize_for(server_context)
        defn = to_mcp_definition(server_context: server_context)
        return nil unless defn

        handler = _contract_handler
        ctx = server_context

        Class.new(MCP::Tool) do
          tool_name defn[:name]
          description defn[:description]
          input_schema defn[:inputSchema]
          output_schema defn[:outputSchema] if defn[:outputSchema]
          annotations(**defn[:annotations]) if defn[:annotations]&.any?

          define_singleton_method(:call) do |**params|
            result = handler.call(server_context: ctx, **params.except(:server_context))
            MCP::Tool::Response.new([ { type: "text", text: result.to_json } ])
          end
        end
      end
    end
  end
end
