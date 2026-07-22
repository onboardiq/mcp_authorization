module McpAuthorization
  # Holds gem-wide settings. A single global instance is created lazily by
  # McpAuthorization.configuration and configured in a Rails initializer:
  #
  #   McpAuthorization.configure do |c|
  #     c.server_name      = "my-app"
  #     c.server_version   = MyApp::VERSION
  #     c.tool_paths       = %w[app/mcp]
  #     c.context_builder  = ->(request) { ... }
  #   end
  #
  # == Required settings
  #
  # +context_builder+ must be set before the first MCP request. Everything
  # else has sensible defaults.
  #
  # == The context contract
  #
  # Both +context_builder+ and +cli_context_builder+ must return an object
  # whose +current_user+ responds to:
  #
  #   current_user.can?(:symbol)              # required — gates field/tool visibility
  #   current_user.default_for(:symbol)       # optional — populates @default_for tags
  #
  # The context object itself can implement predicate methods for generic
  # tag filtering. Any +@tag(:value)+ not in the known constraint list
  # calls +context.tag?(value)+:
  #
  #   context.requires?(flag)                 # optional — for @requires, falls back to current_user.can?
  #   context.feature?(flag)                  # optional — for @feature (account-level feature flags)
  #   context.tier?(name)                     # optional — for @tier (plan-level gating)
  #
  # For public/anonymous MCP interfaces, supply a context with minimum-viable
  # permissions rather than +current_user: nil+. A nil user causes +@requires+
  # fields to be silently excluded (no user = no permissions).
  #
  # See RbsSchemaCompiler.predicate_excluded? for the full protocol.
  #
  class Configuration
    # Server name reported in the MCP +initialize+ handshake.
    #: String
    attr_accessor :server_name

    # Server version reported in the MCP +initialize+ handshake.
    #: String
    attr_accessor :server_version

    # Directories (relative to +Rails.root+) that contain tool classes.
    # Added to +autoload_paths+ and +eager_load_paths+ by the Engine.
    #: Array[String]
    attr_accessor :tool_paths

    # Directories (relative to +Rails.root+) where shared +.rbs+ type
    # files live. Used by RbsSchemaCompiler to resolve +# @rbs import+.
    #: Array[String]
    attr_accessor :shared_type_paths

    # Domain name used when the request URL has no +:domain+ segment.
    #: String
    attr_accessor :default_domain

    # URL prefix where the Engine mounts its routes.
    #: String
    attr_accessor :mount_path

    # Lambda that builds a server context from a Rack request.
    # The returned object must satisfy the context contract above.
    #: (^(untyped) -> untyped)?
    attr_accessor :context_builder

    # Lambda that builds a server context for CLI/rake usage.
    # Same duck-type contract as +context_builder+.
    #: (^(domain: String, role: String) -> untyped)?
    attr_accessor :cli_context_builder

    # When true, strips JSON Schema keywords that cause 400 errors in
    # Anthropic's strict tool use mode (minLength, maximum, maxItems, etc.)
    # and adds additionalProperties: false to all objects.
    #: bool
    attr_accessor :strict_schema

    # Cache for the +tools/list+ response. Opt-in; defaults to no caching.
    # Accepts:
    #   nil / false  — no caching (default)
    #   :memory      — process-local MemoryStore
    #   :redis       — shared RedisStore (connection resolved from
    #                  +tools_list_cache_redis+ / +tools_list_cache_redis_url+ /
    #                  ENV["REDIS_URL"] / a bare Redis.new — the Rails redis config)
    #   <object>     — any store responding to +get+/+set+
    # See McpAuthorization::Cache for the keying strategy.
    #: untyped
    attr_accessor :tools_list_cache

    # TTL (seconds) for cached +tools/list+ entries. Bounds staleness from
    # out-of-band changes (e.g. a feature flag toggled with no deploy); the
    # deploy digest invalidates on tool/schema changes independently.
    #: Integer
    attr_accessor :tools_list_cache_ttl

    # Optional explicit Redis client for the :redis store. When nil, the store
    # resolves a connection from +tools_list_cache_redis_url+, then
    # ENV["REDIS_URL"], then a bare +Redis.new+.
    #: untyped
    attr_accessor :tools_list_cache_redis

    # Optional explicit Redis URL for the :redis store.
    #: String?
    attr_accessor :tools_list_cache_redis_url

    # Per-domain facet (tool-grouping) configuration, keyed by domain name.
    # Each value is a Hash: { group_by:, schema_strategy:, uncategorized:,
    # facade_suffix: }.
    # Populated by +facet_domain+; read by ToolRegistry / FacadeBuilder.
    # See docs/designs/tool-grouping-facades.md.
    #: Hash[String, Hash[Symbol, untyped]]
    attr_reader :faceted_domains

    # Group summaries keyed by category symbol. Populated by +categories+.
    #: Hash[Symbol, String]
    attr_reader :category_summaries

    # Schema strategies FacadeBuilder knows how to emit.
    # LLM tool `input_schema` must have an object root — Anthropic and OpenAI
    # reject `oneOf`/`allOf`/`anyOf` at the top level — so both facade
    # strategies keep a flat object root and differ only in where the per-tool
    # schemas go: `:vendor_extension` carries them on the facade's `_meta`;
    # `:lazy` omits them (enforced at dispatch). A correlated inline shape
    # (tool_name → its argument schema) would require a root combinator and is
    # therefore not offered.
    SCHEMA_STRATEGIES = %i[vendor_extension lazy].freeze #: Array[Symbol]

    # Behaviors for a tool in a faceted domain that declares no +category+.
    UNCATEGORIZED_MODES = %i[fallback error].freeze #: Array[Symbol]

    # Grouping keys +facet_domain+ knows how to group by. Only +:category+
    # exists today (the +category+ DSL is the only grouping key); accepted
    # explicitly so a future key is an additive, validated change.
    GROUP_BY_KEYS = %i[category].freeze #: Array[Symbol]

    # Default suffix appended to a category to form its facade tool name
    # (e.g. category +:orders+ → +orders_tools+). Overridable per domain via
    # +facet_domain(..., facade_suffix:)+.
    DEFAULT_FACADE_SUFFIX = "tools" #: String

    # A facade suffix must be a bare identifier fragment so the derived facade
    # name (+"#{category}_#{suffix}"+) stays a valid MCP tool name.
    FACADE_SUFFIX_FORMAT = /\A[a-z0-9]+(?:_[a-z0-9]+)*\z/ #: Regexp

    #: () -> void
    def initialize
      @server_name = "mcp-authorization"
      @server_version = "1.0.0"
      @tool_paths = %w[app/mcp]
      @shared_type_paths = %w[sig/shared]
      @default_domain = "default"
      @mount_path = "/mcp"
      @context_builder = nil
      @cli_context_builder = nil
      @strict_schema = false
      @tools_list_cache = nil
      @tools_list_cache_ttl = 3600
      @tools_list_cache_redis = nil
      @tools_list_cache_redis_url = nil
      @faceted_domains = {}
      @category_summaries = {}
    end

    # Present a domain as grouped facade tools instead of a flat tool list.
    #
    #   config.facet_domain :admin, group_by: :category
    #   config.facet_domain :admin, group_by: :category,
    #                        schema_strategy: :lazy,
    #                        uncategorized: :error
    #
    # +group_by+ is currently always +:category+ (the only grouping key the
    # +category+ DSL provides); it is accepted explicitly so future grouping
    # keys are an additive change rather than a behavior switch.
    #
    # +schema_strategy+ selects where the per-tool argument schemas go (the
    # facade inputSchema is a flat object either way — see SCHEMA_STRATEGIES).
    # +:vendor_extension+ (default) carries them on the facade's +_meta+;
    # +:lazy+ omits them.
    #
    # +uncategorized+ controls what happens to a tool in this domain with no
    # +category+: +:fallback+ (default) collects them into an +uncategorized+
    # group; +:error+ raises at facade-build time.
    #
    # +facade_suffix+ is the token appended to a category to form its facade
    # tool name — category +:orders+ → +orders_#{suffix}+. Defaults to
    # +"tools"+ (+orders_tools+). Must be a lowercase identifier fragment
    # (+[a-z0-9_]+) so the derived name stays a valid MCP tool name.
    #: (Symbol | String, group_by: Symbol, ?schema_strategy: Symbol, ?uncategorized: Symbol, ?facade_suffix: String | Symbol) -> void
    def facet_domain(domain, group_by:, schema_strategy: :vendor_extension, uncategorized: :fallback, facade_suffix: DEFAULT_FACADE_SUFFIX)
      unless GROUP_BY_KEYS.include?(group_by.to_sym)
        raise ArgumentError, "unknown group_by #{group_by.inspect}; " \
          "expected one of #{GROUP_BY_KEYS.inspect}"
      end
      unless SCHEMA_STRATEGIES.include?(schema_strategy)
        raise ArgumentError, "unknown schema_strategy #{schema_strategy.inspect}; " \
          "expected one of #{SCHEMA_STRATEGIES.inspect}"
      end
      unless UNCATEGORIZED_MODES.include?(uncategorized)
        raise ArgumentError, "unknown uncategorized mode #{uncategorized.inspect}; " \
          "expected one of #{UNCATEGORIZED_MODES.inspect}"
      end

      suffix = facade_suffix.to_s
      unless FACADE_SUFFIX_FORMAT.match?(suffix)
        raise ArgumentError, "invalid facade_suffix #{facade_suffix.inspect}; " \
          "expected a lowercase identifier fragment matching #{FACADE_SUFFIX_FORMAT.inspect}"
      end

      @faceted_domains[domain.to_s] = {
        group_by: group_by.to_sym,
        schema_strategy: schema_strategy,
        uncategorized: uncategorized,
        facade_suffix: suffix
      }
    end

    # True when the given domain is presented as grouped facades.
    #: (String) -> bool
    def faceted?(domain)
      @faceted_domains.key?(domain.to_s)
    end

    # Facet config Hash for a domain, or nil when the domain is not faceted.
    #: (String) -> Hash[Symbol, untyped]?
    def facet_config(domain)
      @faceted_domains[domain.to_s]
    end

    # Declare one summary line per group. Evaluated in a small collector so
    # the block reads declaratively:
    #
    #   config.categories do
    #     summary :orders,  "Create, inspect, and update orders."
    #     summary :billing, "Invoices, payments, refunds."
    #   end
    #: () { () -> void } -> void
    def categories(&block)
      collector = CategoryCollector.new(@category_summaries)
      collector.instance_eval(&block)
    end

    # The group summary for a category, or nil when none was declared.
    #: (Symbol) -> String?
    def category_summary(category)
      @category_summaries[category.to_sym]
    end

    # Collects +summary :key, "text"+ declarations into a shared hash.
    class CategoryCollector
      #: (Hash[Symbol, String]) -> void
      def initialize(store)
        @store = store
      end

      #: (Symbol | String, String) -> void
      def summary(category, text)
        @store[category.to_sym] = text
      end
    end
  end
end
