# mcp_authorization

Rails engine for serving MCP tools with per-request schema discrimination compiled from RBS type annotations.

Add it to your Gemfile and your Rails app speaks [MCP](https://modelcontextprotocol.io). Write `@rbs type` comments in plain Ruby service classes, tag fields and variants with `@requires(:flag)`, and the gem compiles tailored JSON Schema per request. The type definitions are the authorization policy.

## Three layers of authorization

The gem gives you three independent controls over what each user sees:

| Layer | Mechanism | Effect |
|---|---|---|
| **Tool visibility** | `authorization :manage_workflows` on the tool class | Tool hidden entirely from users who lack the flag |
| **Input fields** | `@requires(:backward_routing)` on a param in `#:` annotation | Field excluded from the input schema |
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
| `shared_type_paths` | `["sig/shared"]` | Directories where shared `.rbs` type files live |
| `context_builder` | *required* | `(request) -> context` |
| `cli_context_builder` | `nil` | `(domain:, role:) -> context` for rake tasks |

## The contract

The gem has two opinions about your app:

```ruby
context.current_user.can?(:symbol)         # => true/false  (required)
context.current_user.default_for(:symbol)  # => value | nil (optional)
```

`can?` gates visibility -- fields, variants, and entire tools. `default_for` populates JSON Schema `default` values from the current user's context. The symbols can mean anything:

```ruby
current_user.can?(:manage_workflows)  # permission
current_user.can?(:backward_routing)  # feature flag
current_user.can?(:enterprise_plan)   # plan tier
current_user.can?(:experiment_v2)     # A/B test

current_user.default_for(:timezone)   # => "America/Chicago"
current_user.default_for(:locale)     # => "en-US"
```

`default_for` is optional. If you don't use `@default_for` tags, you don't need it. When present, it's a simple case statement -- no metaprogramming:

```ruby
def default_for(key)
  case key
  when :timezone then timezone
  when :locale then locale
  end
end
```

## Quick example

### 1. Define shared types

Define reusable types as `.rbs` files. These are plain RBS -- no comment markers.

```rbs
# sig/shared/error.rbs
type error_code = "not_found"
               | "invalid_transition"
               | "already_at_stage"

type error = {
  success: false,
  error: { code: error_code, message: String, hint: String }
}
```

```rbs
# sig/shared/applicant.rbs
type applicant = {
  id: String,
  name: String,
  current_stage: String,
  applied_at: String
}
```

### 2. Define a handler

A handler includes `McpAuthorization::DSL`, imports shared types, and defines its own types. The `#:` annotation on `def call` is the input schema -- tag params with `@requires` to control who sees them.

```ruby
# app/service/workflows/advance_step.rb
module Workflows
  class AdvanceStep
    # @rbs import error

    include McpAuthorization::DSL

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

    # @rbs type output = success
    #                   | rerouted_success  @requires(:backward_routing)
    #                   | error

    def description
      if can?(:backward_routing)
        "Advance an applicant to any stage, or reroute them backward."
      else
        "Advance an applicant to the next stage."
      end
    end

    #: (
    #:   applicant_id: String,
    #:   workflow_id: String,
    #:   ?stage_id: String?    @requires(:backward_routing),
    #:   ?reason: String?      @requires(:backward_routing)
    #: ) -> Hash[Symbol, untyped]
    def call(applicant_id:, workflow_id:, stage_id: nil, reason: nil)
      # your logic here
    end
  end
end
```

### 3. Declare a tool

```ruby
# app/mcp/workflows/advance_step_tool.rb
module Workflows
  class AdvanceStepTool < McpAuthorization::Tool
    tool_name "advance_step"
    authorization :manage_workflows
    not_destructive!
    tags "operator"
    dynamic_contract Workflows::AdvanceStep
  end
end
```

### 4. See the difference

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

A handler includes `McpAuthorization::DSL` and implements two methods:

| Method | Purpose |
|---|---|
| `description` | Tool description shown to the MCP client |
| `call(**params)` | Execute the tool and return a result |

The DSL mixin provides `initialize(server_context:)`, `server_context`, and `can?(:flag)`.

The input schema is inferred from the `#:` annotation on `def call`. The output schema comes from `@rbs type output`. No separate schema definition needed.

## `@requires` rules

**On input params** -- the param is excluded from the input schema when `can?` returns false. Tag them in the `#:` annotation above `def call`:

```ruby
#: (
#:   query: String,
#:   ?force: bool            @requires(:admin),
#:   ?include_deleted: bool  @requires(:admin)
#: ) -> Hash[Symbol, untyped]
def call(query:, force: false, include_deleted: false)
```

**On output variants** -- the variant is excluded from the `oneOf`:

```ruby
# @rbs type output = public_result
#                   | admin_result  @requires(:admin)
#                   | error
```

Untagged params and variants are always included.

## Shared types

Define reusable types as `.rbs` files in `sig/shared/` (configurable via `shared_type_paths`):

```rbs
# sig/shared/pagination.rbs
type pagination = {
  page: Integer,
  per_page: Integer,
  total: Integer
}
```

Import them in any handler:

```ruby
# @rbs import pagination
# @rbs import error

# @rbs type success = {
#   success: true,
#   items: Array[String],
#   pagination: pagination
# }

# @rbs type output = success | error
```

The compiler loads `sig/shared/pagination.rbs` and `sig/shared/error.rbs`, parses their type definitions, and merges them into the handler's type map. The handler's own `@rbs type` definitions override on conflict.

Shared types define **shapes**. Authorization (`@requires`) stays on the handler -- it's a local policy decision, not a property of the type itself.

## Tool DSL

```ruby
class MyTool < McpAuthorization::Tool
  tool_name "my_tool"
  authorization :some_flag        # tool hidden when can?(:some_flag) is false
  tags "recruiting", "operations" # which domains this tool appears in
  read_only!                      # MCP annotation hints
  dynamic_contract MyService      # handler class
end
```

| Method | Purpose |
|---|---|
| `tool_name "name"` | MCP tool name |
| `authorization :sym` | Tool-level visibility gate. Omit for public tools. |
| `tags "domain1", ...` | Domain(s) this tool appears under. Defaults to `["default"]`. |
| `dynamic_contract HandlerClass` | Handler providing description, schemas, and execution |
| `read_only!` | Annotation: tool only reads data |
| `not_destructive!` | Annotation: tool does not destroy data |
| `destructive!` | Annotation: tool may destroy data |
| `idempotent!` | Annotation: multiple calls have same effect |
| `open_world!` | Annotation: tool may access external services |
| `closed_world!` | Annotation: tool stays within the system |

Tools self-register when loaded. Put them anywhere under `tool_paths` (default: `app/mcp/`).

## Contract validation

If a handler is missing required methods or schema definitions, the gem raises an `ArgumentError` on first request with a full diagnostic:

```
MyHandler does not satisfy the McpAuthorization handler contract.

Problems:
  - missing instance method #call
  - missing instance method #description
  - missing output schema (define # @rbs type output = variant1 | variant2 | ...)

A handler class should look like:

  class MyHandler
    include McpAuthorization::DSL

    # @rbs type output = success | error

    def description
      "What this tool does"
    end

    #: (name: String, ?force: bool @requires(:admin)) -> Hash[Symbol, untyped]
    def call(name:, force: false)
      # ...
    end
  end
```

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

# Type references (resolved from local types and imports)
# @rbs type input = { id: String, status: status }
```

### Constraint and annotation tags

Tag any field in a `#:` annotation or `@rbs type` record to add JSON Schema constraints. Tags are written as `@tag(value)` after the type:

```ruby
#: (
#:   name: String                          @min(1) @max(100),
#:   email: String                         @format(email),
#:   age: Integer                          @min(0) @max(150),
#:   score: Float                          @exclusive_min(0) @exclusive_max(1.0),
#:   tags: Array[String]                   @min(1) @max(10) @unique(),
#:   quantity: Integer                     @multiple_of(5),
#:   ?timezone: String                     @default_for(:timezone),
#:   ?stage_id: String?                    @requires(:backward_routing) @depends_on(:workflow_id)
#: ) -> Hash[Symbol, untyped]
```

**Value constraints:**

| Tag | Applies to | JSON Schema |
|---|---|---|
| `@min(n)` | String, Integer, Float, Array | `minLength`, `minimum`, or `minItems` |
| `@max(n)` | String, Integer, Float, Array | `maxLength`, `maximum`, or `maxItems` |
| `@exclusive_min(n)` | Integer, Float | `exclusiveMinimum` |
| `@exclusive_max(n)` | Integer, Float | `exclusiveMaximum` |
| `@multiple_of(n)` | Integer, Float | `multipleOf` |
| `@pattern(regex)` | String | `pattern` |
| `@format(name)` | String | `format` (e.g. `email`, `uri`, `date-time`) |
| `@unique()` | Array | `uniqueItems: true` |

**Metadata:**

| Tag | JSON Schema | Purpose |
|---|---|---|
| `@desc(text)` | `description` | Field description — also used as tool-chaining hints for MCP clients |
| `@title(text)` | `title` | Human-readable title |
| `@default(value)` | `default` | Default value (`true`, `false`, `nil`, numbers, strings) |
| `@default_for(:key)` | `default` | Dynamic default resolved via `current_user.default_for(:key)` |
| `@example(value)` | `examples` | Example value (repeat for multiple: `@example(foo) @example(bar)`) |
| `@deprecated()` | `deprecated: true` | Mark as deprecated |
| `@read_only()` | `readOnly: true` | Read-only field |
| `@write_only()` | `writeOnly: true` | Write-only field |

**Authorization:**

| Tag | Purpose |
|---|---|
| `@requires(:flag)` | Field/variant excluded when `can?(:flag)` is false |
| `@depends_on(:field)` | Emits `dependentRequired` — field only required when parent field is present |

**Niche:**

| Tag | JSON Schema |
|---|---|
| `@closed()` / `@strict()` | `additionalProperties: false` |
| `@media_type(type)` | `contentMediaType` (e.g. `application/json`) |
| `@encoding(enc)` | `contentEncoding` (e.g. `base64`) |

The `@min` / `@max` tags are type-aware: on strings they emit `minLength`/`maxLength`, on numbers `minimum`/`maximum`, and on arrays `minItems`/`maxItems`.

### Multiline `#:` annotations

The `#:` annotation above `def call` supports multiple lines. Each line starts with `#:`:

```ruby
#: (
#:   applicant_id: String       @desc(Use fetch_latest_applicant to find this),
#:   workflow_id: String,
#:   ?stage_id: String?         @requires(:backward_routing) @depends_on(:workflow_id),
#:   ?reason: String?           @requires(:backward_routing)
#: ) -> Hash[Symbol, untyped]
def call(applicant_id:, workflow_id:, stage_id: nil, reason: nil)
```

Prefix a param with `?` to mark it optional. Suffix the type with `?` for nilable types. Both together (`?name: Type?`) means the field is optional and can be nil.

### `@depends_on` for conditional required fields

Use `@depends_on(:parent_field)` to express that a field is only required when another field is present. This emits JSON Schema `dependentRequired`:

```ruby
#: (
#:   workflow_id: String,
#:   ?stage_id: String?      @requires(:backward_routing) @depends_on(:workflow_id),
#:   ?reason: String?        @requires(:backward_routing) @depends_on(:stage_id)
#: ) -> Hash[Symbol, untyped]
```

When `:backward_routing` is enabled, the schema includes:
```json
{
  "dependentRequired": {
    "workflow_id": ["stage_id"],
    "stage_id": ["reason"]
  }
}
```

### Discriminated unions

Literal `true` / `false` types become `"const"` values in JSON Schema:

```ruby
# @rbs type success = { success: true, data: String }
# @rbs type error   = { success: false, code: String }
# @rbs type output  = success | error
```

MCP clients can narrow on `success: const true` vs `success: const false` -- the same pattern as TypeScript discriminated unions.

## Performance

Source files are parsed once at boot and cached in memory. Only `@requires` filtering runs per request (hash lookups and `can?` calls). In development, caches are cleared automatically on file change via the Rails reloader.

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
4. `RbsSchemaCompiler` loads shared types from `# @rbs import` declarations
5. Input schema is compiled from the `#:` annotation on `def call`, filtering `@requires` params
6. Output schema is compiled from `@rbs type output`, filtering `@requires` variants
7. MCP client receives tool definitions with schemas tailored to the current user

Different users hitting the same endpoint can see different tools, different descriptions, different input fields, and different output shapes.

## Stateless transport and schema lifetime

The gem uses the MCP SDK's Streamable HTTP transport in **stateless mode**. Each HTTP request creates a fresh `MCP::Server`, materialized with tools filtered and shaped for the current user. There is no persistent session or SSE stream between requests.

This is a deliberate choice. The gem's value is per-request schema discrimination -- the same endpoint returns different JSON Schema depending on who's asking. A stateful session would bake the tool list at connection time, meaning permission changes during a session would serve stale schemas until reconnect.

In practice this doesn't matter because MCP clients call `tools/list` once -- at the start of a conversation or when manually refreshed. The schema returned at that point is what the client (and the LLM behind it) uses for the entire conversation. Tool calls made later in the conversation still go through `context_builder` and the `authorization` gate, so a revoked permission results in a rejected call, not a leaked capability.

The tradeoff: stateless mode cannot send `notifications/tools/list_changed` or use `report_progress` during long-running tool calls, since both require an open SSE stream. For most use cases this is the right default -- schemas that reflect the current user's permissions at conversation start, enforced again at call time.

## Requirements

- Ruby >= 3.1
- Rails >= 6.0
- [mcp](https://rubygems.org/gems/mcp) ~> 0.10

## License

MIT
