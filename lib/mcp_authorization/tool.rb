module McpAuthorization
  # Base class for MCP tools with schema-shaping authorization.
  #
  # Subclass this instead of MCP::Tool directly. Each subclass is a thin
  # declarative wrapper — the actual business logic lives in a *handler
  # class* (a plain Ruby class that includes DSL) pointed to by
  # +dynamic_contract+.
  #
  # == Defining a tool
  #
  #   class Tools::ListOrders < McpAuthorization::Tool
  #     tool_name "list_orders"
  #     authorization :view_orders
  #     tags "operator", "fulfillment"
  #     read_only!
  #
  #     dynamic_contract Handlers::ListOrders
  #   end
  #
  class Tool < MCP::Tool
    class NotAuthorizedError < StandardError; end

    class << self
      #: Symbol?
      attr_reader :_permission

      #: Array[String]?
      attr_reader :_tags

      #: untyped
      attr_reader :_contract_handler

      #: (Class) -> void
      def inherited(subclass)
        super
        McpAuthorization::ToolRegistry.register(subclass)
      end

      # Declare the permission flag required to see this tool.
      #: (Symbol) -> void
      def authorization(permission)
        @_permission = permission
      end

      # Declare which MCP domains this tool belongs to.
      #: (*String | Array[String]) -> void
      def tags(*list)
        @_tags = list.flatten
      end

      # MCP annotation hint shorthands
      #: () -> void
      def read_only!;       merge_annotations(read_only_hint: true) end
      #: () -> void
      def destructive!;     merge_annotations(destructive_hint: true) end
      #: () -> void
      def not_destructive!; merge_annotations(destructive_hint: false) end
      #: () -> void
      def idempotent!;      merge_annotations(idempotent_hint: true) end
      #: () -> void
      def open_world!;      merge_annotations(open_world_hint: true) end
      #: () -> void
      def closed_world!;    merge_annotations(open_world_hint: false) end

      # Point this tool at its handler class.
      #: (untyped) -> void
      def dynamic_contract(handler_class)
        @_contract_handler = handler_class
        @_contract_validated = false
      end

      # Build the tool description for this user.
      #: (server_context: untyped) -> String
      def dynamic_description(server_context:)
        handler_instance(server_context).description
      end

      # Compile the input JSON Schema for this user.
      #: (server_context: untyped) -> Hash[Symbol, untyped]
      def dynamic_input_schema(server_context:)
        McpAuthorization::RbsSchemaCompiler.compile_input(
          _contract_handler,
          server_context: server_context
        )
      end

      # Compile the output JSON Schema for this user.
      #: (server_context: untyped) -> Hash[Symbol, untyped]?
      def dynamic_output_schema(server_context:)
        McpAuthorization::RbsSchemaCompiler.compile_output(
          _contract_handler,
          server_context: server_context
        )
      end

      # Check whether the current user is allowed to see this tool.
      #: (untyped) -> bool
      def permitted?(server_context)
        return true if _permission.nil?
        server_context.current_user.can?(_permission)
      end

      # Build the full MCP tool definition hash for +tools/list+.
      # Returns nil if the user is not permitted.
      #: (server_context: untyped) -> Hash[Symbol, untyped]?
      def to_mcp_definition(server_context:)
        return nil unless permitted?(server_context)
        validate_contract!(_contract_handler) unless @_contract_validated
        @_contract_validated = true

        {
          name: tool_name,
          description: dynamic_description(server_context: server_context),
          inputSchema: dynamic_input_schema(server_context: server_context),
          outputSchema: dynamic_output_schema(server_context: server_context),
          annotations: @_annotations_hash || {}
        }
      end

      # Execute the tool by delegating to the handler.
      #: (?server_context: untyped?, **untyped) -> untyped
      def call(server_context: nil, **params)
        raise NotAuthorizedError unless server_context && permitted?(server_context)
        handler_instance(server_context).call(**params)
      end

      # Create an anonymous MCP::Tool subclass with this user's schemas baked in.
      #: (untyped) -> Class?
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

          define_singleton_method(:call) do |server_context: nil, **params|
            effective_ctx = server_context || ctx
            result = handler.new(server_context: effective_ctx).call(**params)
            MCP::Tool::Response.new([ { type: "text", text: result.to_json } ])
          end
        end
      end

      private

      #: (**untyped) -> void
      def merge_annotations(**new_hints)
        hints = (@_annotation_hints || {}).merge(new_hints)
        @_annotation_hints = hints
        annotations(**hints)
      end

      #: (untyped) -> untyped
      def handler_instance(server_context)
        _contract_handler.new(server_context: server_context)
      end

      #: (untyped) -> void
      def validate_contract!(handler_class)
        errors = []

        unless handler_class.method_defined?(:call)
          errors << "missing instance method #call"
        end
        unless handler_class.method_defined?(:description)
          errors << "missing instance method #description"
        end

        init = handler_class.instance_method(:initialize) rescue nil
        unless init&.parameters&.any? { |type, name| name == :server_context && type == :keyreq }
          errors << "missing initialize(server_context:)"
        end

        source_file = McpAuthorization::RbsSchemaCompiler.send(:find_source_file, handler_class)
        if source_file && File.exist?(source_file)
          content = File.read(source_file)
          has_input = content.include?("# @rbs type input =")
          has_call_annotation = content.match?(/^\s*#:.*->/m)
          has_output = content.include?("# @rbs type output =")

          unless has_input || has_call_annotation
            errors << "missing input schema (define #: annotation above def call, or # @rbs type input = { ... })"
          end

          unless has_output
            errors << "missing output schema (define # @rbs type output = variant1 | variant2 | ...)"
          end

          if has_output
            begin
              cached = McpAuthorization::RbsSchemaCompiler.send(:cache_for, handler_class)
              if cached[:raw_output]&.dig(:kind) == :union
                primitives = %w[String Integer Float bool true false]
                parts = cached[:raw_output][:body].split("|").map(&:strip).reject(&:empty?)
                parts.each do |part|
                  name = part.gsub(/\s*@\w+\([^)]*\)/, "").strip
                  next if primitives.include?(name)
                  next if cached[:type_map].key?(name)
                  errors << "output variant '#{name}' does not resolve to a defined type (check @rbs type definitions and @rbs import statements)"
                end
              end
            rescue => e
              # Don't fail validation if cache isn't ready
            end
          end
        elsif source_file.nil?
          errors << "could not locate source file (is #call defined?)"
        end

        return if errors.empty?

        raise ArgumentError, <<~MSG
          #{handler_class} does not satisfy the McpAuthorization handler contract.

          Problems:
            #{errors.map { |e| "- #{e}" }.join("\n    ")}

          A handler class should look like:

            class MyHandler
              include McpAuthorization::DSL

              # @rbs type output = success | error

              def description
                "What this tool does"
              end

              #: (name: String, ?force: bool @requires(:admin)) -> Hash[Symbol, untyped]
              def call(name:, force: false)
                # ...
              end
            end
        MSG
      end
    end
  end
end
