module McpAuthorization
  class McpController < ActionController::Base
    skip_forgery_protection

    # POST/GET/DELETE /mcp/:domain
    #: () -> void
    def handle
      server_context = build_server_context
      tools = McpAuthorization::ToolRegistry.tool_classes_for(
        domain: params[:domain],
        server_context: server_context
      )

      server = MCP::Server.new(
        name: McpAuthorization.config.server_name,
        version: McpAuthorization.config.server_version,
        tools: tools,
        server_context: server_context
      )
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
      server.transport = transport

      status, headers, body = transport.handle_request(request)
      headers.each { |k, v| response.set_header(k, v) }
      render json: body.first, status: status
    end

    private

    #: () -> untyped
    def build_server_context
      builder = McpAuthorization.config.context_builder
      raise "McpAuthorization.config.context_builder must be configured" unless builder
      builder.call(request)
    end
  end
end
