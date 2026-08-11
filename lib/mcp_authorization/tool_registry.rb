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
      #
      # Gated on "loading finished", not on "the array has entries" — see
      # +ensure_tools_loaded!+ for why those must not be conflated.
      #: () -> Array[singleton(McpAuthorization::Tool)]
      def registered_tools
        tools = (@registered_tools ||= [])
        ensure_tools_loaded! unless @tools_loaded
        tools
      end

      # Force-loads tool directories so tool classes self-register, then runs
      # +config.tool_producers+ for tools the host generates at runtime.
      #
      # Deliberately lazy, and the ordering here is the contract:
      #
      # * *Producers run last*, inside this method, so a host cannot register a
      #   generated tool ahead of the +tool_paths+ eager-load and suppress it.
      #
      # * *Producers run on a registry read, never from a boot callback.*
      #   Generating tool classes means loading the code they derive from,
      #   which in a Rails app pulls in a large share of the application. Doing
      #   that from +config.to_prepare+ runs it during +:run_prepare_callbacks+,
      #   which precedes +:eager_load!+ and +:finisher_hook+ — and +config.i18n+
      #   is only copied onto +I18n+ from a railtie-level +after_initialize+.
      #   Application code loaded that early sees an empty +I18n.load_path+, so
      #   any class resolving a translation in its class body freezes
      #   "Translation missing: ..." into validators and option lists
      #   permanently. Deferring to first read sidesteps the whole ordering
      #   question rather than asking each host to solve it.
      #
      # * *Producers re-run after +reset!+.* The Engine resets the registry on
      #   every code reload; the next read repopulates it, producers included.
      #
      # +@tools_loaded+ tracks completion, and is set only after every producer
      # has returned. It deliberately does NOT reuse "is +@registered_tools+
      # non-empty?" as the signal, because a non-empty registry does not mean
      # loading succeeded: +eager_load_tool_paths!+ registers the file-defined
      # tools first, so by the time a producer raises the array is already
      # populated — as it also is when a producer registers 40 tools and raises
      # on the 41st. Guarding on that would make the failure loud exactly once
      # and silent forever after, leaving a permanently incomplete surface. The
      # contract is the opposite: a producer that raises fails *every* read until
      # it is fixed. Re-running is safe — +register+ dedupes by identity and
      # +eager_load_dir+ is a no-op on an already-loaded directory.
      #
      # The reentrancy guard lets a producer call back into the registry (to
      # inspect what is already registered, say) without recursing forever.
      #: () -> void
      def ensure_tools_loaded!
        return if @tools_loaded
        return if @loading_tools

        @loading_tools = true
        begin
          eager_load_tool_paths!
          McpAuthorization.config.tool_producers.each(&:call)
          @tools_loaded = true
        ensure
          @loading_tools = false
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

      # Concrete MCP::Tool subclass for a single named tool within a domain,
      # or nil when the tool is unknown in that domain or the current user is
      # not permitted to use it.
      #
      # Materializing a per-user schema is the dominant cost of handling an MCP
      # request, so a +tools/call+ — which targets exactly one tool — should
      # compile that one tool rather than the whole domain (what
      # +tool_classes_for+ does for +tools/list+).
      #: (domain: String, name: String, server_context: untyped) -> singleton(MCP::Tool)?
      def tool_class_for(domain:, name:, server_context:)
        tool_class = (tools_by_domain[domain] || []).find { |tc| tc.tool_name == name }
        return nil unless tool_class
        return nil unless tool_class.permitted?(server_context)

        tool_class.materialize_for(server_context)
      end

      # Grouped facade tools for a faceted domain — one synthetic MCP::Tool
      # per non-empty category the caller has at least one permitted tool
      # in. Returns [] for domains not configured via facet_domain.
      # See FacadeBuilder and docs/designs/tool-grouping-facades.md.
      #: (domain: String, server_context: untyped) -> Array[singleton(MCP::Tool)]
      def facades_for(domain:, server_context:)
        McpAuthorization::FacadeBuilder.facades_for(domain: domain, server_context: server_context)
      end

      # A single facade by name within a faceted domain, or nil when the
      # domain is not faceted or the name matches no non-empty group for
      # this caller. The facade analogue of tool_class_for — a tools/call
      # targeting one facade should not build every facade in the domain.
      #: (domain: String, name: String, server_context: untyped) -> singleton(MCP::Tool)?
      def facade_for(domain:, name:, server_context:)
        McpAuthorization::FacadeBuilder.facade_for(domain: domain, name: name, server_context: server_context)
      end

      # Look up a tool by its MCP tool name across all domains.
      #: (String) -> singleton(McpAuthorization::Tool)?
      def find_tool(name)
        registered_tools.find { |t| t.tool_name == name }
      end

      # Clear the registry. Called by the Engine's reloader on code change.
      # The next read reloads +tool_paths+ and re-runs +tool_producers+.
      #: () -> void
      def reset!
        @registered_tools = []
        @loading_tools = false
        @tools_loaded = false
      end

      private

      # Probes for the methods actually called rather than the bare constant,
      # matching Diagnostics' `defined?(Rails) && Rails.respond_to?(:env)`.
      # A partially-loaded Rails (or an unrelated `Rails` module in a non-Rails
      # process) satisfies `defined?` and then raises NoMethodError on `.root`,
      # which would take `registered_tools` down with it — including for a host
      # whose tools all come from `tool_producers` and need no autoloader.
      #: () -> void
      def eager_load_tool_paths!
        return unless defined?(Rails) && Rails.respond_to?(:root) && Rails.respond_to?(:autoloaders)

        McpAuthorization.config.tool_paths.each do |path|
          full_path = Rails.root.join(path)
          Rails.autoloaders.main.eager_load_dir(full_path) if File.directory?(full_path)
        end
      end
    end
  end
end
