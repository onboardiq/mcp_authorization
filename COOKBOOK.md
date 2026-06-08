# mcp_authorization Cookbook

Task-oriented recipes. The [README](README.md) is the reference — this is "I want to do X, what do I write?"

Every recipe is a complete, copy-pasteable snippet. They build on the handler-example app (a recruiting-workflow server, not yet published as a standalone repo) with three roles — **viewer** (`view_workflows`), **operator** (`manage_workflows`), and **manager** (`manage_workflows` + `backward_routing`).

The mental model, in one line: **your RBS type annotations are the authorization policy.** You don't reject requests — you compile a different schema per user, and the gem enforces it on the way in and on the way out.

## Recipes

- [1. Expose your first tool (read-only, end to end)](#1-expose-your-first-tool-read-only-end-to-end)
- [2. Hide an entire tool behind a permission](#2-hide-an-entire-tool-behind-a-permission)
- [3. Hide a tool behind an account feature, not a role](#3-hide-a-tool-behind-an-account-feature-not-a-role)
- [4. Hide one input field from some users](#4-hide-one-input-field-from-some-users)
- [5. Give privileged users a richer output shape](#5-give-privileged-users-a-richer-output-shape)
- [6. Pre-fill a field from the current user](#6-pre-fill-a-field-from-the-current-user)
- [7. Validate input with constraints](#7-validate-input-with-constraints)
- [8. Share a type across handlers](#8-share-a-type-across-handlers)
- [9. Model success-or-error as a discriminated union](#9-model-success-or-error-as-a-discriminated-union)
- [10. Require a field only when another is present](#10-require-a-field-only-when-another-is-present)
- [11. Change the tool description by role](#11-change-the-tool-description-by-role)
- [12. Serve different tool surfaces from one app (domains)](#12-serve-different-tool-surfaces-from-one-app-domains)
- [13. Invent your own predicate vocabulary](#13-invent-your-own-predicate-vocabulary)
- [14. See exactly what a role sees (debugging)](#14-see-exactly-what-a-role-sees-debugging)
- [15. Mark a tool read-only / destructive (annotation hints)](#15-mark-a-tool-read-only--destructive-annotation-hints)

**Talking to the outside world**

- [16. Query a database from a tool](#16-query-a-database-from-a-tool)
- [17. Talk to a TCP socket from a tool](#17-talk-to-a-tcp-socket-from-a-tool)

---

## 1. Expose your first tool (read-only, end to end)

**Problem.** You have a Rails app and want one MCP tool that returns data. No auth subtleties yet.

**Solution.** Three files: a handler (logic + schema), a tool wrapper (declaration), and the one-time config.

```ruby
# app/service/workflows/fetch_latest_applicant.rb
module Workflows
  class FetchLatestApplicant
    include McpAuthorization::DSL

    # @rbs type output = {
    #   applicant_id: String,
    #   name: String,
    #   current_stage: String
    # }

    def description
      "Fetch the most recent applicant in the workflow."
    end

    #: (workflow_id: String) -> Hash[Symbol, untyped]
    def call(workflow_id:)
      { applicant_id: "app-42", name: "Jane Doe", current_stage: "screening" }
    end
  end
end
```

```ruby
# app/mcp/workflows/fetch_latest_applicant_tool.rb
module Workflows
  class FetchLatestApplicantTool < McpAuthorization::Tool
    tool_name "fetch_latest_applicant"
    read_only!
    dynamic_contract Workflows::FetchLatestApplicant
  end
end
```

```ruby
# config/initializers/mcp_authorization.rb
McpAuthorization.configure do |config|
  config.server_name = "my-app"
  config.context_builder = ->(request) {
    user = User.authenticate(request.headers["Authorization"])
    OpenStruct.new(current_user: user)  # works for a sketch; prefer a real context class — see recipe 14
  }
end
```

**Result.** Routes mount automatically at `/mcp`. `POST /mcp` now answers MCP `tools/list` and `tools/call`. The input schema comes from the `#:` line; the output schema from `@rbs type output`. You wrote no JSON Schema.

> A handler must define `description` and `call`, and declare `@rbs type output`. Miss one and the gem raises an `ArgumentError` with a worked example on first request.

---

## 2. Hide an entire tool behind a permission

**Problem.** Only users who can `manage_workflows` should even *see* the `advance_step` tool. Everyone else gets a clean tool list with no hint it exists.

**Solution.** Add `authorization` to the tool wrapper. This is RBAC — it calls `current_user.can?`.

```ruby
# app/mcp/workflows/advance_step_tool.rb
module Workflows
  class AdvanceStepTool < McpAuthorization::Tool
    tool_name "advance_step"
    authorization :manage_workflows   # hidden unless current_user.can?(:manage_workflows)
    dynamic_contract Workflows::AdvanceStep
  end
end
```

**Result.** A viewer's `tools/list` omits `advance_step` entirely. An operator's includes it. The check also runs at call time, so a viewer who hand-crafts a `tools/call` for it is rejected, not served.

---

## 3. Hide a tool behind an account feature, not a role

**Problem.** Visibility shouldn't depend on the user's role but on whether their *account* has SMS provisioned. RBAC is the wrong axis.

**Solution.** Use `gate :predicate, :value`. It calls `server_context.{predicate}?(value)` instead of `current_user.can?`. Gates AND with `authorization`.

```ruby
class BulkSendSmsTool < McpAuthorization::Tool
  tool_name "bulk_send_sms"
  authorization :communications   # RBAC: user must be allowed to message
  gate :feature, :sms             # AND account must have SMS configured
  dynamic_contract Comms::BulkSendSms
end
```

```ruby
# Your server context object needs the matching predicate:
class ServerContext
  def feature?(name) = account[:features].include?(name.to_s)
end
```

**Result.** The tool appears only when the user passes the RBAC check *and* `server_context.feature?(:sms)` returns true. If your context doesn't define `feature?` at all, the gate **fails open** (with a dev-mode warning) — so a missing predicate never silently hides everything.

---

## 4. Hide one input field from some users

**Problem.** `advance_step` should let managers jump an applicant to *any* stage via a `stage_id` param — but operators shouldn't even see that the parameter exists.

**Solution.** Tag the param with `@requires(:flag)` in the `#:` annotation. The whole tool stays visible; only the field disappears.

```ruby
#: (
#:   applicant_id: String,
#:   workflow_id: String,
#:   ?stage_id: String?    @requires(:backward_routing)
#: ) -> Hash[Symbol, untyped]
def call(applicant_id:, workflow_id:, stage_id: nil)
  # ...
end
```

**Result.**

| Role | Input fields the LLM sees |
|---|---|
| operator (no `backward_routing`) | `applicant_id`, `workflow_id` |
| manager (has `backward_routing`) | `applicant_id`, `workflow_id`, `stage_id` |

This is enforced, not cosmetic. If an operator's client sends `stage_id` in the raw JSON-RPC anyway, the gem **strips it before `#call` runs** — the handler sees `stage_id: nil`. You don't have to re-check `can?` inside the method.

> `?stage_id` (leading `?`) = optional param. `String?` (trailing `?`) = nilable type. Together: optional *and* may be nil.

---

## 5. Give privileged users a richer output shape

**Problem.** When a manager reroutes an applicant, the response should include `previous_stage` and an `audit_trail`. Operators should never receive those fields — not even if a handler bug tries to emit them.

**Solution.** Define two output variants and tag the privileged one with `@requires`.

```ruby
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
```

**Result.** An operator's output schema is `success | error`. A manager's is `success | rerouted_success | error`. The enforcement bite: the gem **projects the handler's return value onto the caller's compiled output schema**. If your `call` returns `audit_trail` to an operator by mistake, the field is stripped before it crosses the wire. A refactor accident can't leak privileged fields.

---

## 6. Pre-fill a field from the current user

**Problem.** Most users operate on one default workflow. You want the schema's `default` for `workflow_id` to be *that user's* default, not a hardcoded constant.

**Solution.** Tag with `@default_for(:key)` and implement `default_for` on your user.

```ruby
#: (
#:   applicant_id: String,
#:   workflow_id: String   @default_for(:workflow_id)
#: ) -> Hash[Symbol, untyped]
```

```ruby
class CurrentUser
  def default_for(key)
    case key
    when :workflow_id then defaults[:workflow_id]
    end
  end
end
```

**Result.** A manager's schema shows `"default": "wf-executive-hiring"`; an operator's shows `"default": "wf-standard-hiring"`. Same param, personalized default, resolved per request. `default_for` is optional — skip the tag and you never need the method.

> Want a *static* default instead? Use `@default(value)` — it takes literals: `true`, `false`, `nil`, numbers, or strings.

---

## 7. Validate input with constraints

**Problem.** You want the schema to enforce shape — a pattern on an ID, a length range on a reason, a numeric bound — so the LLM gets it right the first time and bad input never reaches `call`.

**Solution.** Stack constraint tags after the type. They're type-aware: `@min`/`@max` become `minLength`, `minimum`, or `minItems` depending on the field's type.

```ruby
#: (
#:   applicant_id: String   @pattern(^app-\d+$) @desc(Use fetch_latest_applicant to get this ID),
#:   workflow_id: String    @min(1) @max(50),
#:   email: String          @format(email),
#:   priority: Integer      @min(1) @max(5),
#:   ?reason: String?       @min(10) @max(500),
#:   ?tags: Array[String]   @max(10) @unique()
#: ) -> Hash[Symbol, untyped]
```

**Result.** Each tag maps to its JSON Schema keyword: `pattern`, `minLength`/`maxLength`, `format`, `minimum`/`maximum`, `maxItems`, `uniqueItems`. `@desc(...)` becomes the field `description` — and doubles as a tool-chaining hint to the LLM ("call X first to get this value").

Full tag table lives in the [README](README.md#constraint-and-annotation-tags). The common ones: `@min @max @exclusive_min @exclusive_max @multiple_of @pattern @format @unique @desc @title @example @deprecated`.

---

## 8. Share a type across handlers

**Problem.** Every tool returns the same `error` shape and the same `applicant` record. You don't want to redeclare them in each handler.

**Solution.** Put plain RBS in `sig/shared/` (no comment markers — these are real `.rbs` files), then `# @rbs import` them.

```rbs
# sig/shared/applicant.rbs
type applicant = {
  id: String,
  name: String,
  current_stage: String,
  applied_at: String
}
```

```rbs
# sig/shared/error.rbs
# `code` is an open String: every domain returns its own failure codes
# (recruiting uses "applicant_not_found"/"stage_transition_invalid"/...,
# the database and socket recipes below add "query_failed"/"host_not_allowed").
# Narrow it per domain when you want the schema to enumerate them — see Result.
type error = {
  success: false,
  error: { code: String, message: String, hint: String }
}
```

```ruby
# In any handler:
# @rbs import applicant
# @rbs import error

# @rbs type success = { success: true, applicant: applicant }
# @rbs type output  = success | error
```

**Result.** The compiler loads the `.rbs` files, merges their types into the handler's type map, and a handler's own `@rbs type` wins on name conflict. Shared types define **shapes only** — keep `@requires` on the handler, since authorization is a local policy decision, not a property of the type. Leaving `code` an open `String` keeps the shared shape honest across domains; if you want one domain's schema to *enumerate* its codes, narrow it locally with a string-literal union, which compiles to a JSON Schema `enum`:

```ruby
# @rbs type error_code = "applicant_not_found" | "stage_transition_invalid" | "already_at_stage"
# @rbs type error = { success: false, error: { code: error_code, message: String, hint: String } }
```

---

## 9. Model success-or-error as a discriminated union

**Problem.** You want the LLM to reliably tell a success response from an error and branch on it — like a TypeScript discriminated union.

**Solution.** Use literal `true`/`false` on a shared key. They compile to JSON Schema `const`.

```ruby
# @rbs type success = { success: true,  applicant_id: String, current_stage: String }
# @rbs type output  = success | error      # error has success: false
```

Return the matching shape from `call`, and give callers a recoverable error:

```ruby
def call(applicant_id:, workflow_id:)
  applicant = find_applicant(applicant_id)
  return not_found_error(applicant_id) unless applicant
  { success: true, applicant_id: applicant_id, current_stage: "screening" }
end

def not_found_error(id)
  {
    success: false,
    error: {
      code: "applicant_not_found",
      message: "No applicant found with ID #{id}",
      hint: "Use fetch_latest_applicant to get a valid ID before retrying."
    }
  }
end
```

**Result.** The `oneOf` carries `"success": { "const": true }` vs `{ "const": false }`. Clients narrow on it exactly like `if (res.success)`. The `hint` field is gold for agents — it tells the model how to recover instead of giving up.

---

## 10. Require a field only when another is present

**Problem.** `reason` is meaningless without `stage_id`. You want "if `stage_id` is provided, `reason` becomes required" — without making either unconditionally required.

**Solution.** `@depends_on(:other_field)`. It emits JSON Schema `dependentRequired`.

```ruby
#: (
#:   workflow_id: String,
#:   ?stage_id: String?   @requires(:backward_routing) @depends_on(:workflow_id),
#:   ?reason: String?     @requires(:backward_routing) @depends_on(:stage_id)
#: ) -> Hash[Symbol, untyped]
```

**Result.** For a manager, the schema includes:

```json
{ "dependentRequired": { "workflow_id": ["stage_id"], "stage_id": ["reason"] } }
```

Note both fields are *also* gated by `@requires` — tags stack and AND together. An operator sees neither field nor the dependency.

---

## 11. Change the tool description by role

**Problem.** The same tool does more for managers. You want its one-line description to reflect that, so the LLM understands the fuller capability when it's available.

**Solution.** `description` is a regular method — branch on `can?`.

```ruby
def description
  if can?(:backward_routing)
    "Advance an applicant to any stage, or reroute them backward in the workflow."
  else
    "Advance an applicant to the next stage in their workflow."
  end
end
```

**Result.** Managers and operators get descriptions matched to the schema each can actually use. `can?` is provided by `McpAuthorization::DSL` and delegates to `current_user.can?`.

---

## 12. Serve different tool surfaces from one app (domains)

**Problem.** One Rails app, but you want a `recruiting` tool surface and an `operations` tool surface at different URLs, each exposing its own set of tools.

**Solution.** Tag tools with one or more domains; route by the `:domain` path segment.

```ruby
class FetchLatestApplicantTool < McpAuthorization::Tool
  tool_name "fetch_latest_applicant"
  tags "recruiting"                    # only on /mcp/recruiting
  dynamic_contract Workflows::FetchLatestApplicant
end

class ReconcileLedgerTool < McpAuthorization::Tool
  tool_name "reconcile_ledger"
  tags "operations", "finance"          # on both /mcp/operations and /mcp/finance
  dynamic_contract Ops::ReconcileLedger
end
```

**Result.**

```
POST /mcp/recruiting   -> tools tagged "recruiting"
POST /mcp/operations   -> tools tagged "operations"
POST /mcp              -> tools tagged with config.default_domain
```

Point different MCP clients at different URLs. Untagged tools default to `["default"]`. Domain filtering composes with everything above — a tool must match the domain *and* pass its gates.

---

## 13. Invent your own predicate vocabulary

**Problem.** `@requires` (RBAC) and `@feature` (account flags) aren't enough. You want to gate on plan tier, beta enrollment, A/B bucket — whatever your domain needs.

**Solution.** Any `@name(value)` that isn't a known constraint tag is a **generic predicate**. At compile time the gem calls `server_context.{name}?(value)`. Define the predicates on your context; use the tags freely.

```ruby
# Your server context — one method per predicate you want to use:
class ServerContext
  def requires?(flag) = current_user.can?(flag.to_sym)
  def feature?(flag)  = account.feature_enabled?(flag.to_s)
  def tier?(name)     = account.plan_tier?(name.to_s)
  def beta?(flag)     = account.beta_enrolled?(flag.to_s)
end
```

```ruby
# Use them on fields...
#: (
#:   ?status: "active" | "inactive" | "unlisted"  @feature(:opening_status_v2),
#:   ?bulk_limit: Integer                          @tier(:enterprise),
#:   ?experimental_ranking: bool                   @beta(:ranking_v2)
#: ) -> Hash[Symbol, untyped]

# ...and on whole tools, via gate:
class ExportEverythingTool < McpAuthorization::Tool
  gate :tier, :enterprise
  gate :beta, :bulk_export
end
```

**Result.** Multiple predicates on one field AND together — all must pass for the field to appear. If the context doesn't respond to a predicate method, it's skipped (permissive at the field level; fail-open at the tool level with a dev warning). One pipeline, infinite vocabulary.

---

## 14. See exactly what a role sees (debugging)

**Problem.** You added `@requires` tags and want to confirm an operator really can't see `stage_id` — without wiring up a client and forging auth headers.

**Solution.** Set `cli_context_builder`, then use the bundled rake tasks.

```ruby
# config/initializers/mcp_authorization.rb
config.cli_context_builder = ->(domain:, role:) {
  role_config = ROLES.fetch(role, ROLES["viewer"])
  user = CurrentUser.new(
    id: "cli", name: role_config[:name], role: role.to_sym,
    permissions: role_config[:permissions], defaults: role_config[:defaults] || {}
  )
  ServerContext.new(current_user: user)
}
```

```sh
# What does each role see?
bundle exec rake "mcp:tools[operator,operator]"   # domain=operator, role=operator
bundle exec rake "mcp:tools[operator,manager]"    # same domain, manager role

# Print Claude Code / Desktop config JSON for live testing
bundle exec rake "mcp:claude[operator,manager]"

# Launch the MCP Inspector UI (needs npx)
bundle exec rake "mcp:inspect[operator,manager]"
```

**Result.** `mcp:tools` prints each visible tool with its input field names and output variant shapes — so you can diff operator vs manager at a glance and confirm the gate works. This is the fastest feedback loop while authoring schemas.

---

## 15. Mark a tool read-only / destructive (annotation hints)

**Problem.** You want to advertise behavioral hints — this tool only reads, that one might delete — so clients can warn users or auto-approve safe calls.

**Solution.** Declarative bangs on the tool wrapper. These map to standard MCP tool annotations.

```ruby
class FetchLatestApplicantTool < McpAuthorization::Tool
  tool_name "fetch_latest_applicant"
  read_only!            # only reads data
  dynamic_contract Workflows::FetchLatestApplicant
end

class AdvanceStepTool < McpAuthorization::Tool
  tool_name "advance_step"
  not_destructive!      # mutates, but doesn't destroy
  idempotent!           # repeat calls = same effect
  dynamic_contract Workflows::AdvanceStep
end
```

**Result.** The hints ride along in the tool definition. Full set: `read_only!`, `destructive!`, `not_destructive!`, `idempotent!`, `open_world!` (touches external services), `closed_world!` (stays in-system). They're advisory metadata — not a security boundary. For *security*, reach for `authorization`, `gate`, and `@requires`.

---

## Talking to the outside world

Every recipe so far returned a canned hash. Real handlers do I/O — they query databases and open sockets. The gem doesn't get in the way: a handler is a plain Ruby object running inside your Rails process, so you have ActiveRecord, connection pools, and the standard library. Two things stay your job, and the next two recipes are mostly about them:

> **The input is hostile.** Every param value originates from an LLM, which is steered by whoever is talking to it. Treat `query:`, `host:`, and friends exactly as you'd treat a raw HTTP param: never interpolate them into SQL, never open a connection to an attacker-chosen address without an allowlist. Schema constraints (`@pattern`, `@format`, `@min`) narrow the shape but do **not** make a value trusted.
>
> **Connections don't survive the request.** The transport is stateless — each MCP request builds a fresh server (see [README: Stateless transport](README.md#stateless-transport-and-schema-lifetime)). Open what you need inside `call`, use it, close it. Don't stash a socket in an instance variable hoping to reuse it next call; there is no next call on this object.

---

## 16. Query a database from a tool

**Problem.** `search_applicants` should hit the real database, filter by what the LLM asked for, and return only the columns this user is allowed to see.

**Solution.** You're inside Rails — use ActiveRecord. Build the query with the relation API (which parameterizes for you), then **map the records onto your `@rbs type` shape explicitly**. Gate sensitive columns with `@requires` on an output variant.

```ruby
# app/service/workflows/search_applicants.rb
module Workflows
  class SearchApplicants
    # @rbs import error

    include McpAuthorization::DSL

    # @rbs type applicant_summary = {
    #   id: String,
    #   name: String,
    #   stage: String
    # }

    # @rbs type pii_summary = {
    #   id: String,
    #   name: String,
    #   stage: String,
    #   email: String,
    #   phone: String
    # }

    # @rbs type success     = { success: true, total: Integer, applicants: Array[applicant_summary] }
    # @rbs type pii_success = { success: true, total: Integer, applicants: Array[pii_summary] }
    # Gate the whole VARIANT, not a field inside it — and list it first (see Result).
    # @rbs type output = pii_success @requires(:view_pii)
    #                  | success
    #                  | error

    def description
      "Search applicants by name fragment and/or current stage."
    end

    #: (
    #:   ?query: String?   @min(1) @max(100) @desc(Case-insensitive name fragment),
    #:   ?stage: String?   @desc(Exact stage to filter by),
    #:   ?limit: Integer   @min(1) @max(100) @default(20)
    #: ) -> Hash[Symbol, untyped]
    def call(query: nil, stage: nil, limit: 20)
      scope = Applicant.all
      # Relation methods parameterize the value — the LLM's text never touches raw SQL.
      scope = scope.where("name ILIKE ?", "%#{query}%") if query.present?  # ILIKE is PostgreSQL-only; use LIKE on MySQL/SQLite (case-sensitivity varies by collation)
      scope = scope.where(stage: stage) if stage.present?

      total   = scope.count
      records = scope.order(updated_at: :desc).limit(limit).to_a

      {
        success: true,
        total: total,
        applicants: records.map { |a| summarize(a) }
      }
    rescue ActiveRecord::StatementInvalid => e
      { success: false, error: { code: "query_failed", message: e.message,
                                 hint: "Check the stage value against list_workflow_stages." } }
    end

    private

    def summarize(applicant)
      # id is declared `String` in the type — to_s it, since projection
      # passes values through without coercing them.
      base = { id: applicant.id.to_s, name: applicant.name, stage: applicant.stage }
      return base unless can?(:view_pii)

      base.merge(email: applicant.email, phone: applicant.phone)
    end
  end
end
```

**Result.** The query is parameterized, so a `query:` of `"'; DROP TABLE applicants; --"` is matched as a literal name fragment, not executed. PII is protected in two layers. The source of truth is `summarize`: it only adds `email`/`phone` when `can?(:view_pii)`. The schema is the backstop — but only if you gate the right thing. `pii_success` is a **`@requires(:view_pii)` *variant*** (the tag sits on the union member, not on a field inside the named type — a field-level tag on a variant resolved by name is honored for nesting but the wrong tool for "show this whole shape to some users"). For a user without the flag, the variant is dropped from the output schema entirely and `filter_output` projects the return value onto the remaining `success` shape, stripping `email`/`phone` before serialization even if a handler bug let them through. The variant is listed **first** because `success` and `pii_success` share the same top-level keys: when both are visible (a `view_pii` user), the gem breaks the tie by source order, so the richer PII shape must come first or it gets projected away. Pagination is bounded by `@max(100)` so the LLM can't ask for a million rows.

**Variant: a second database or raw SQL.** Reading from an analytics replica or a non-AR datastore? Borrow a pooled connection and sanitize explicitly — never string-build with LLM input:

```ruby
def call(account_id:, since:)
  rows = ApplicationRecord.connection.exec_query(
    ApplicationRecord.sanitize_sql_array(
      ["SELECT stage, COUNT(*) AS n FROM events WHERE account_id = ? AND created_at >= ? GROUP BY stage",
       account_id, since]
    )
  )
  { success: true, by_stage: rows.map { |r| { stage: r["stage"], count: r["n"] } } }
end
```

The connection comes from ActiveRecord's pool and is returned automatically at the end of the request — you don't open or close it yourself.

---

## 17. Talk to a TCP socket from a tool

**Problem.** A tool should open a raw TCP connection to a service, send a probe, read the reply, and report latency — without hanging the request thread or becoming an SSRF hole.

**Solution.** Use `Socket.tcp` with a `connect_timeout:`, gate the read with `wait_readable`, and **allowlist the destination** before you connect. Always close in an `ensure`. Gate the whole tool behind a permission, because "open an arbitrary TCP connection from inside our network" is a capability, not a convenience.

```ruby
# app/service/ops/probe_service.rb
require "socket"

module Ops
  class ProbeService
    # @rbs import error

    include McpAuthorization::DSL

    # @rbs type success = {
    #   success: true,
    #   host: String,
    #   port: Integer,
    #   banner: String,
    #   latency_ms: Integer
    # }

    # @rbs type output = success | error

    # Only these hosts may be probed. The LLM picks the host; the allowlist
    # decides whether we honor it. Never skip this for an LLM-supplied address.
    ALLOWED_HOSTS = %w[redis.internal cache.internal queue.internal].freeze
    CONNECT_TIMEOUT = 3 # seconds
    READ_TIMEOUT    = 3 # seconds

    def description
      "Open a TCP connection to an allowlisted internal service and read its banner."
    end

    #: (
    #:   host: String    @desc(Service hostname; must be on the allowlist),
    #:   port: Integer   @min(1) @max(65535),
    #:   ?probe: String? @max(256) @default(PING)
    #: ) -> Hash[Symbol, untyped]
    def call(host:, port:, probe: "PING")
      return rejected(host) unless ALLOWED_HOSTS.include?(host)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      socket  = Socket.tcp(host, port, connect_timeout: CONNECT_TIMEOUT)
      begin
        socket.write("#{probe}\r\n")

        # Bound the blocking read. wait_readable returns nil on timeout.
        unless socket.wait_readable(READ_TIMEOUT)
          return connection_error(host, port, "read timed out after #{READ_TIMEOUT}s")
        end
        banner = socket.gets.to_s.strip

        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
        { success: true, host: host, port: port, banner: banner, latency_ms: elapsed }
      ensure
        socket.close
      end
    rescue Errno::ETIMEDOUT
      connection_error(host, port, "connect timed out after #{CONNECT_TIMEOUT}s")
    rescue SystemCallError => e # ECONNREFUSED, EHOSTUNREACH, ECONNRESET, ...
      connection_error(host, port, e.message)
    end

    private

    def rejected(host)
      { success: false, error: { code: "host_not_allowed", message: "#{host} is not probeable",
                                 hint: "Allowed hosts: #{ALLOWED_HOSTS.join(', ')}." } }
    end

    def connection_error(host, port, detail)
      { success: false, error: { code: "connection_failed",
                                 message: "Could not reach #{host}:#{port} — #{detail}",
                                 hint: "Verify the service is up and the port is correct." } }
    end
  end
end
```

```ruby
# app/mcp/ops/probe_service_tool.rb
module Ops
  class ProbeServiceTool < McpAuthorization::Tool
    tool_name "probe_service"
    authorization :ops_diagnostics   # capability gate — not everyone gets a raw socket
    open_world!                      # honest hint: this touches external services
    tags "operations"
    dynamic_contract Ops::ProbeService
  end
end
```

**Result.** Three timeouts that matter are all handled — connect (`connect_timeout:`), read (`wait_readable`), and the `ensure socket.close` that runs on every path including the early `return`. The allowlist check happens *before* `Socket.tcp`, so an LLM that asks to probe `169.254.169.254` (the cloud metadata endpoint) gets a structured `host_not_allowed` error instead of an SSRF. The connection is opened and closed entirely within the call, matching the stateless transport.

> **Why not `Timeout.timeout`?** It raises asynchronously from a separate thread and can fire while a socket is mid-syscall, leaving connections in a half-open state. Prefer `connect_timeout:` for the dial and `wait_readable(seconds)` for the read — they're cooperative and don't interrupt I/O at an arbitrary point.

---

## Where to go next

- **Reference** — every option, tag, and lifecycle detail: [README](README.md)
- **Working app** — all of the above, running: the handler-example app (not yet published as a standalone repo)
- **The one idea to keep** — authorization is *schema-shaping*, enforced both inbound (params filtered before `call`) and outbound (return value projected onto the caller's schema). You shape what each user sees; the gem makes the shape a boundary.
