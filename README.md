# mcp_authorization

Rails engine for serving MCP tools with per-request schema discrimination compiled from RBS type annotations.

Add it to your Gemfile and your Rails app speaks [MCP](https://modelcontextprotocol.io). Write `@rbs type` comments in plain Ruby service classes, tag fields and variants with `@requires(:flag)`, and the gem compiles tailored JSON Schema per request. The type definitions are the authorization policy.

## Three layers of authorization

The gem gives you three independent controls over what each user sees:

| Layer | Mechanism | Effect |
|---|---|---|
| **Tool visibility** | `authorization :manage_workflows` on the tool class | Tool hidden entirely from users who lack the flag |
| **Input fields** | `@requires(:backward_routing)` on a field in `@rbs type input` | Field excluded from the input schema |
| **Output variants** | `@requires(:backward_routing)` on a variant in `@rbs type output` | Variant excluded from the `oneOf` |

All three go through the same predicate: `current_user.can?(:symbol)`. The symbol can represent a permission, a feature flag, a plan tier, an A/B bucket -- whatever your app puts behind it.

## Install

```ruby
# Gemfile
gem "mcp_authorization"
```

```sh
bundle install
```

Routes install automatically at `/mcp`. No `mount` needed.

## Configuration

```ruby
# config/initializers/mcp_authorization.rb
McpAuthorization.configure do |config|
  config.server_name    = "my-app"
  config.server_version = "1.0.0"

  # Build a context from each MCP request.
  # Return anything that responds to .current_user.can?(symbol).
  config.context_builder = ->(request) {
    user = User.authenticate(request.headers["Authorization"])
    OpenStruct.new(current_user: user)
  }
end
```

### Options

| Option | Default | Description |
|---|---|---|
| `server_name` | `"mcp-authorization"` | Name in MCP handshake |
| `server_version` | `"1.0.0"` | Version in MCP handshake |
| `mount_path` | `"/mcp"` | URL prefix for MCP endpoints |
| `default_domain` | `"default"` | Domain when no `:domain` segment in path |
| `tool_paths` | `["app/mcp"]` | Directories where tool classes live (relative to Rails.root) |
| `context_builder` | *required* | `(request) -> context` |
| `cli_context_builder` | `nil` | `(domain:, role:) -> context` for rake tasks |

## The contract

The gem has one opinion about your app:

```ruby
context.current_user.can?(:symbol) # => true/false
```

That's the entire interface. The symbol can mean anything:

```ruby
current_user.can?(:manage_workflows)  # permission
current_user.can?(:backward_routing)  # feature flag
current_user.can?(:enterprise_plan)   # plan tier
current_user.can?(:experiment_v2)     # A/B test
```

The gem doesn't know or care. It just calls `can?` and filters.

## Quick example

### 1. Define a handler

A handler is a plain Ruby class with `@rbs type` comments. Tag fields and variants with `@requires` to control who sees what.

```ruby
# app/service/workflows/advance_step.rb
module Workflows
  class AdvanceStep
    # -- Named types --

    # @rbs type error = {
    #   success: false,
    #   error: { code: String, message: String }
    # }

    # @rbs type success = {
    #   success: true,
    #   applicant_id: String,
    #   current_stage: String
    # }

    # @rbs type rerouted_success = {
    #   success: true,
    #   applicant_id: String,
    #   previous_stage: String,
    #   current_stage: String,
    #   audit_trail: Array[String]
    # }

    # -- Input: @requires controls which fields appear --

    # @rbs type input = {
    #   applicant_id: String,
    #   workflow_id: String,
    #   stage_id?: String    @requires(:backward_routing),
    #   reason?: String      @requires(:backward_routing)
    # }

    # -- Output: @requires controls which variants appear --

    # @rbs type output = success
    #                   | rerouted_success  @requires(:backward_routing)
    #                   | error

    def self.description(server_context:)
      if server_context.current_user.can?(:backward_routing)
        "Advance an applicant to any stage, or reroute them backward."
      else
        "Advance an applicant to the next stage."
      end
    end

    def self.call(server_context:, applicant_id:, workflow_id:, stage_id: nil, reason: nil)
      # your logic here
    end
  end
end
```

### 2. Declare a tool

```ruby
# app/mcp/workflows/advance_step_tool.rb
module Workflows
  class AdvanceStepTool < McpAuthorization::Tool
    tool_name "advance_step"
    authorization :manage_workflows
    tags "operator"
    dynamic_contract Workflows::AdvanceStep
  end
end
```

### 3. See the difference

A user **without** `:backward_routing`:

```
advance_step — "Advance an applicant to the next stage."
  input:  applicant_id, workflow_id
  output: success | error
```

A user **with** `:backward_routing`:

```
advance_step — "Advance an applicant to any stage, or reroute them backward."
  input:  applicant_id, workflow_id, stage_id, reason
  output: success | rerouted_success | error
```

Same tool, same endpoint. The feature flag shapes the schema.

## Handler interface

| Method | Required | Purpose |
|---|---|---|
| `.description(server_context:)` | yes | Tool description shown to the MCP client |
| `.call(server_context:, **params)` | yes | Execute the tool and return a result |

That's it. No schema dispatch methods -- the `@rbs type` annotations with `@requires` tags handle everything.

## `@requires` rules

**On input fields** -- the field is excluded from the schema when `can?` returns false:

```ruby
# @rbs type input = {
#   query: String,
#   force?: bool            @requires(:admin),
#   include_deleted?: bool  @requires(:admin)
# }
```

**On output variants** -- the variant is excluded from the `oneOf`:

```ruby
# @rbs type output = public_result
#                   | admin_result  @requires(:admin)
#                   | error
```

Untagged fields and variants are always included.

## Tool DSL

```ruby
class MyTool < McpAuthorization::Tool
  tool_name "my_tool"
  authorization :some_flag        # tool hidden when can?(:some_flag) is false
  tags "recruiting", "operations" # which domains this tool appears in
  annotations(destructive_hint: false, idempotent_hint: true)
  dynamic_contract MyService      # handler class
end
```

| Method | Purpose |
|---|---|
| `tool_name "name"` | MCP tool name |
| `authorization :sym` | Tool-level visibility gate. Omit for public tools. |
| `tags "domain1", ...` | Domain(s) this tool appears under. Defaults to `["default"]`. |
| `annotations(...)` | MCP tool annotations |
| `dynamic_contract HandlerClass` | Handler providing description, schemas, and execution |

Tools self-register when loaded. Put them anywhere under `tool_paths` (default: `app/mcp/`).

## Multi-domain routing

```
POST /mcp/operator    -> tools tagged "operator"
POST /mcp/recruiting  -> tools tagged "recruiting"
POST /mcp             -> tools tagged with default_domain
```

Tag a tool with multiple domains to make it available in each:

```ruby
tags "operator", "recruiting"
```

## RBS type syntax

The `@rbs type` comments compile to JSON Schema:

```ruby
# Primitives
# @rbs type x = String    -> { "type": "string" }
# @rbs type x = Integer   -> { "type": "integer" }
# @rbs type x = Float     -> { "type": "number" }
# @rbs type x = bool      -> { "type": "boolean" }
# @rbs type x = true      -> { "type": "boolean", "const": true }
# @rbs type x = false     -> { "type": "boolean", "const": false }

# String enums
# @rbs type status = "pending"
#                  | "active"
#                  | "closed"

# Records
# @rbs type result = {
#   success: bool,
#   message: String,
#   count?: Integer
# }
# (count? is optional -- excluded from "required")

# Arrays
# @rbs type items = Array[String]

# Type references
# @rbs type input = { id: String, status: status }
```

### Discriminated unions

Literal `true` / `false` types become `"const"` values in JSON Schema:

```ruby
# @rbs type success = { success: true, data: String }
# @rbs type error   = { success: false, code: String }
# @rbs type output  = success | error
```

MCP clients can narrow on `success: const true` vs `success: const false` -- the same pattern as TypeScript discriminated unions.

### Fallback: infer from call signature

If no `@rbs type input` is defined, the schema is inferred from the `#:` annotation on `def self.call`:

```ruby
#: (server_context: ServerContext, applicant_id: String, ?reason: String?) -> Hash[Symbol, untyped]
def self.call(server_context:, applicant_id:, reason: nil)
```

The `server_context` parameter is always excluded.

## Development

### Live reload

In development mode, the gem wires into the Rails reloader. Edit an `@rbs type` annotation, save, and the next MCP request returns the updated schema. No server restart needed.

### Rake tasks

```sh
# List tools visible to a given role
bundle exec rake "mcp:tools[operator,manager]"

# Print Claude Code / Claude Desktop config JSON
bundle exec rake "mcp:claude[operator,manager]"

# Launch MCP Inspector (requires npx)
bundle exec rake "mcp:inspect[operator,manager]"
```

Rake tasks require `cli_context_builder`:

```ruby
config.cli_context_builder = ->(domain:, role:) {
  user = User.new(role: role, permissions: ROLE_PERMISSIONS[role])
  OpenStruct.new(current_user: user)
}
```

## How it works

1. MCP client sends a request to `/mcp/:domain`
2. Engine calls your `context_builder` with the request
3. `ToolRegistry` filters tools by domain tag and `authorization` gate (`can?` check)
4. `RbsSchemaCompiler` reads `@rbs type input` and `@rbs type output` from the handler source
5. Fields and variants tagged `@requires(:flag)` are included or excluded based on `can?`
6. MCP client receives tool definitions with schemas tailored to the current user

Different users hitting the same endpoint can see different tools, different descriptions, different input fields, and different output shapes.

## Requirements

- Ruby >= 3.1
- Rails >= 7.0
- [mcp](https://rubygems.org/gems/mcp) ~> 0.9

## License

MIT
