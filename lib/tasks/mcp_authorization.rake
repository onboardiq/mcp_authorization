namespace :mcp do
  desc "Start Rails server and MCP Inspector for a given domain and role"
  task :inspect, [ :domain, :role ] => :environment do |_t, args|
    domain = args[:domain] || McpAuthorization.config.default_domain
    role = args[:role] || "operator"
    port = ENV.fetch("PORT", "3000")
    mount = McpAuthorization.config.mount_path || "/mcp"
    url = "http://localhost:#{port}#{mount}/#{domain}"

    puts "Starting MCP Inspector"
    puts "  Domain:  #{domain}"
    puts "  Role:    #{role}"
    puts "  URL:     #{url}"
    puts ""

    config = {
      mcpServers: {
        McpAuthorization.config.server_name => {
          url: url,
          headers: { "Authorization" => role }
        }
      }
    }
    config_path = Rails.root.join("tmp/mcp_inspector.json")
    File.write(config_path, JSON.pretty_generate(config))

    rails_pid = spawn(
      "bundle exec rails server -p #{port}",
      out: File::NULL, err: File::NULL
    )

    sleep 3

    begin
      exec(
        "npx", "@modelcontextprotocol/inspector",
        "--config", config_path.to_s,
        "--server", McpAuthorization.config.server_name
      )
    ensure
      Process.kill("TERM", rails_pid) rescue nil
    end
  end

  desc "Print Claude Code MCP config for a given domain and role"
  task :claude, [ :domain, :role ] => :environment do |_t, args|
    domain = args[:domain] || McpAuthorization.config.default_domain
    role = args[:role] || "operator"
    port = ENV.fetch("PORT", "3000")
    mount = McpAuthorization.config.mount_path || "/mcp"
    url = "http://localhost:#{port}#{mount}/#{domain}"

    config = {
      "mcpServers" => {
        "#{McpAuthorization.config.server_name}-#{domain}" => {
          "url" => url,
          "headers" => { "Authorization" => role }
        }
      }
    }

    puts "Add this to your Claude Code settings (~/.claude/settings.json):"
    puts ""
    puts JSON.pretty_generate(config)
    puts ""
    puts "Make sure Rails is running: bundle exec rails server -p #{port}"
  end

  desc "List available tools for a domain and role"
  task :tools, [ :domain, :role ] => :environment do |_t, args|
    require "json"
    domain = args[:domain] || McpAuthorization.config.default_domain
    role = args[:role] || "operator"

    builder = McpAuthorization.config.cli_context_builder
    unless builder
      puts "McpAuthorization.config.cli_context_builder is not configured."
      puts "Set it in config/initializers/mcp_authorization.rb"
      exit 1
    end

    ctx = builder.call(domain: domain, role: role)

    tools = McpAuthorization::ToolRegistry.list_tools(domain: domain, server_context: ctx)

    if tools.empty?
      puts "No tools available for domain '#{domain}' with role '#{role}'"
    else
      tools.each do |tool|
        puts "#{tool[:name]}"
        puts "  #{tool[:description]}"
        puts "  input:  #{tool[:inputSchema][:properties].keys.join(', ')}"
        output_shapes = tool.dig(:outputSchema, :oneOf)&.map { |s| s[:properties]&.keys&.join(', ') }
        puts "  output: #{output_shapes&.join(' | ')}" if output_shapes
        puts ""
      end
    end
  end
end
