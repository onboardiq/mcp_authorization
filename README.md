# mcp_authorization
[read it](https://fountain.engineering/mcp_authorization/)

Rails engine for serving MCP tools with per-request schema discrimination compiled from RBS type annotations.

Add it to your Gemfile and your Rails app speaks [MCP](https://modelcontextprotocol.io). Write `@rbs type` comments in plain Ruby service classes, tag fields and variants with `@requires(:flag)`, and the gem compiles tailored JSON Schema per request. The type definitions are the authorization policy.

> Looking for task-oriented "how do I X?" recipes rather than reference? See the **[Cookbook](COOKBOOK.md)**.

<!-- site:skip -->
> Prefer these docs as a browsable site, one section per page? **<https://fountain.engineering/mcp_authorization>** — built from these same files by [`site/collect.rb`](site/collect.rb).
<!-- site:endskip -->

## Three layers of authorization

The gem gives you three independent controls over what each user sees:

| Layer | Mechanism | Effect |
|---|---|---|
| **Tool visibility** | `authorization :manage_workflows` (RBAC) or `gate :feature, :sms` (any predicate) on the tool class | Tool hidden entirely from users who fail any check |
| **Input fields** | `@requires(:backward_routing)` or `@feature(:sms)` on a param in `#:` annotation | Field excluded from the input schema *and* stripped from inbound params at call time |
| **Output variants** | `@requires(:backward_routing)` or `@feature(:sms)` on a variant in `@rbs type output` | Variant excluded from the `oneOf` *and* fields projected out of the handler's return value before it crosses the wire |

Tool-level `authorization :perm` is RBAC (calls `current_user.can?`). Tool-level `gate :predicate, :value` and the field-level annotations are generic — any predicate name works, as long as the server context implements `{predicate}?(value)`. See [Generic predicate tags](#generic-predicate-tags) below.

### Enforcement, not just shaping

`@requires` is a security boundary, not a hint. At tool-call time the gem:

- **Filters inbound params** against the user's compiled input schema. Gated fields, and any keys not declared in the schema at all, are dropped before the handler's `#call` is invoked. A handler that takes `force:` gated behind `@requires(:admin)` will see `force: false` (its default) for non-admins even if the MCP client sends `force: true` in the raw JSON-RPC payload.
- **Projects the handler's return value** onto the user's compiled output schema. A variant hidden by `@requires` has its shape unavailable, so if the handler erroneously emits that variant's extra fields, they are stripped before serialization. A handler bug or refactor accident cannot leak admin-only fields to a non-admin.

This means handler authors don't have to remember to re-check `can?` at every branch -- the schema *is* the boundary. `can?` inside `#call` is still useful for logic that changes behavior (not just field visibility), but it is no longer load-bearing for security.

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
| `tool_producers` | `[]` | Callables that register tool classes built at runtime — see [Generated tools](#generated-tools) |
| `shared_type_paths` | `["sig/shared"]` | Directories where shared `.rbs` type files live |
| `context_builder` | *required* | `(request) -> context` |
| `cli_context_builder` | `nil` | `(domain:, role:) -> context` for rake tasks |
| `strict_schema` | `false` | Emit stricter compiled schemas |
| `tools_list_cache` | `nil` | `:memory`, `:redis`, or any object responding to `get`/`set` — see [Caching `tools/list`](#caching-toolslist) |
| `tools_list_cache_ttl` | `3600` | Per-entry TTL in seconds |
| `tools_list_cache_redis` | `nil` | Explicit Redis client for the `:redis` store |
| `tools_list_cache_redis_url` | `nil` | Explicit Redis URL; falls back to `ENV["REDIS_URL"]`, then `Redis.new` |

Two configuration **methods** (not attributes) turn a domain into grouped facades — see [Tool grouping](#tool-grouping-facades):

| Method | Purpose |
|---|---|
| `facet_domain :domain, group_by: :category, ...` | Present this domain as one facade tool per category. Optional `schema_strategy:`, `uncategorized:`, `facade_suffix:`. |
| `categories { summary :key, "text" }` | Declare one summary line per group, used as each facade description's lead. |

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
  authorization :some_flag        # RBAC: hidden unless current_user.can?(:some_flag)
  gate :feature, :order_tracking  # any predicate: hidden unless server_context.feature?(:order_tracking)
  gate :tier, :enterprise         # multiple gates AND together
  tags "recruiting", "operations" # which domains this tool appears in
  category :orders                # group this tool belongs to in a faceted domain
  read_only!                      # MCP annotation hints
  dynamic_contract MyService      # handler class
end
```

| Method | Purpose |
|---|---|
| `tool_name "name"` | MCP tool name |
| `authorization :sym` | Tool-level RBAC visibility gate. Convenience alias for `gate :requires, :sym` — routes through the generic gate pipeline and falls back to `current_user.can?(:sym)` when the server context lacks a `requires?` method. Omit for public tools. |
| `gate :predicate, :value` | Tool-level generic predicate gate. Calls `server_context.{predicate}?(value)`. Repeat for AND. Fail-open when the predicate method is missing (warning logged in dev). |
| `tags "domain1", ...` | Domain(s) this tool appears under. Defaults to `["default"]`. |
| `category :name` | Group this tool belongs to when its domain is faceted (see [Tool grouping](#tool-grouping-facades)). Ignored in flat domains. Optional `summary:` kwarg supplies the group summary for single-tool groups. |
| `dynamic_contract HandlerClass` | Handler providing description, schemas, and execution |
| `read_only!` | Annotation: tool only reads data |
| `not_destructive!` | Annotation: tool does not destroy data |
| `destructive!` | Annotation: tool may destroy data |
| `idempotent!` | Annotation: multiple calls have same effect |
| `open_world!` | Annotation: tool may access external services |
| `closed_world!` | Annotation: tool stays within the system |

`authorization :perm` is just a convenience for `gate :requires, :perm` — internally there is one gate pipeline, not two. Multiple `gate` declarations AND together with `authorization`: the tool is shown only when every check passes. This makes tool-level gating symmetric with the field-level annotations (`@requires`, `@feature`, any custom predicate).

Tools self-register when loaded. Put them anywhere under `tool_paths` (default: `app/mcp/`).

### Generated tools

Some tools aren't worth writing by hand — one per controller action, one per row in a config table, one per endpoint in a family. For those, register a **producer**: a callable that mints the classes and registers them.

```ruby
McpAuthorization.configure do |config|
  config.tool_producers << -> { MyApp::GeneratedTools.register_all! }
end
```

Producers run from `ToolRegistry.ensure_tools_loaded!` — on the first read of an empty registry, immediately after `tool_paths` is eager-loaded, and again after every reload. Two properties follow from that, and both matter:

- **Don't register from a Rails boot callback instead.** Generating tools usually means loading the code they derive from, and from `config.to_prepare` that happens during `:run_prepare_callbacks` — before `:eager_load!`, and before railties copy `config.i18n` onto `I18n`. Application code loaded that early sees an empty `I18n.load_path`, so any class resolving a translation in its class body freezes `"Translation missing: …"` into its validators and option lists for the life of the process. A producer sidesteps the ordering question entirely.
- **Don't register before the registry loads its own tools.** Historically `ensure_tools_loaded!` skipped the `tool_paths` pass once the registry was non-empty, so registering first made every file-defined tool silently disappear from `tools/list`. Producers run *after* that pass, and completion is now tracked separately from "the registry has entries", so the ordering is not yours to get right.

A producer must be **idempotent**. `register` dedupes by object identity, not by `tool_name`, so minting a fresh class on every call registers a second tool under the same name and leaves `find_tool` resolving an arbitrary one. Reuse the class while its inputs are unchanged. Exceptions propagate — a malformed generated tool fails the read rather than vanishing.

When the host eager-loads (production), the engine reads the registry at `after_initialize`, so a producer that raises fails the deploy instead of the first `tools/list`. Development and test stay lazy.

### Introspecting a tool class

Every declaration is readable back off the class, which is what the registry, the facade builder, and the cache digest use:

| Reader | Returns |
|---|---|
| `_permission` | The symbol passed to `authorization` |
| `_gates` | `[{ name:, value: }, ...]` for every declared gate |
| `_tags` | Declared domains |
| `_category` | Declared category symbol, or `nil` |
| `_category_summary` | Summary passed to `category(summary:)`, or `nil` |
| `_contract_handler` | The handler class |

`ToolRegistry` is the entry point for turning those declarations into MCP tools:

| Registry method | Purpose |
|---|---|
| `tool_classes_for(domain:, server_context:)` | Every permitted tool in a domain (the `tools/list` path) |
| `tool_class_for(domain:, name:, server_context:)` | One named tool, or `nil` (the `tools/call` path) |
| `facades_for(domain:, server_context:)` | Facades for a faceted domain |
| `facade_for(domain:, name:, server_context:)` | One facade by name |

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

## Tool grouping (facades)

As a domain grows into the hundreds of tools, a flat `tools/list` spends the
selection prompt on call-time schemas instead of routing signal. A domain can
opt into **grouped facades**: one tool per category, with a routing-only
description and per-tool schemas deferred out of the listing.

```ruby
class ListOrdersTool < McpAuthorization::Tool
  tags "admin"
  category :orders                    # the group this tool belongs to
  dynamic_contract OrderHandlers::List
end

McpAuthorization.configure do |config|
  config.facet_domain :admin, group_by: :category

  config.categories do
    summary :orders,  "Create, inspect, and update orders and their line items."
    summary :billing, "Invoices, payments, refunds, and billing profiles."
  end
end
```

Grouping is opt-in and per-domain: a domain with no `facet_domain` behaves
exactly as before, and `category` is inert there. `facet_domain` takes:

| Option | Default | Description |
|---|---|---|
| `group_by:` | *required* | Grouping key. Only `:category` today; anything else raises `ArgumentError`. |
| `schema_strategy:` | `:vendor_extension` | Where per-tool argument schemas go — `:vendor_extension` or `:lazy` (below). |
| `uncategorized:` | `:fallback` | `:fallback` collects tools with no `category` into an `uncategorized` group; `:error` raises instead. |
| `facade_suffix:` | `"tools"` | Token appended to a category to form the facade name (`orders_tools`). |

For a group that holds a single tool, `category :orders, summary: "..."` saves a
trip to the central registry. When both are declared, `config.categories` wins.

`tools/list` for the domain then returns one facade per group the caller has
at least one permitted tool in (`orders_tools`, `billing_tools`), each
describing its tools with RBAC-filtered one-liners. Calling a facade names the
inner tool and its arguments:

```json
{ "name": "orders_tools",
  "arguments": { "tool_name": "update_order", "arguments": { "id": "o_1" } } }
```

### Facade shape

| Part | Value |
|---|---|
| Name | `"#{category}_#{facade_suffix}"` — default suffix `tools`, so `orders_tools` |
| Description | Group summary, then one line per tool the caller may invoke: `- tool_name — first line of that tool's description for this caller` |
| `inputSchema` | Flat object: `tool_name` (string enum of permitted tool names) + `arguments` (object). Both required. |
| `_meta` | Under `:vendor_extension`, key `"tool-input-schemas"` — a map of tool name to that caller's compiled input schema |

### Facade dispatch

Dispatch resolves the real tool through its normal call path — there is no
second code path, and therefore no second place for authorization to be wrong:

1. **Advertised-set check.** `tool_name` must be in the set advertised to *this*
   caller, else `ArgumentError` listing the valid names.
2. **Re-resolution.** The tool is re-fetched via `ToolRegistry.tool_class_for`,
   which re-runs `permitted?` — so a stale advertised set cached by a client
   cannot get a caller into a tool they've lost access to. Failure raises
   `NotAuthorizedError`.
3. **Argument coercion.** MCP clients frequently serialize nested objects as JSON
   strings, and the facade's generic `arguments: object` contract cannot know
   which fields are structured. The `arguments` blob itself, and any top-level
   value whose type in the *target's* compiled schema is `object` or `array`, are
   JSON-parsed. Invalid JSON raises `ArgumentError` naming the field.
4. **Delegation.** The target's materialized `call` runs, applying `filter_input`
   and `filter_output` exactly as in a direct call.

Direct tool names still resolve on `tools/call`, so a client that learned a
real tool name before the domain was faceted keeps working.

A `tools/call` build skips the `_meta` per-tool schema map (`for_dispatch: true`)
— nothing on the call path reads it, and building it would recompile every tool
in the group on every call.

The facade `inputSchema` is always a flat object (a `tool_name` enum plus a
permissive `arguments` object). It has to be: an LLM tool `input_schema` must
have an object root — Anthropic and OpenAI reject `oneOf`/`allOf`/`anyOf` at the
top level — and hosts routinely forward a facade's `inputSchema` straight to the
model. A correlated inline shape (each `tool_name` tied to its own argument
schema) would need a root combinator, so it is not offered. `schema_strategy:`
therefore only chooses where the per-tool schemas go:

- `:vendor_extension` (default) — the per-tool schemas are carried on the
  facade's `_meta` (key `"tool-input-schemas"`). `_meta` is the MCP-sanctioned
  extension channel: SDKs preserve it and it is never forwarded to the model as
  the tool `input_schema`, so the schemas stay available in-band for a client
  that wants to expand the facade, without touching `inputSchema`.
- `:lazy` — names and one-liners only; argument shapes are enforced at dispatch
  by the target tool's own `filter_input`.

Uncategorized tools land in an `uncategorized` facade by default; pass
`uncategorized: :error` to fail fast instead. Groups with zero permitted tools
are hidden entirely, so a facade never advertises an empty `enum`. A facade
name that collides with a real registered tool in the domain raises
`FacadeBuilder::FacadeNameCollisionError` rather than shadowing that tool.

Facade names are `#{category}_tools` by default. Override the suffix per domain
with `facade_suffix:` — e.g. `config.facet_domain :admin, group_by: :category,
facade_suffix: "hire"` exposes `orders_hire`, `billing_hire`. The suffix must be
a lowercase identifier fragment (`[a-z0-9_]`) so the derived name stays a valid
MCP tool name. See [the design doc](docs/designs/tool-grouping-facades.md) for
the full rationale.

Facet configuration participates in the [`tools/list` cache](#caching-toolslist)
digest — each tool's `category`, every `facet_domain` setting, and every group
summary — so toggling grouping or rewording a summary invalidates cached
listings the same way a gate change does.

### Facade errors

| Error | Raised when |
|---|---|
| `FacadeBuilder::UncategorizedToolError` | A tool has no `category` in a domain faceted with `uncategorized: :error` |
| `FacadeBuilder::FacadeNameCollisionError` | A derived facade name collides with a registered tool in the domain |
| `ArgumentError` (config) | Invalid `group_by:`, `schema_strategy:`, `uncategorized:`, or `facade_suffix:` |
| `ArgumentError` (dispatch) | `tool_name` not advertised, or a string argument that isn't valid JSON |
| `NotAuthorizedError` | Re-resolution found the caller isn't permitted after all |

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
#   ?count: Integer
# }
# (?count is optional -- excluded from "required")

# Arrays
# @rbs type items = Array[String]

# Type references (resolved from local types and imports)
# @rbs type input = { id: String, status: status }
```

Every handler must declare `@rbs type output`. It may be a single record, a reference, or a union:

```ruby
# @rbs type output = { id: String }        # inline record
# @rbs type output = applicant             # reference
# @rbs type output = success | error       # union
```

When a type appears more than once in a compiled schema, it is hoisted into `$defs` and referenced with `$ref` rather than inlined repeatedly. This is automatic — nothing to declare.

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

**Authorization & predicate filters:**

| Tag | Purpose |
|---|---|
| `@requires(:flag)` | Field/variant excluded when `server_context.requires?(:flag)` returns false. Legacy fallback: if `requires?` is not defined, falls back to `current_user.can?(:flag)`. |
| `@feature(:flag)` | Field/variant excluded when `server_context.feature?(:flag)` returns false (account-level feature flags) |
| `@depends_on(:field)` | Emits `dependentRequired` — field only required when parent field is present |

Any `@tag(:value)` not in the known constraint list above is a **generic predicate filter**. At schema compile time, the gem calls `server_context.tag_name?(value)` — if it returns false, the field is excluded. If `server_context` doesn't respond to the method, the predicate is skipped (permissive).

This makes the gem infinitely extensible. Define any predicate on your server context:

```ruby
# In your app's server context:
def requires?(flag) = current_user.can?(flag.to_sym)
def feature?(flag) = current_account.feature_enabled?(flag.to_s)
def tier?(name) = current_account.plan_tier?(name.to_s)
def beta?(flag) = current_account.beta_enrolled?(flag.to_s)

# In your handler:
#: (?status: "active" | "inactive" | "unlisted" @feature(:opening_status_v2)) -> output
#: (?force: bool @requires(:admin) @tier(:enterprise)) -> output
```

Multiple predicates on the same field are AND-ed — all must pass for the field to appear.

### Tool-level gates

The same predicate vocabulary is available at the **tool wrapper** level via `gate :predicate, :value`:

```ruby
class BulkSendSmsTool < McpAuthorization::Tool
  authorization :communications  # RBAC permission
  gate :feature, :sms            # hide tool unless account has SMS configured
  gate :requires, :super_user    # extra RBAC check beyond authorization
end
```

`gate` is the tool-level counterpart of `@predicate(:value)` on a field. Semantics:

- Calls `server_context.{predicate_name}?(value)` at request time.
- All gates AND together with `authorization`. The tool is shown only when every check passes.
- Fail-open when the predicate method is missing on the server context (warning logged in development).
- `gate :requires, :perm` falls back to `current_user.can?(:perm)` when the context lacks a `requires?` method (matching the field-level backward-compat path).
- Exceptions raised by a predicate are rescued and logged — a broken predicate never crashes `tools/list`.

**Niche:**

| Tag | JSON Schema |
|---|---|
| `@closed()` / `@strict()` | `additionalProperties: false` |
| `@media_type(type)` | `contentMediaType` (e.g. `application/json`) |
| `@encoding(enc)` | `contentEncoding` (e.g. `base64`) |

The `@min` / `@max` tags are type-aware: on strings they emit `minLength`/`maxLength`, on numbers `minimum`/`maximum`, and on arrays `minItems`/`maxItems`.

### Where tags may appear

| Position | Effect |
|---|---|
| On a param in `#:` | Constrains or gates that input field |
| On a field in an `@rbs type` record | Constrains or gates that output field |
| On a member of an `@rbs type` union | Gates that whole output variant |
| On an inline literal union member | Gates that individual member |

A tag trailing a whole inline literal union applies to the **field**, not to the last member — the compiler distinguishes the two by whether any non-final member carries a tag.

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

Per-request work is also scoped to what the incoming JSON-RPC method actually needs, since per-tool schema compilation is the dominant cost of an MCP request:

| Method | Tools materialized |
|---|---|
| `tools/list` | Every permitted tool in the domain |
| `tools/call` | Only the invoked tool |
| `initialize`, `notifications/initialized`, `ping`, GET stream probe | None |
| Unrecognized shape (e.g. a batch with no top-level `method`) | Full domain, so routing stays correct |

In a 140-tool domain that took a `tools/call` from ~2.6s to under 100ms and `notifications/initialized` from ~2s to ~1ms, with no change to `tools/list` output. What remains is the listing itself — which is cacheable (below) and, for very large domains, [groupable](#tool-grouping-facades).

## Caching `tools/list`

`tools/list` must materialize a per-user schema for every tool in a domain. That cost can be cached. Default is no caching, so nothing changes unless you opt in:

```ruby
McpAuthorization.configure do |c|
  c.tools_list_cache = :redis          # or :memory, or any object responding to get/set
  c.tools_list_cache_ttl = 3600        # seconds (default)
end
```

| Store | Behavior |
|---|---|
| `:memory` | Process-local, bounded LRU with per-entry TTL |
| `:redis` | Shared across processes, JSON values, per-entry TTL |
| custom object | Anything responding to `get`/`set` |
| *(unset)* | `NullStore` — no caching |

The Redis connection resolves from an explicit client (`tools_list_cache_redis`), then `tools_list_cache_redis_url`, then `ENV["REDIS_URL"]`, then a bare `Redis.new` — i.e. it defaults to the host's Rails redis config with no extra wiring. `redis` is an optional dependency, required lazily only when the Redis store is used.

### The key is a decision vector, not an identity

```
H(domain + tool_defs_digest + vocab_fingerprint + decision_vector)
```

The **decision vector** is the result of every gating decision the domain's compilation consults — `@requires` / `@feature` / `@tier` / custom predicates, tool-level `gate` and `authorization`, and `current_user.can?` / `default_for`. It never includes user or account identity.

Two contexts that answer all of those identically produce identical schemas by construction, so they share an entry. Flip one feature flag and the vector — and the key — change, so an admin in a flag-on account never receives a flag-off account's tools. The `tool_defs_digest` (each tool's gates plus handler source, plus facet configuration) changes on deploy, auto-invalidating stale entries; the TTL bounds out-of-band staleness, such as a permission changed directly in the database.

### Two ways to supply the vector

**Automatic.** On the first (cold) compile the gem wraps the context in a `Cache::Recorder`, learns the domain's predicate vocabulary, then replays that vocabulary against the live context on later requests.

**Explicit.** If the server context responds to `mcp_cache_fingerprint`, its return value is used verbatim as the decision component and the recorder is skipped:

```ruby
class ServerContext
  def mcp_cache_fingerprint
    [current_user.role, account.enabled_features.sort, account.plan_tier]
  end
end
```

Explicit wins when present. Reach for it when gating depends on something the recorder cannot observe, or when you would rather own the invalidation contract than infer it.

### Operational notes

- **Cache outages fail open** — a `get`/`set` error is logged and behaves as a miss, never breaking `tools/list`.
- **Only successful listings are cached.** Error and unexpected responses render but are not stored.
- **A hit still rebuilds the envelope** — the cached `result` is re-wrapped with the live JSON-RPC id.
- **Development reloads clear it** (the reloader calls `Cache.reset!`), so an edited annotation shows up immediately.

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
