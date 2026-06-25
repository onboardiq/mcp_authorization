require "monitor"

module McpAuthorization
  module Cache
    # Process-local in-memory store with a bounded entry count and per-entry
    # TTL. Each worker process warms its own copy — fine for the tools/list
    # payload, which is identical across workers for a given decision vector.
    # For cross-process/host sharing, use RedisStore.
    class MemoryStore
      include MonitorMixin

      DEFAULT_MAX_ENTRIES = 512

      #: (?max_entries: Integer) -> void
      def initialize(max_entries: DEFAULT_MAX_ENTRIES)
        super()
        @max_entries = max_entries
        @entries = {} #: Hash[String, [untyped, Float?]]  # key => [value, expires_at]
      end

      #: (String) -> untyped
      def get(key)
        synchronize do
          entry = @entries[key]
          return nil unless entry

          value, expires_at = entry
          if expires_at && monotonic > expires_at
            @entries.delete(key)
            return nil
          end

          # Mark as most-recently-used.
          @entries.delete(key)
          @entries[key] = entry
          value
        end
      end

      #: (String, untyped, ?ttl: Integer?) -> void
      def set(key, value, ttl: nil)
        synchronize do
          @entries.delete(key)
          @entries[key] = [value, ttl ? monotonic + ttl : nil]
          @entries.shift while @entries.size > @max_entries # evict oldest (insertion order)
        end
      end

      #: () -> void
      def clear
        synchronize { @entries.clear }
      end

      private

      #: () -> Float
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
