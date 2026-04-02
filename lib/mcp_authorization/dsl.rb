module McpAuthorization
  # Mixin for handler classes — the plain Ruby objects that implement the
  # business logic behind each MCP tool.
  #
  # Include this module instead of hand-rolling +initialize+, permission
  # checks, and MCP notification plumbing:
  #
  #   class Handlers::ListOrders
  #     include McpAuthorization::DSL
  #
  #     def description
  #       "List recent orders"
  #     end
  #
  #     #: (status: String, ?limit: Integer @requires(:admin)) -> Hash[Symbol, untyped]
  #     def call(status:, limit: 25)
  #       orders = Order.where(status: status).limit(limit)
  #       { orders: orders.map(&:as_json) }
  #     end
  #   end
  #
  # == What it provides
  #
  # * +server_context+ — the per-request context object built by the host
  #   app's +context_builder+.
  # * +can?(flag)+ — convenience delegation to +current_user.can?+.
  # * +report_progress+ / +notify_log_message+ — thin wrappers around MCP
  #   session notifications, safe to call even when the context doesn't
  #   support them (e.g. during +tools/list+).
  #
  module DSL
    # The per-request context built by the host app's +context_builder+.
    #: untyped
    attr_reader :server_context

    #: (server_context: untyped) -> void
    def initialize(server_context:)
      @server_context = server_context
    end

    # Convenience check — delegates to +server_context.current_user.can?+.
    # Use inside +#call+ for runtime branching beyond +@requires+ filtering.
    #: (Symbol) -> bool
    def can?(flag)
      server_context.current_user.can?(flag)
    end

    # Send a progress notification to the MCP client (MCP 0.10+).
    # Safe to call unconditionally — no-ops when context lacks support.
    #: (Numeric, ?total: Numeric?, ?message: String?) -> void
    def report_progress(progress, total: nil, message: nil)
      return unless server_context.respond_to?(:report_progress)
      server_context.report_progress(progress, total: total, message: message)
    end

    # Send a log message notification to the MCP client (MCP 0.10+).
    # Safe to call unconditionally — no-ops when context lacks support.
    #: (data: untyped, level: String | Symbol, ?logger: String?) -> void
    def notify_log_message(data:, level:, logger: nil)
      return unless server_context.respond_to?(:notify_log_message)
      server_context.notify_log_message(data: data, level: level, logger: logger)
    end
  end
end
