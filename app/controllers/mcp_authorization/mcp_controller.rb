module McpAuthorization
  class McpController < ActionController::Base
    skip_forgery_protection

    # POST/GET/DELETE /mcp/:domain
    #: () -> void
    def handle
      server_context = build_server_context

      server = MCP::Server.new(
        name: McpAuthorization.config.server_name,
        version: McpAuthorization.config.server_version,
        tools: tools_for_request(server_context),
        server_context: server_context
      )
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
      server.transport = transport

      status, headers, body = transport.handle_request(request)
      headers.each { |k, v| response.set_header(k, v) }
      render json: body.first, status: status
    end

    private

    # Materialize only the tools the incoming JSON-RPC method needs. Compiling
    # per-user schemas for every tool is the dominant cost of an MCP request, so
    # a +tools/call+ compiles just the invoked tool and lifecycle methods
    # (initialize, notifications/*, ping) and non-POST probes compile none.
    # +tools/list+ — and any unrecognized shape such as a JSON-RPC batch —
    # falls back to the full domain so routing stays correct.
    #: (untyped) -> Array[singleton(MCP::Tool)]
    def tools_for_request(server_context)
      return [] if request.get?

      case mcp_method
      when "tools/list"
        all_tools(server_context)
      when "tools/call"
        name = mcp_request_params[:name]
        name ? Array(McpAuthorization::ToolRegistry.tool_class_for(
          domain: params[:domain],
          name: name,
          server_context: server_context
        )) : all_tools(server_context)
      when "initialize", "ping", %r{\Anotifications/}
        []
      else
        # Unknown or unreadable method (e.g. a JSON-RPC batch with no top-level
        # method): materialize the full domain so multi-method requests route.
        all_tools(server_context)
      end
    end

    #: (untyped) -> Array[singleton(MCP::Tool)]
    def all_tools(server_context)
      McpAuthorization::ToolRegistry.tool_classes_for(
        domain: params[:domain],
        server_context: server_context
      )
    end

    #: () -> untyped
    def mcp_method
      params[:method] || params.dig(:mcp, :method)
    end

    #: () -> untyped
    def mcp_request_params
      params[:params] || params.dig(:mcp, :params) || ActionController::Parameters.new
    end

    #: () -> untyped
    def build_server_context
      builder = McpAuthorization.config.context_builder
      raise "McpAuthorization.config.context_builder must be configured" unless builder
      builder.call(request)
    end
  end
end
