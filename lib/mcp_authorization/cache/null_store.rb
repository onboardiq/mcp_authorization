module McpAuthorization
  module Cache
    # No-op store. The default — caching is opt-in. Every read misses, every
    # write is discarded, so behavior is identical to a gem with no cache.
    class NullStore
      #: (String) -> nil
      def get(_key)
        nil
      end

      #: (String, untyped, ?ttl: Integer?) -> void
      def set(_key, _value, ttl: nil)
        nil
      end

      #: () -> void
      def clear; end
    end
  end
end
