require "json"
require "set"

module McpAuthorization
  # Builds grouped facade tools for a faceted domain.
  #
  # A facade is a per-request synthetic MCP::Tool subclass — one per
  # non-empty category — whose description carries routing signal only
  # (group summary + RBAC-filtered tool one-liners) and whose inputSchema
  # defers per-tool argument schemas out of the selection prompt. A
  # +tools/call+ on a facade names the inner tool (+tool_name+) and its
  # +arguments+; dispatch resolves the real tool through
  # ToolRegistry.tool_class_for — re-running +permitted?+ — and delegates
  # to its materialized +call+, so authorization, gating, and input/output
  # filtering apply exactly as if the tool had been called directly.
  #
  # Facades are never registered in ToolRegistry; they are produced on
  # demand by +facades_for+. See docs/designs/tool-grouping-facades.md.
  class FacadeBuilder
    # A tool in a faceted domain declared no +category+ and the domain is
    # configured with +uncategorized: :error+.
    class UncategorizedToolError < StandardError; end

    # A facade's derived name (e.g. "orders_tools") collides with a real
    # registered tool name. Renaming the category is the fix.
    class FacadeNameCollisionError < StandardError; end

    # Fallback group for uncategorized tools (default mode).
    FALLBACK_CATEGORY = :uncategorized #: Symbol

    class << self
      # All facades for a domain, one per non-empty group the caller has at
      # least one permitted tool in. Empty groups produce no facade — which
      # also guarantees no facade ever advertises an empty +enum+.
      #: (domain: String, server_context: untyped) -> Array[singleton(MCP::Tool)]
      def facades_for(domain:, server_context:)
        config = McpAuthorization.config.facet_config(domain)
        return [] unless config

        group_tools(domain, server_context, config).map do |category, tools|
          build_facade(domain, category, tools, server_context, config)
        end
      end

      # A single facade by its tool name (e.g. "orders_tools"), or nil when
      # the name matches no non-empty group for this caller. Used by
      # +tools/call+ routing so one call doesn't build every facade.
      #: (domain: String, name: String, server_context: untyped) -> singleton(MCP::Tool)?
      def facade_for(domain:, name:, server_context:)
        config = McpAuthorization.config.facet_config(domain)
        return nil unless config

        group_tools(domain, server_context, config).each do |category, tools|
          return build_facade(domain, category, tools, server_context, config) if facade_name(category) == name
        end
        nil
      end

      # The MCP tool name a category's facade is exposed under.
      #: (Symbol) -> String
      def facade_name(category)
        "#{category}_tools"
      end

      private

      # Partition the domain's tools into non-empty, RBAC-filtered groups.
      # Ordering is deterministic (by category name) so listings are stable.
      #: (String, untyped, Hash[Symbol, untyped]) -> Array[[Symbol, Array[singleton(McpAuthorization::Tool)]]]
      def group_tools(domain, server_context, config)
        candidates = McpAuthorization::ToolRegistry.tools_by_domain[domain] || []
        permitted = candidates.select { |tc| tc.permitted?(server_context) }

        groups = Hash.new { |h, k| h[k] = [] } #: Hash[Symbol, Array[singleton(McpAuthorization::Tool)]]
        permitted.each do |tool_class|
          category = tool_class._category
          if category.nil?
            if config[:uncategorized] == :error
              raise UncategorizedToolError,
                "#{tool_class} (tool #{tool_class.tool_name.inspect}) has no category, and domain " \
                "#{domain.inspect} is faceted with uncategorized: :error. Declare `category :name` " \
                "on the tool or switch the domain to uncategorized: :fallback."
            end
            category = FALLBACK_CATEGORY
          end
          groups[category] << tool_class
        end

        sorted = groups.sort_by { |category, _| category.to_s }
        sorted.each { |category, _| check_name_collision!(domain, category, candidates) }
        sorted
      end

      # A facade name shadowing a real tool would make that tool
      # unreachable by name in this domain — fail loudly instead.
      #: (String, Symbol, Array[singleton(McpAuthorization::Tool)]) -> void
      def check_name_collision!(domain, category, candidates)
        name = facade_name(category)
        collision = candidates.find { |tc| tc.tool_name == name }
        return unless collision

        raise FacadeNameCollisionError,
          "facade name #{name.inspect} for category #{category.inspect} collides with registered " \
          "tool #{collision} in domain #{domain.inspect}. Rename the category or the tool."
      end

      # Build the synthetic MCP::Tool subclass for one group, with this
      # caller's description, schema, and dispatch baked in — the same
      # materialization shape Tool.materialize_for uses for real tools.
      #: (String, Symbol, Array[singleton(McpAuthorization::Tool)], untyped, Hash[Symbol, untyped]) -> singleton(MCP::Tool)
      def build_facade(domain, category, tools, server_context, config)
        name = facade_name(category)
        desc = facade_description(category, tools, server_context)
        strategy = resolve_strategy(config, tools)
        schema = facade_input_schema(tools, server_context, strategy)
        schema = McpAuthorization::RbsSchemaCompiler.strict_sanitize(schema) if McpAuthorization.config.strict_schema

        # :vendor_extension ships the per-tool argument schemas out-of-band on
        # the facade's `_meta` — the MCP-sanctioned extension channel — rather
        # than as a non-standard key inside `inputSchema`. Client SDKs preserve
        # `_meta` but strip (or, when strict, reject) unknown JSON Schema
        # keywords, and `_meta` is never forwarded to the model as the tool's
        # input_schema. So the listing stays valid for strict Zod clients and
        # strict-mode LLM tool-calling while still carrying the schemas in-band
        # for capable clients.
        meta_payload = strategy == :vendor_extension ? { "tool-input-schemas" => child_schema_map(tools, server_context) } : nil

        advertised = tools.map(&:tool_name).to_set
        builder = self
        ctx = server_context

        Class.new(MCP::Tool) do
          tool_name name
          description desc
          input_schema schema
          meta(meta_payload) if meta_payload

          define_singleton_method(:call) do |server_context: nil, **params|
            builder.send(:dispatch, domain, advertised, params, server_context || ctx)
          end
        end
      end

      # Routing-only description: group summary + one line per tool the
      # caller may invoke. No argument schemas — those are deferred into
      # the inputSchema per the domain's schema strategy.
      #: (Symbol, Array[singleton(McpAuthorization::Tool)], untyped) -> String
      def facade_description(category, tools, server_context)
        summary = McpAuthorization.config.category_summary(category) ||
                  tools.filter_map(&:_category_summary).first ||
                  "Tools in the #{category} group."

        lines = tools.map do |tool_class|
          one_liner = tool_class.dynamic_description(server_context: server_context)
                                .to_s.lines.first.to_s.strip
          "- #{tool_class.tool_name} — #{one_liner}"
        end

        <<~DESC.strip
          #{summary}

          Available tools (pass one as `tool_name`):
          #{lines.join("\n")}
        DESC
      end

      # The facade inputSchema for the configured strategy. All three keep
      # per-tool schemas out of the description and advertise only tools the
      # caller may invoke; they differ in where argument schemas live.
      #: (Array[singleton(McpAuthorization::Tool)], untyped, Symbol) -> Hash[Symbol, untyped]
      def facade_input_schema(tools, server_context, strategy)
        names = tools.map(&:tool_name)

        case strategy
        when :discriminated_union
          # Native JSON Schema; per-tool argument validation for free. Some
          # strict tool-calling stacks reject a top-level oneOf — which is
          # why this is selectable rather than the default.
          {
            oneOf: tools.map do |tool_class|
              {
                type: "object",
                properties: {
                  tool_name: { type: "string", const: tool_class.tool_name },
                  arguments: tool_class.dynamic_input_schema(server_context: server_context)
                },
                required: %w[tool_name arguments]
              }
            end
          }
        else # :vendor_extension (default) and :lazy
          # Standards-clean: a plain enum + permissive arguments object, with
          # NO non-standard keys — valid for strict Zod clients and strict-mode
          # LLM tool-calling. :vendor_extension additionally ships the per-tool
          # schemas on the facade's `_meta` (see build_facade); :lazy ships
          # nothing and relies on dispatch-time filter_input to enforce shapes.
          arguments_description =
            if strategy == :vendor_extension
              'Arguments for the chosen tool; per-tool schemas are in this tool\'s _meta under "tool-input-schemas".'
            else
              "Arguments for the chosen tool."
            end
          {
            type: "object",
            properties: {
              tool_name: { type: "string", enum: names },
              arguments: {
                type: "object",
                description: arguments_description
              }
            },
            required: %w[tool_name arguments]
          }
        end
      end

      # Resolve the configured strategy to a concrete one for THIS group.
      # `:auto` keeps small groups rich (`:discriminated_union` — per-tool
      # schemas inline and correlated to `tool_name`, which the model can use
      # without the client expanding `_meta`, at trivial size for a few
      # branches) and large groups compact (`:vendor_extension` — schemas on
      # `_meta`, so a big group doesn't inflate the listing with a large
      # `oneOf`). The cutoff is `auto_threshold` (tool count).
      #: (Hash[Symbol, untyped], Array[singleton(McpAuthorization::Tool)]) -> Symbol
      def resolve_strategy(config, tools)
        strategy = config[:schema_strategy]
        return strategy unless strategy == :auto

        tools.length <= config[:auto_threshold] ? :discriminated_union : :vendor_extension
      end

      # Per-tool compiled input schemas keyed by tool_name, filtered for this
      # caller. Shipped on the facade's `_meta` by the :vendor_extension
      # strategy so the argument shapes travel with the listing without a
      # non-standard key inside `inputSchema`.
      #: (Array[singleton(McpAuthorization::Tool)], untyped) -> Hash[String, untyped]
      def child_schema_map(tools, server_context)
        tools.each_with_object({}) do |tool_class, map|
          map[tool_class.tool_name] = tool_class.dynamic_input_schema(server_context: server_context)
        end
      end

      # Dispatch a facade call to the real tool.
      #
      # 1. tool_name must be in the set advertised to *this* caller.
      # 2. tool_class_for re-runs permitted?, so gating is enforced at
      #    dispatch even if the advertised set were stale.
      # 3. Arguments are coerced against the *target* tool's schema
      #    (JSON-string blobs parsed) before delegation; the target's own
      #    materialized call then applies filter_input / filter_output —
      #    the same code path as a direct call.
      #: (String, Set[String], Hash[Symbol, untyped], untyped) -> untyped
      def dispatch(domain, advertised, params, server_context)
        tool_name = (params[:tool_name] || params["tool_name"]).to_s
        unless advertised.include?(tool_name)
          raise ArgumentError,
            "unknown tool_name #{tool_name.inspect}; expected one of #{advertised.to_a.sort.inspect}"
        end

        candidates = McpAuthorization::ToolRegistry.tools_by_domain[domain] || []
        original = candidates.find { |tc| tc.tool_name == tool_name }
        target = McpAuthorization::ToolRegistry.tool_class_for(
          domain: domain, name: tool_name, server_context: server_context
        )
        raise McpAuthorization::Tool::NotAuthorizedError unless original && target

        arguments = coerce_arguments(original, params[:arguments] || params["arguments"], server_context)
        target.call(server_context: server_context, **arguments)
      end

      # Coerce a facade's +arguments+ blob against the target tool's
      # compiled input schema. MCP clients frequently serialize nested
      # objects as JSON strings; the facade's own contract only knows
      # `arguments: object`, so string blobs are parsed here — both the
      # blob itself and any top-level value whose target type is an object
      # or array. Unknown / permission-gated fields are then stripped by
      # the target's filter_input as in a direct call.
      #: (singleton(McpAuthorization::Tool), untyped, untyped) -> Hash[Symbol, untyped]
      def coerce_arguments(tool_class, raw, server_context)
        parsed = raw.is_a?(String) ? parse_json_blob(raw, "arguments") : raw
        return {} unless parsed.is_a?(Hash)

        schema = tool_class.dynamic_input_schema(server_context: server_context)
        properties = schema.is_a?(Hash) ? (schema[:properties] || schema["properties"] || {}) : {}

        parsed.each_with_object({}) do |(key, value), out|
          sym = key.to_sym
          expected = properties[sym] || properties[key.to_s] || {}
          expected_type = expected[:type] || expected["type"]
          if value.is_a?(String) && %w[object array].include?(expected_type.to_s)
            value = parse_json_blob(value, sym)
          end
          out[sym] = value
        end
      end

      #: (String, untyped) -> untyped
      def parse_json_blob(string, field)
        JSON.parse(string)
      rescue JSON::ParserError => e
        raise ArgumentError, "#{field} was sent as a string but is not valid JSON: #{e.message}"
      end
    end
  end
end
