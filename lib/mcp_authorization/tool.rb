require_relative "diagnostics"

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
  #     authorization :view_orders     # RBAC permission (legacy, still supported)
  #     gate :feature, :order_tracking # generic predicate gate (any predicate name)
  #     tags "operator", "fulfillment"
  #     read_only!
  #
  #     dynamic_contract Handlers::ListOrders
  #   end
  #
  # Both +authorization+ and any number of +gate+ declarations contribute to
  # visibility — the tool is shown only when every check passes. See
  # +permitted?+ for the resolution order.
  #
  class Tool < MCP::Tool
    class NotAuthorizedError < StandardError; end

    class << self
      #: Symbol?
      attr_reader :_permission

      #: Array[String]?
      attr_reader :_tags

      #: Array[Hash[Symbol, untyped]]?
      attr_reader :_gates

      #: untyped
      attr_reader :_contract_handler

      #: (Class) -> void
      def inherited(subclass)
        super
        McpAuthorization::ToolRegistry.register(subclass)
      end

      # Declare the RBAC permission flag required to see this tool.
      #
      # Convenience alias for +gate :requires, permission+. The generic
      # gate pipeline handles dispatch — calling
      # +server_context.requires?(permission)+ when defined, otherwise
      # falling back to +current_user.can?(permission)+. This mirrors the
      # field-level migration done in 0.3.0 (#12): +@requires+ also went
      # through the generic predicate pipeline rather than carrying its
      # own special-cased branch.
      #
      # +_permission+ remains exposed for introspection — the value is
      # written there as before — but the actual gating goes through the
      # gate list at +permitted?+ time, just like every other check.
      #: (Symbol) -> void
      def authorization(permission)
        @_permission = permission
        gate :requires, permission
      end

      # Declare which MCP domains this tool belongs to.
      #: (*String | Array[String]) -> void
      def tags(*list)
        @_tags = list.flatten
      end

      # Declare a generic predicate gate that must pass for this tool to be
      # visible. The gate calls +server_context.{predicate}?(value)+ at
      # request time. If the predicate returns false, the tool is hidden
      # from +tools/list+ and rejected from +tools/call+.
      #
      # Mirrors the field-level +@predicate(:value)+ system: any predicate
      # name works, as long as the +server_context+ implements
      # +{predicate}?(value)+.
      #
      #   class BulkSendSmsTool < McpAuthorization::Tool
      #     authorization :communications  # RBAC (existing)
      #     gate :feature, :sms            # hide tool unless account has SMS configured
      #     gate :requires, :super_user    # extra RBAC check beyond authorization
      #   end
      #
      # Multiple +gate+ calls AND together — every gate must pass.
      #
      # @param predicate_name [Symbol] Predicate name; resolved to +{predicate_name}?+ on the context.
      # @param value [Symbol, String] Argument passed to the predicate method.
      #: (Symbol, untyped) -> void
      def gate(predicate_name, value)
        (@_gates ||= []) << { name: predicate_name.to_sym, value: value }
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
      #
      # Evaluates every declared gate against the server context. A tool
      # is permitted only when every gate passes. With no gates declared,
      # the tool is unconditionally visible.
      #
      # +authorization :perm+ contributes a +gate :requires, :perm+
      # internally, so it goes through the same pipeline as every other
      # predicate. There is one code path for gating, not two.
      #: (untyped) -> bool
      def permitted?(server_context)
        gates_pass?(server_context)
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
      #
      # Inputs are filtered against the user's compiled input schema before
      # being passed to the handler, and outputs are filtered against the
      # user's compiled output schema before being returned. Fields and
      # variants gated by +@requires+ that the user lacks permission for
      # never reach the handler (in) or cross the wire (out).
      #: (?server_context: untyped?, **untyped) -> untyped
      def call(server_context: nil, **params)
        raise NotAuthorizedError unless server_context && permitted?(server_context)
        filtered = McpAuthorization::RbsSchemaCompiler.filter_input(
          _contract_handler, params, server_context: server_context
        )
        result = handler_instance(server_context).call(**symbolize_keys(filtered))
        McpAuthorization::RbsSchemaCompiler.filter_output(
          _contract_handler, result, server_context: server_context
        )
      end

      # Create an anonymous MCP::Tool subclass with this user's schemas baked in.
      #
      # The materialized +call+ enforces the compiled schema at runtime:
      # input params are stripped of unknown or permission-gated fields
      # before reaching the handler, and the handler's return value is
      # projected onto the user's output schema before being serialized.
      #: (untyped) -> Class?
      def materialize_for(server_context)
        defn = to_mcp_definition(server_context: server_context)
        return nil unless defn

        handler = _contract_handler
        ctx = server_context
        symbolize = method(:symbolize_keys)

        Class.new(MCP::Tool) do
          tool_name defn[:name]
          description defn[:description]
          input_schema defn[:inputSchema]
          output_schema defn[:outputSchema] if defn[:outputSchema]
          annotations(**defn[:annotations]) if defn[:annotations]&.any?

          define_singleton_method(:call) do |server_context: nil, **params|
            effective_ctx = server_context || ctx
            filtered_params = McpAuthorization::RbsSchemaCompiler.filter_input(
              handler, params, server_context: effective_ctx
            )
            raw = handler.new(server_context: effective_ctx).call(**symbolize.call(filtered_params))
            result = McpAuthorization::RbsSchemaCompiler.filter_output(
              handler, raw, server_context: effective_ctx
            )
            response_args = [{ type: "text", text: result.to_json }]
            if defn[:outputSchema]
              MCP::Tool::Response.new(response_args, structured_content: result)
            else
              MCP::Tool::Response.new(response_args)
            end
          end
        end
      end

      # Normalize hash keys to symbols so projection output can be splatted
      # into a handler's kwarg-only +#call+ signature.
      #: (Hash[untyped, untyped]) -> Hash[Symbol, untyped]
      def symbolize_keys(hash)
        return {} unless hash.is_a?(Hash)
        hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
      end

      private

      # Evaluate all declared +gate+ predicates against the server context.
      # Returns true if every gate passes.
      #
      # No gates declared → permissive (tool is public). Gates declared
      # but no server context → deny (a programmer error reaching this
      # method should not silently expose the tool).
      #
      # Symmetric with field-level +RbsSchemaCompiler#predicate_excluded?+:
      # - Unknown predicate (server_context does not implement +{name}?+):
      #   fail-open per-gate (gate passes, tool shown). A warning is
      #   logged in development environments.
      # - +requires+ predicate without a +requires?+ method: backward-compat
      #   fallback to +current_user.can?(value)+.
      # - Predicate raises an exception: fail-open per-gate and log.
      #: (untyped) -> bool
      def gates_pass?(server_context)
        return true if _gates.nil? || _gates.empty?
        return false unless server_context # gates declared + nil context → deny
        _gates.all? { |gate| evaluate_gate(gate, server_context) }
      end

      #: (Hash[Symbol, untyped], untyped) -> bool
      def evaluate_gate(gate, server_context)
        method = :"#{gate[:name]}?"
        if server_context.respond_to?(method)
          !!server_context.public_send(method, gate[:value])
        elsif gate[:name] == :requires && server_context.respond_to?(:current_user)
          # Backward compat: fall back to direct user permission check.
          # Mirrors RbsSchemaCompiler#predicate_excluded? handling for the
          # OpenStruct-style contexts that predate ServerContext.
          !!server_context.current_user&.can?(gate[:value].to_sym)
        else
          warn_unknown_gate(gate[:name], server_context)
          true # Fail-open: show the tool
        end
      rescue StandardError => e
        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.error("[McpAuthorization] tool gate #{gate[:name]}?(#{gate[:value]}) raised: #{e.message}")
        end
        true # Fail-open on error: show the tool
      end

      # Emit a development-mode warning when a gate predicate method is not
      # found on the server context. Delegates to the shared diagnostic
      # helper so the field-level (+@predicate+) and tool-level (+gate+)
      # warning shapes stay in sync.
      #: (Symbol, untyped) -> void
      def warn_unknown_gate(name, server_context)
        McpAuthorization::Diagnostics.warn_unknown_predicate(name, server_context, site: :tool)
      end

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
