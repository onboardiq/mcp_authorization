require "json"

module McpAuthorization
  module Cache
    # Redis-backed store — shared across workers and hosts. Values are stored
    # as JSON (the tools/list result is plain JSON-serializable data), with a
    # per-entry TTL via +SET ... EX+.
    #
    # Connection resolution (first match wins), so a Rails host gets the
    # "Rails redis config" for free without passing anything:
    #
    #   1. an explicit client       — RedisStore.new(redis: $redis)
    #   2. an explicit URL          — RedisStore.new(url: "redis://…")
    #   3. ENV["REDIS_URL"]         — the conventional Rails/Heroku/Sidekiq var
    #   4. Redis.new                — the redis gem's own default (ENV or localhost),
    #                                 matching a bare `Redis.new` in the host
    #
    # The +redis+ gem is an optional dependency, required lazily here so hosts
    # that don't use this store never need it.
    class RedisStore
      # Raised when :redis caching is requested but the redis gem is absent.
      class RedisUnavailable < StandardError; end

      NAMESPACE = "mcpauth".freeze

      #: (?redis: untyped?, ?url: String?, ?namespace: String) -> void
      def initialize(redis: nil, url: nil, namespace: NAMESPACE)
        @redis = redis
        @url = url
        @namespace = namespace
      end

      #: (String) -> untyped
      def get(key)
        raw = client.get(namespaced(key))
        raw && JSON.parse(raw)
      rescue StandardError => e
        log_error("get", e)
        nil # never let a cache outage break tools/list
      end

      #: (String, untyped, ?ttl: Integer?) -> void
      def set(key, value, ttl: nil)
        payload = JSON.generate(value)
        if ttl && ttl > 0
          client.set(namespaced(key), payload, ex: ttl)
        else
          client.set(namespaced(key), payload)
        end
        nil
      rescue StandardError => e
        log_error("set", e)
        nil
      end

      #: () -> void
      def clear
        cursor = "0"
        loop do
          cursor, keys = client.scan(cursor, match: namespaced("*"), count: 500)
          client.del(*keys) unless keys.empty?
          break if cursor == "0"
        end
      rescue StandardError => e
        log_error("clear", e)
      end

      private

      #: (String) -> String
      def namespaced(key)
        "#{@namespace}:#{key}"
      end

      #: () -> untyped
      def client
        @client ||= @redis || build_client
      end

      #: () -> untyped
      def build_client
        require "redis"
        url = @url || ENV["REDIS_URL"]
        url ? ::Redis.new(url: url) : ::Redis.new
      rescue LoadError
        raise RedisUnavailable, <<~MSG
          McpAuthorization is configured to use the :redis tools/list cache,
          but the `redis` gem is not available. Add `gem "redis"` to your
          Gemfile, or pass an explicit client/store to
          `config.tools_list_cache`.
        MSG
      end

      #: (String, Exception) -> void
      def log_error(op, error)
        return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

        Rails.logger.error("[McpAuthorization] redis cache #{op} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
