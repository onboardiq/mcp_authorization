# Design: Declarative tool grouping with summarized facades + deferred schema loading

Tracking issue: [#30](https://github.com/onboardiq/mcp_authorization/issues/30)
Status: **Proposed** — design for review. No code yet.
Target: a minor release (additive, opt-in; no behavior change for existing servers).

## 1. Problem

A domain that grows into the hundreds of tools returns a large, flat `tools/list`.
Two costs compound:

1. **Selection-context bloat.** Every tool's full `inputSchema` is materialized into
   the listing up front, even though the model will pick exactly one. The per-tool
   schemas dominate the payload; the selection prompt is spent on call-time detail
   rather than routing signal.
2. **Poor selection surface.** A flat list of 100+ tools is hard to choose from.
   Grouping by capability lets a caller narrow to an area before committing to a tool.

Today `ToolRegistry.list_tools` / `tool_classes_for` emit one entry per permitted tool
in a domain — there is no way to present the same tools as a smaller, grouped surface.

## 2. Proposal in one paragraph

Add an opt-in, per-domain **facade** layer. A tool declares the group it belongs to
(`category :orders`). A domain opts into grouping (`config.facet_domain :admin,
group_by: :category`). `tools/list` for that domain then returns **one facade tool per
non-empty group** — `orders_tools`, `billing_tools` — each carrying a routing-only
description (group summary + RBAC-filtered tool one-liners) and a facade `inputSchema`
whose per-tool argument schemas are **deferred** out of the selection prompt. A
`tools/call` on a facade names the inner tool and its arguments; the gem coerces those
arguments against the *target* tool's schema and dispatches through the real tool's
normal call path, so per-tool authorization, gating, and schema filtering apply exactly
as if the tool had been called directly.

## 3. Public API

```ruby
# 1. A tool declares its group.
class ListOrdersTool < McpAuthorization::Tool
  tags "admin"
  authorization :view_orders
  category :orders                 # NEW
  dynamic_contract OrderHandlers::List
end

# 2. A domain opts into grouping, and groups get summaries.
McpAuthorization.configure do |config|
  config.facet_domain :admin,
    group_by: :category,
    schema_strategy: :vendor_extension    # :vendor_extension (default) | :discriminated_union | :lazy
    # uncategorized: :fallback             # :fallback (default) | :error
    # facade_suffix: "tools"               # facade name = "#{category}_#{suffix}" (default "tools")

  config.categories do
    summary :orders,  "Create, inspect, and update orders and their line items."
    summary :billing, "Invoices, payments, refunds, and billing profiles."
  end
end
```

A domain **not** named in a `facet_domain` call behaves exactly as today. This is the
core compatibility guarantee: grouping is strictly additive and per-domain.

## 4. How it lands on the existing architecture

The feature belongs in the gem because every hard part is generic mechanism that reuses
seams that already exist. The server-specific inputs are only *which domains to group*,
*a tool's group*, and *a group's summary*.

| Concern | Existing seam | Change |
|---|---|---|
| Per-caller RBAC filtering | `Tool.permitted?` (`tool.rb:153`), `ToolRegistry.tool_classes_for` (`tool_registry.rb:68`) | Reused unchanged to decide which inner tools a facade advertises. |
| Grouping by tag | `ToolRegistry.tools_by_domain` (`tool_registry.rb:48`) | New sibling that partitions the *permitted* subset by `_category`. |
| Per-caller schema shaping | `RbsSchemaCompiler.compile_input` via `Tool.dynamic_input_schema` (`tool.rb:127`) | Reused to build each inner tool's argument schema for the facade. |
| Dispatch through the real call path | `ToolRegistry.tool_class_for` + `Tool.materialize_for` (`tool.rb:200`) | Facade `call` resolves the inner tool by name and delegates here. |
| Argument filtering / gating on call | `RbsSchemaCompiler.filter_input` / `filter_output` inside the materialized `call` (`tool.rb:215`) | Reused unchanged — dispatch reaches it. |
| Request routing | `McpController#tools_for_request` (`mcp_controller.rb:91`) | Facade names must resolve for `tools/call` (see §7). |
| tools/list cache | `Cache.tools_list_key` (`cache.rb`) | Facade composition must be inside the cached region and folded into the defs digest (see §8). |

### Facade lifecycle

A facade is **not** a `McpAuthorization::Tool` subclass (those self-register and expect a
`dynamic_contract`). It is a per-request synthetic `MCP::Tool` subclass, built the same
way `Tool.materialize_for` builds a concrete tool: `tool_name`, `description`,
`input_schema`, and a `call` singleton baked in for this caller. It never enters
`ToolRegistry`'s registered set; it is produced on demand by a new
`ToolRegistry.facades_for(domain:, server_context:)`.

## 5. Facade shape

For a caller permitted `list_orders` and `update_order` but not `delete_order`, the
`orders_tools` facade:

**description** (routing only — no argument schemas):
```
Create, inspect, and update orders and their line items.

Available tools (pass one as `tool_name`):
- list_orders — List orders, optionally filtered by status.
- update_order — Update fields on an existing order.
```
The per-tool one-liners come from each inner tool's existing handler `#description`
(`Tool.dynamic_description`, `tool.rb:121`). `delete_order` is absent because
`permitted?` returned false for this caller — the RBAC-filtering invariant.

**inputSchema** — depends on `schema_strategy` (§6).

## 6. Deferred-schema strategies

All three keep per-tool schemas out of the *description* and RBAC-filter what they
advertise. They differ in where the argument schemas live in `inputSchema`.

### 6a. `:vendor_extension` — **recommended default**

```jsonc
{
  "type": "object",
  "properties": {
    "tool_name": { "type": "string", "enum": ["list_orders", "update_order"] },
    "arguments": { "type": "object" }
  },
  "required": ["tool_name", "arguments"],
  "x-tool-input-schemas": {
    "list_orders":  { /* compiled input schema, RBAC-filtered for this caller */ },
    "update_order": { /* ... */ }
  }
}
```

Why default: inert to every JSON Schema validator, so it never breaks a strict
tool-calling stack. A client that understands `x-tool-input-schemas` gets full per-tool
argument shapes; one that doesn't still sees a valid `tool_name` enum + generic
`arguments` object and can round-trip. Graceful degradation with no interop cliff.

### 6b. `:discriminated_union` — most standards-friendly, has an interop trap

```jsonc
{
  "oneOf": [
    { "type": "object",
      "properties": { "tool_name": { "const": "list_orders" },
                      "arguments": { /* compiled schema */ } },
      "required": ["tool_name", "arguments"] },
    { "type": "object",
      "properties": { "tool_name": { "const": "update_order" },
                      "arguments": { /* compiled schema */ } },
      "required": ["tool_name", "arguments"] }
  ]
}
```

Native JSON Schema; per-tool argument validation for free. **But** a top-level `oneOf`
in a *tool input schema* is rejected or silently degraded by some tool-calling stacks
(notably strict modes) — which is exactly why strategy is selectable rather than
hardcoded. Offer it; do not default to it.

### 6c. `:lazy` — smallest listing, one extra round-trip

`inputSchema` carries the `tool_name` enum and generic `arguments` only; no per-tool
schemas anywhere. The caller fetches a chosen tool's schema on demand. Two sub-questions
this strategy raises, deferred to a follow-up because they need an MCP-surface decision:

- **How the schema is fetched.** Either a reserved discovery tool per facade
  (`orders_tools.describe`, args `{ tool_name }`) that returns the compiled schema, or a
  distinct JSON-RPC probe. The reserved-tool form needs no protocol extension and is
  preferred, but it doubles as a naming decision.
- **Whether the enum alone is enough routing signal.** Likely yes when paired with the
  description one-liners.

Recommendation: ship `:vendor_extension` and `:discriminated_union` first; land `:lazy`
in a follow-up once the fetch mechanism is chosen.

## 7. Dispatch and coercion

A `tools/call` targeting a facade carries `{ name: "orders_tools", arguments: {
tool_name: "update_order", arguments: {...} } }`. The facade's baked `call` singleton:

1. Reads `tool_name` from params; rejects if absent or not in this caller's advertised
   set (the same RBAC-filtered set used to build the facade — never trust the wire).
2. Resolves the inner tool: `ToolRegistry.tool_class_for(domain:, name: tool_name,
   server_context:)`. This **re-runs `permitted?`** (`tool_registry.rb:88`), so gating is
   enforced on dispatch even if the advertised set were somehow stale. Returns an
   authorization error if nil.
3. **Coerces `arguments` against the target tool's schema, not the facade's.** MCP
   clients frequently send nested object arguments as a JSON *string*. The facade's own
   contract only knows `arguments: object`; the coercion must parse the string and
   validate/shape it against the *inner* tool's compiled input schema before dispatch.
   This is a new helper (`coerce_arguments(target_handler, raw, server_context:)`) that
   JSON-parses when `raw` is a String, then routes through the existing
   `RbsSchemaCompiler.filter_input` so unknown/permission-gated fields are stripped
   exactly as in a direct call.
4. Delegates to the resolved tool's materialized `call`, returning its `MCP::Tool::Response`
   verbatim. Output filtering (`filter_output`, `tool.rb:221`) happens inside that call —
   the facade adds nothing on the way out.

The critical invariant: **dispatch is the real call path.** The facade resolves a tool
and calls it; it does not re-implement gating, filtering, or response shaping. Anything
the direct path enforces, the faceted path enforces, because it is the same code.

### Controller routing

`McpController#tools_for_request` (`mcp_controller.rb:91`) currently routes `tools/call`
by looking up a registered tool name via `tool_class_for`. Facade names are not registered
tools, so this must gain a branch: when the domain is faceted and `name` matches a facade,
materialize the facade (via `facades_for`, filtered to that one name) instead. `tools/list`
on a faceted domain routes to `facades_for` instead of `all_tools`.

## 8. Interaction with the tools/list cache

The tools/list cache (`cache.rb`) keys on `domain + defs_digest + decision_vector` and
caches the JSON-RPC `result`. Facades must compose **inside** the cached region so the
cached `result` is already the grouped listing. Two required adjustments:

- The **defs digest** must fold in each domain's `facet_domain` config and every group
  summary, so toggling grouping or editing a summary invalidates stale entries the same
  way a gate/source change does today.
- Facade composition consults the same predicates per inner tool that a flat compile
  does (`permitted?` → gates), so the **Recorder** already captures the right decision
  vocabulary — no new fingerprint inputs. This should be asserted with a test, not
  assumed.

## 9. Resolved open questions

The issue left four open. Recommended resolutions:

1. **Uncategorized tools in a grouped domain** → **`uncategorized` fallback group by
   default**, with `uncategorized: :error` opt-in for strict servers. Rationale: a hard
   error raised *during* `tools/list` breaks the entire listing for one mis-tagged tool —
   a runtime cliff. A fallback group is safe and keeps the tool reachable. Emit a
   development-mode warning via the existing `Diagnostics` helper
   (`diagnostics.rb`) so the mistake is visible without being fatal. Servers that want
   CI-enforced completeness set `:error`.

2. **Group summary location** → **central registry (`config.categories`) is
   authoritative** for the *group* summary; per-tool one-liners come from each tool's
   existing handler `#description`. A summary describes the group, not any one tool, so
   co-locating it on an arbitrary member is awkward and creates a "which tool owns the
   summary" problem. Allow a convenience override `category :orders, summary: "..."` on a
   tool declaration for single-tool groups, but the central form wins on conflict.

3. **Empty groups** → **hide the facade entirely.** A facade advertising zero permitted
   tools is meaningless *and* is exactly the case that produces an empty `enum`, which
   fails JSON Schema draft-04 validation and can fail the whole `tools/list`. The grouping
   step filters to non-empty groups before emitting any facade, which satisfies the "no
   invalid schema" behavioral requirement structurally rather than by special-casing.

4. **Default schema strategy** → **`:vendor_extension`.** It never breaks a validator and
   degrades gracefully; `:discriminated_union` is more elegant but carries the top-level
   `oneOf` interop trap. Default to safe, make elegant opt-in.

## 10. Behavioral requirements → where each is met

| Requirement (from #30) | Mechanism |
|---|---|
| Grouping + advertised enum/schema map RBAC-filtered per caller | Facade built from the `permitted?`-filtered subset (§4, §5). |
| A zero-permitted-tool group must not emit an invalid schema | Empty groups hidden entirely (§9.3). |
| Dispatch goes through the real call path; auth/gating/output-filtering never bypassed | Facade resolves via `tool_class_for` (re-checks `permitted?`) and delegates to materialized `call` (§7). |
| Nested JSON-string args coerced against the *target* tool's schema | `coerce_arguments` parses + routes through the inner tool's `filter_input` (§7.3). |

## 11. Proposed rollout

1. **Slice 1 (this design):** `category` DSL, `facet_domain` / `categories` config,
   `ToolRegistry.facades_for`, `:vendor_extension` strategy, dispatch + coercion,
   controller routing, empty-group hiding, uncategorized fallback. Tests for each
   behavioral requirement + the cache-vocabulary assertion (§8).
2. **Slice 2:** `:discriminated_union` strategy behind the existing `schema_strategy`
   selector (schema shape only — dispatch is unchanged).
3. **Slice 3:** `:lazy` strategy once the schema-fetch mechanism is chosen (§6c).

## 12. Risks

- **`strict_schema` mode** (`configuration.rb:80`) strips keywords and adds
  `additionalProperties: false`. Facade schemas must pass through it too, and
  `:discriminated_union`'s `oneOf` interacts badly with strict mode — reinforces the
  `:vendor_extension` default.
- **Naming collisions.** A facade named `orders_tools` must not collide with a real
  registered tool of that name. Validate at config/first-request time and error loudly.
- **`find_tool` / cross-domain lookups** (`tool_registry.rb:95`) are unaffected — facades
  are never registered — but this should be covered by a test so a future refactor
  doesn't accidentally register them.
