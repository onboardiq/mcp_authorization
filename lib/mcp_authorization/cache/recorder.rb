module McpAuthorization
  module Cache
    # A signature for one decision the compiler consulted on the server
    # context: a predicate call (`feature?(:sms)`, `requires?(:admin)`, a
    # custom `tier?(:enterprise)`), or a `current_user.can?` / `default_for`
    # call. Identity is by (target, method, arg) so the same decision dedupes
    # across tools; +arg+ is retained intact so replay calls the predicate
    # with the original value, not a coerced one.
    Signature = Struct.new(:target, :method, :arg) do
      #: () -> String
      def canonical
        "#{target}\x1f#{method}\x1f#{arg.inspect}"
      end

      #: (untyped) -> bool
      def eql?(other)
        other.is_a?(Signature) && canonical == other.canonical
      end

      #: () -> Integer
      def hash
        canonical.hash
      end
    end

    # Wraps a server context during a cold compile and records every gating
    # decision the compiler reads — so the cache key can be rebuilt later from
    # just those decisions. Two contexts that answer every recorded predicate
    # identically (same permissions, feature flags, tiers, defaults) produce
    # the same key and share a cache entry; flip one feature flag and the
    # vector — and the key — change.
    #
    # Transparently delegates everything to the wrapped context. The compiler
    # reaches the user via +current_user+, so that returns a RecorderUser to
    # capture +can?+ and +default_for+.
    class Recorder
      #: untyped
      attr_reader :__target

      #: Array[Signature]
      attr_reader :consulted

      #: (untyped) -> void
      def initialize(target)
        @__target = target
        @consulted = []
        @__user = nil
      end

      #: () -> untyped
      def current_user
        user = @__target.current_user
        return nil unless user

        @__user ||= RecorderUser.new(user, @consulted)
      end

      #: (Symbol, ?bool) -> bool
      def respond_to_missing?(name, include_private = false)
        @__target.respond_to?(name, include_private)
      end

      #: (Symbol, *untyped) -> untyped
      def method_missing(name, *args, &block)
        result = @__target.public_send(name, *args, &block)
        # Gating predicates are single-arg methods ending in "?"
        # (feature?/requires?/tier?/<custom>?). Recording an incidental
        # predicate is harmless — it just adds a deterministic dimension to
        # the key — so we don't need a hardcoded allowlist.
        if name.to_s.end_with?("?") && args.size == 1
          @consulted << Signature.new(:context, name.to_s, args.first)
        end
        result
      end
    end

    # Records +can?+ and +default_for+ on the wrapped user. +default_for+
    # returns a value baked into the schema, so its result is part of the
    # decision vector too, not just predicate booleans.
    class RecorderUser
      #: (untyped, Array[Signature]) -> void
      def initialize(target, consulted)
        @__target = target
        @consulted = consulted
      end

      #: (untyped) -> untyped
      def can?(flag)
        @consulted << Signature.new(:user, "can?", flag)
        @__target.can?(flag)
      end

      #: (untyped) -> untyped
      def default_for(key)
        @consulted << Signature.new(:user, "default_for", key)
        @__target.default_for(key)
      end

      #: (Symbol, ?bool) -> bool
      def respond_to_missing?(name, include_private = false)
        @__target.respond_to?(name, include_private)
      end

      #: (Symbol, *untyped) -> untyped
      def method_missing(name, *args, &block)
        @__target.public_send(name, *args, &block)
      end
    end
  end
end
