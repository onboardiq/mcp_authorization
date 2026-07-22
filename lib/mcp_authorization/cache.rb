require "digest"
require "json"
require "monitor"
require "set"

require_relative "cache/null_store"
require_relative "cache/memory_store"
require_relative "cache/redis_store"
require_relative "cache/recorder"

module McpAuthorization
  # Opt-in caching for the `tools/list` response — the one MCP method that must
  # materialize a per-user schema for *every* tool in a domain, and the
  # dominant cost of an MCP request once `tools/call` only compiles one tool
  # (see McpController).
  #
  # The cache is keyed on the *decisions* the compiler makes, not on user or
  # account identity, so it is both correct under feature flags and maximally
  # shareable:
  #
  #   key = H(domain + tool_defs_digest + vocab_fingerprint + decision_vector)
  #
  # - tool_defs_digest   — changes when a tool's gates or handler source change
  #                        (i.e. on deploy), auto-invalidating stale entries.
  # - decision_vector    — the result of every gating predicate the domain's
  #                        compilation consults, evaluated against this context.
  #
  # Two ways the decision vector is obtained:
  #
  # 1. Explicit (recommended for hosts that know their inputs): if the server
  #    context responds to +mcp_cache_fingerprint+, its return value is used
  #    verbatim as the decision component. The host is responsible for folding
  #    in everything that shapes the schema (permission set, feature flags,
  #    integrations, per-user defaults).
  #
  # 2. Automatic: otherwise the gem learns the vocabulary by wrapping the
  #    context in a Recorder on the first (cold) compile of a domain, capturing
  #    every predicate / can? / default_for it reads. Subsequent requests
  #    rebuild the vector by replaying that vocabulary against the live context.
  #
  # Caching is off by default (NullStore). Enable in a Rails initializer:
  #
  #   McpAuthorization.configure do |c|
  #     c.tools_list_cache = :redis        # or :memory, or a custom store
  #     c.tools_list_cache_ttl = 3600
  #   end
  module Cache
    @monitor = Monitor.new
    @learned = {}      #: Hash[String, Array[Signature]]  # domain => learned signatures
    @learned_flag = {} #: Hash[String, bool]              # domain => has been learned at all
    @store = nil
    @defs_digest = nil

    class << self
      # The resolved store. Memoized; rebuilt after +reset!+.
      #: () -> untyped
      def store
        @monitor.synchronize { @store ||= resolve_store(McpAuthorization.config.tools_list_cache) }
      end

      #: () -> bool
      def enabled?
        !store.is_a?(NullStore)
      end

      #: () -> Integer
      def ttl
        McpAuthorization.config.tools_list_cache_ttl
      end

      # Returns [effective_context, recorder_or_nil]. When the host supplies an
      # explicit fingerprint, no recorder is needed and the real context is
      # used. Otherwise the context is wrapped so the cold compile is observed.
      #: (untyped) -> [untyped, Recorder?]
      def recording_context(server_context)
        return [server_context, nil] if explicit_fingerprint(server_context)

        recorder = Recorder.new(server_context)
        [recorder, recorder]
      end

      # Merge a cold compile's consulted decisions into the domain vocabulary.
      # No-op in explicit-fingerprint mode (recorder is nil).
      #: (domain: String, recorder: Recorder?) -> void
      def learn!(domain:, recorder:)
        return if recorder.nil?

        @monitor.synchronize do
          existing = @learned[domain] ||= []
          seen = existing.to_set
          recorder.consulted.each { |sig| existing << sig unless seen.include?(sig) }
          @learned_flag[domain] = true
        end
      end

      # The cache key for this domain + context, or nil when the domain has not
      # been learned yet (auto mode), which forces a cold compile.
      #: (domain: String, server_context: untyped) -> String?
      def tools_list_key(domain:, server_context:)
        fp = explicit_fingerprint(server_context)
        if fp
          components = ["fp", domain, defs_digest, stable(fp)]
          return digest_key(components)
        end

        vocab, learned = @monitor.synchronize { [(@learned[domain] || []).dup, @learned_flag[domain]] }
        return nil unless learned

        sorted = vocab.sort_by(&:canonical)
        vector = sorted.map { |sig| [sig.canonical, stable(evaluate(sig, server_context))] }
        fingerprint = Digest::SHA256.hexdigest(sorted.map(&:canonical).join("\n"))[0, 12]
        digest_key(["v", domain, defs_digest, fingerprint, vector])
      end

      # Digest of every registered tool's gating + contract source. Changes on
      # deploy (gate edits, handler source mtime), invalidating cached entries
      # without an explicit bust. Memoized; cleared by +reset!+.
      #: () -> String
      def defs_digest
        @monitor.synchronize do
          @defs_digest ||= compute_defs_digest
        end
      end

      # Clear memoized store, learned vocabulary, and the defs digest. Called by
      # the Engine reloader so code changes in development take effect.
      #: () -> void
      def reset!
        @monitor.synchronize do
          @store = nil
          @learned = {}
          @learned_flag = {}
          @defs_digest = nil
        end
      end

      private

      #: (untyped) -> untyped
      def resolve_store(setting)
        case setting
        when nil, false then NullStore.new
        when :memory then MemoryStore.new
        when :redis
          RedisStore.new(
            redis: McpAuthorization.config.tools_list_cache_redis,
            url: McpAuthorization.config.tools_list_cache_redis_url
          )
        else
          setting # assume a store-like object (responds to get/set)
        end
      end

      #: (untyped) -> untyped
      def explicit_fingerprint(server_context)
        return nil unless server_context.respond_to?(:mcp_cache_fingerprint)

        server_context.mcp_cache_fingerprint
      rescue StandardError
        nil
      end

      #: (Signature, untyped) -> untyped
      def evaluate(sig, server_context)
        target = sig.target == :user ? server_context.current_user : server_context
        return :__no_target if target.nil?

        target.public_send(sig.method, sig.arg)
      rescue StandardError
        :__error
      end

      #: (Array[untyped]) -> String
      def digest_key(components)
        "tl:" + Digest::SHA256.hexdigest(JSON.generate(components))
      end

      # Coerce a value into a stable, JSON-safe form for the key. Symbols become
      # strings; anything exotic falls back to its inspect string.
      #: (untyped) -> untyped
      def stable(value)
        case value
        when Symbol then value.to_s
        when String, Integer, Float, true, false, nil then value
        when Array then value.map { |v| stable(v) }
        when Hash then value.sort_by { |k, _| k.to_s }.map { |k, v| [k.to_s, stable(v)] }
        else value.inspect
        end
      end

      #: () -> String
      def compute_defs_digest
        sigs = McpAuthorization::ToolRegistry.registered_tools.map do |tool_class|
          handler = (tool_class._contract_handler rescue nil)
          source = handler_source_mtime(handler)
          [
            tool_class.tool_name.to_s,
            (tool_class._gates || []).map { |g| [g[:name].to_s, g[:value].to_s] },
            handler&.name.to_s,
            source,
            tool_class._category.to_s
          ]
        end.sort_by(&:first)
        # Facet config and group summaries shape the tools/list of a faceted
        # domain the same way a gate edit shapes a flat one — toggling
        # grouping, switching schema strategy, or rewording a summary must
        # invalidate cached listings.
        config = McpAuthorization.config
        facets = config.faceted_domains.sort.map do |domain, fc|
          [domain, fc.sort_by { |k, _| k.to_s }.map { |k, v| [k.to_s, v.to_s] }]
        end
        summaries = config.category_summaries.sort_by { |k, _| k.to_s }.map { |k, v| [k.to_s, v] }
        Digest::SHA256.hexdigest(JSON.generate([sigs, facets, summaries]))[0, 16]
      rescue StandardError
        # If anything about introspection fails, fall back to a process-stable
        # digest so caching still works within a boot (just not across deploys
        # via the digest — TTL still bounds staleness).
        defined?(McpAuthorization::VERSION) ? McpAuthorization::VERSION : "mcpauth"
      end

      #: (untyped) -> Integer
      def handler_source_mtime(handler)
        return 0 unless handler

        file = McpAuthorization::RbsSchemaCompiler.send(:find_source_file, handler)
        file && File.exist?(file) ? File.mtime(file).to_i : 0
      rescue StandardError
        0
      end
    end
  end
end
