module McpAuthorization
  class McpController < ActionController::Base
    skip_forgery_protection

    # POST/GET/DELETE /mcp/:domain
    #: () -> void
    def handle
      server_context = build_server_context

      if mcp_method == "tools/list" && McpAuthorization::Cache.enabled?
        return render_cached_tools_list(server_context)
      end

      status, headers, body = run_transport(server_context, tools_for_request(server_context))
      apply_headers(headers)
      render json: body.first, status: status
    end

    private

    # Build a stateless MCP server with the given tools + context and run the
    # incoming request through the transport.
    #: (untyped, Array[singleton(MCP::Tool)]) -> [Integer, Hash[String, String], Array[untyped]]
    def run_transport(server_context, tools)
      server = MCP::Server.new(
        name: McpAuthorization.config.server_name,
        version: McpAuthorization.config.server_version,
        tools: tools,
        server_context: server_context
      )
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: true)
      server.transport = transport
      transport.handle_request(request)
    end

    #: (Hash[String, String]) -> void
    def apply_headers(headers)
      headers.each { |k, v| response.set_header(k, v) }
    end

    # Serve tools/list from the configured cache, or compile it cold (observed
    # by a Recorder so the cache key vocabulary is learned) and store it. The
    # JSON-RPC envelope is rebuilt with the live request id, so the cached
    # value is just the (id-independent) `result`.
    #: (untyped) -> void
    def render_cached_tools_list(server_context)
      domain = params[:domain]

      key = McpAuthorization::Cache.tools_list_key(domain: domain, server_context: server_context)
      if key && (cached = McpAuthorization::Cache.store.get(key))
        return render json: tools_list_envelope(cached)
      end

      effective_ctx, recorder = McpAuthorization::Cache.recording_context(server_context)
      status, headers, body = run_transport(effective_ctx, all_tools(effective_ctx))
      McpAuthorization::Cache.learn!(domain: domain, recorder: recorder)
      apply_headers(headers)

      parsed = begin
        JSON.parse(body.first)
      rescue StandardError
        nil
      end
      result = parsed && parsed["result"]
      unless result
        return render json: body.first, status: status # error / unexpected shape — don't cache
      end

      store_key = McpAuthorization::Cache.tools_list_key(domain: domain, server_context: server_context)
      McpAuthorization::Cache.store.set(store_key, result, ttl: McpAuthorization::Cache.ttl) if store_key
      render json: tools_list_envelope(result), status: status
    end

    #: (untyped) -> String
    def tools_list_envelope(result)
      { jsonrpc: "2.0", id: mcp_request_id, result: result }.to_json
    end

    #: () -> untyped
    def mcp_request_id
      params[:id] || params.dig(:mcp, :id)
    end

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
