require_relative "lib/mcp_authorization/version"

Gem::Specification.new do |spec|
  spec.name        = "mcp_authorization"
  spec.version     = McpAuthorization::VERSION
  spec.authors     = ["Andy"]
  spec.summary     = "Rails engine for MCP tools with per-request schema discrimination"
  spec.description = "Add MCP tool serving to any Rails app. Write @rbs type annotations " \
                     "with @requires(:flag) tags and the gem compiles per-user JSON Schema " \
                     "automatically. Feature flags, permissions, and plan tiers all work " \
                     "through a single can?(:symbol) predicate."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir[
    "lib/mcp_authorization.rb",
    "lib/mcp_authorization/**/*",
    "lib/tasks/mcp_authorization.rake",
    "app/controllers/mcp_authorization/**/*",
    "LICENSE.txt",
    "README.md"
  ]

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "mcp", "~> 0.9"
end
