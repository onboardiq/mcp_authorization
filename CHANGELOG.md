# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [0.7.0] - 2026-07-21

Declarative tool grouping: a domain can present its tools as a small set of
summarized category facades instead of a flat list, with per-tool schemas
deferred out of the selection prompt. Opt-in and per-domain — domains not
configured via `facet_domain` behave exactly as before. (#30)

### Added
- **`category :name` tool DSL.** A tool declares the group it belongs to when its domain is faceted; ignored in flat domains. An optional `summary:` kwarg serves single-tool groups; the central registry wins on conflict.

- **`config.facet_domain :admin, group_by: :category`** — present a domain as grouped facades. `tools/list` returns one facade per group the caller has at least one permitted tool in (e.g. `orders_tools`), each with a routing-only description: the group summary plus RBAC-filtered one-liners of the tools the caller may actually invoke. Groups with zero permitted tools are hidden entirely, so a facade never advertises an empty `enum` (which fails JSON Schema draft-04 validation and can fail the whole `tools/list`).

- **`config.categories { summary :orders, "..." }`** — one summary line per group, used as the facade description's lead.

- **Selectable deferred-schema strategy** per domain via `schema_strategy:`. `:vendor_extension` (default) emits a `tool_name` enum and carries the per-tool schemas on the facade's `_meta` (key `"tool-input-schemas"`) — the MCP-sanctioned extension channel that SDKs preserve and that is never forwarded to the model as `input_schema`, so `inputSchema` itself stays free of non-standard keys and the listing is valid for strict Zod clients and strict-mode tool-calling while still shipping schemas in-band for capable clients. `:discriminated_union` emits a `oneOf` of `{tool_name: const, arguments: schema}` branches — native JSON Schema, but selectable rather than default because some strict tool-calling stacks reject a top-level `oneOf` (under `strict_schema` it is sanitized to `anyOf`). `:lazy` carries names only; argument shapes are enforced at dispatch. In every strategy the per-tool schemas are compiled per caller, so permission-gated fields never appear in a facade a caller receives.

- **Facade dispatch through the real call path.** A `tools/call` on a facade names the inner tool (`tool_name`) and its `arguments`. Dispatch checks the name against the set advertised to *this* caller, re-resolves the tool via `ToolRegistry.tool_class_for` — which re-runs `permitted?`, so gating is enforced even against a stale advertised set — and delegates to the tool's materialized `call`. Input filtering, output filtering, and `NotAuthorizedError` behave exactly as in a direct call, because it is the same code.

- **Argument coercion against the target tool's schema.** MCP clients frequently serialize nested objects as JSON strings; the facade's generic `arguments: object` contract cannot know which fields to parse. Both the `arguments` blob itself and any top-level value whose *target* schema type is an object or array are JSON-parsed before dispatch, then stripped by the target's `filter_input` as usual.

- **`uncategorized:` mode** — a tool without a `category` in a faceted domain lands in an `uncategorized` fallback group by default; `uncategorized: :error` raises instead for servers that want CI-enforced completeness. A facade name that collides with a real registered tool raises `FacadeNameCollisionError` rather than shadowing the tool.

- **`ToolRegistry.facades_for(domain:, server_context:)` / `facade_for(domain:, name:, server_context:)`** — the facade analogues of `tool_classes_for` / `tool_class_for`. `McpController` routes `tools/list` on a faceted domain to facades and resolves facade names on `tools/call` (direct tool names still resolve, so a client that learned a real tool name keeps working).

### Changed
- **The `tools/list` cache defs digest now folds in facet configuration.** Each tool's `category`, every `facet_domain` setting, and every group summary participate in the digest, so toggling grouping, switching schema strategy, or rewording a summary invalidates cached listings the same way a gate or handler-source change does.

## [0.6.2] - 2026-07-01

### Fixed
- **A record field whose type is an inline string-literal union with a single field-level tag was misclassified as a per-member-tagged union.** `compile_tagged_record` routes a field into `compile_tagged_union` (which gates each `|`-separated member individually, e.g. `stage: a @feature(x) | b @feature(y)`) whenever `tagged_union_field?` sees an `@` anywhere in the type string plus more than one `|`-separated part. A plain literal union with one *field-level* tag trailing the whole thing — `logic: "AND" | "OR" @desc(...)` — matches that same heuristic even though the tag applies to the field, not an individual member. Misrouting sends each bare literal (`"AND"`, `"OR"`) through `resolve_type`, which only resolves *named alias references*; each literal fell back to `{type: "object"}`, producing `{type: "object", oneOf: [{type: "object"}, {type: "object"}]}` instead of `{type: "string", enum: ["AND", "OR"]}`. `tagged_union_field?` and `tagged_array_union_inner` now require at least one *non-final* `|`-separated member to carry a tag before treating a field as per-member-gated — every genuine per-member-tagged union in this codebase tags each gated member individually, so a tag trailing only the last member is never sufficient on its own. Field-level tags on inline literal unions now fall through to the normal RBS-library path (`visit_rbs_union`), which already resolved them correctly.

## [0.6.1] - 2026-07-01

### Fixed
- **Single-line string-literal-union type aliases (e.g. `type logic = "AND" | "OR"`) lost every member after the first.** Both the `# @rbs type` inline-comment parser and the shared `sig/shared/*.rbs` file parser only scanned *subsequent lines* for `| "value"` continuations, so a union written entirely on one line — the common shape for short enums like `"AND" | "OR"` — resolved to `{type: "string", enum: ["AND"]}` instead of `["AND", "OR"]`. Multi-line unions (`"low"\n| "medium"\n| "high"`) were unaffected. Literal unions written directly inline on a record field (not behind a named alias) were also unaffected, since those go through the RBS-parser union visitor rather than the alias collector.

## [0.6.0] - 2026-06-25

Per-request work is now scoped to what each MCP method needs, and the
remaining `tools/list` cost is cacheable.

### Changed
- **`McpController#handle` now materializes only the tools the incoming request needs.** Every request — `initialize`, `notifications/initialized`, `ping`, the GET stream probe, and `tools/call` — previously ran `ToolRegistry.tool_classes_for`, compiling a per-user schema for *every* tool in the domain before the transport even looked at the method. Per-tool schema compilation is the dominant cost of an MCP request, so a `tools/call` (which invokes exactly one tool) and lifecycle traffic (which needs none) paid the full-domain price for nothing. `handle` now routes by JSON-RPC method: `tools/list` materializes the whole domain (unchanged), `tools/call` materializes only the invoked tool, lifecycle methods and the non-POST probe materialize none, and any unrecognized shape (e.g. a JSON-RPC batch with no top-level `method`) falls back to the full domain so routing stays correct. In a 140-tool domain this took a `tools/call` from ~2.6s to <100ms and `notifications/initialized` from ~2s to ~1ms, with no change to `tools/list` output.

### Added
- **`ToolRegistry.tool_class_for(domain:, name:, server_context:)`** — returns the concrete `MCP::Tool` subclass for a single named tool within a domain (or `nil` when the tool is unknown in that domain or the current user is not permitted), materializing just that one tool instead of the whole domain. Complements `tool_classes_for`, which remains the path for `tools/list`.

- **Opt-in caching for the `tools/list` response.** `tools/list` must materialize a per-user schema for every tool in a domain — the dominant cost of an MCP request now that `tools/call` compiles only the invoked tool (above). It can now be cached. Enable in the host initializer:

  ```ruby
  McpAuthorization.configure do |c|
    c.tools_list_cache = :redis          # or :memory, or any object responding to get/set
    c.tools_list_cache_ttl = 3600        # seconds (default)
  end
  ```

  Default is no caching (`NullStore`), so behavior is unchanged unless opted in.

- **Decision-vector cache key — correct under feature flags, shareable across identity.** The key is `H(domain + tool_defs_digest + vocab_fingerprint + decision_vector)`, never user/account identity. The decision vector is the result of every gating decision the domain's compilation consults — `@requires`/`@feature`/`@tier`/custom predicates, tool-level `gate`/`authorization`, and `current_user.can?` / `default_for`. Two contexts that answer all of them identically (same permissions, feature flags, tiers, defaults) share an entry; flip one feature flag and the vector — and the key — change, so an admin in a flag-on account never receives a flag-off account's tools. The `tool_defs_digest` (computed from each tool's gates + handler source) changes on deploy, auto-invalidating stale entries; the TTL bounds out-of-band staleness.

- **Two ways to supply the decision vector.** Automatic: the gem learns a domain's predicate vocabulary by wrapping the context in a `Cache::Recorder` on the first (cold) compile, then replays that vocabulary against the live context on subsequent requests. Explicit: if the server context responds to `mcp_cache_fingerprint`, its return value is used verbatim as the decision component (the host folds in whatever shapes the schema). Explicit wins when present.

- **Pluggable stores.** `Cache::NullStore` (default), `Cache::MemoryStore` (process-local, bounded LRU + per-entry TTL), and `Cache::RedisStore` (shared; JSON values; per-entry TTL). The Redis store's connection resolves from an explicit client (`tools_list_cache_redis`), then `tools_list_cache_redis_url`, then `ENV["REDIS_URL"]`, then a bare `Redis.new` — i.e. it defaults to the host's Rails redis config with no extra wiring. `redis` is an optional dependency, required lazily only when the Redis store is used. Cache outages fail open (a get/set error logs and behaves as a miss, never breaking `tools/list`).

- **`McpController` serves `tools/list` through the cache** when enabled: a hit renders the cached `result` re-wrapped with the live JSON-RPC id; a miss compiles cold under a `Recorder`, learns the vocabulary, and stores the result. Error/unexpected responses are rendered but not cached. All other methods are unaffected.

### Notes
- The cache is cleared on code reload (the Engine reloader now also calls `Cache.reset!`), so development picks up tool/schema changes immediately.

## [0.5.6] - 2026-06-08

### Fixed
- **Single-line and column-aligned `# @rbs type` record aliases are now collected.** A record alias written on one line — `# @rbs type ok = { a: String, b: Integer }` — was silently dropped: `collect_inline_aliases` truncated the body to a bare `{` and only a closing brace on a *following* line ever balanced it. Any union or field referencing such an alias resolved to the `{type: "object"}` fallback (no properties, no per-request gating), so the advertised schema and runtime projection both lost the type's shape. The opening-line body is now captured whole and stored immediately when its braces balance. Relatedly, the alias regex now tolerates arbitrary whitespace around `=`, so column-aligned blocks (`# @rbs type success     = { ... }`) parse instead of being skipped. Multi-line aliases are unaffected.

## [0.5.5] - 2026-06-04

### Fixed
- **`$defs` deduplication now ref-injects *inside* hoisted defs and prunes unreferenced ones.** `with_ref_injection` hoisted a multi-use type into `$defs` and `$ref`d it from the main schema, but left the def's *body* untouched — so a nested multi-use type (e.g. a shared base that inlines a template used elsewhere) stayed fully inlined inside the hoisted base **and** got hoisted again into a separate, never-referenced def. Each def body is now itself ref-injected (replacing nested multi-use types with `$ref`, excluding self), and any def left unreferenced (transitively from the root) is dropped. For a large discriminated union with a shared base, this removes both the duplicated nested types and the dead defs — a substantial `tools/list` size reduction with identical semantics.

### Added
- **Per-member predicate gating also reaches a union inside `Array[...]`.** A field typed `Array[a @feature(x) | b @feature(y)]` now gates the element union per request (the `|` is at bracket depth 1, so the plain field-union path didn't see it). `compile_tagged_record` detects `Array[<tagged union>]`, gates the inner union via `compile_tagged_union`, and re-wraps it as `{type: "array", items: …}`. Lets a list-of-discriminated-variants input (e.g. bulk create) expose only the variants available to the current account/user.
- **Per-member predicate gating now works for a union nested in a record field.** Previously, variant-level gating (`a | b @requires(:x)`) only applied to a top-level `# @rbs type output`/`input` union; a union inside a record field (`# @rbs type input = { stage: a @feature(x) | b @feature(y) }`) went through the RBS-library path and couldn't carry per-member tags. `compile_tagged_record` now detects a multi-member union field that carries a predicate tag and routes it through `compile_tagged_union`, so each variant is filtered per request (variants whose predicate is false are dropped). Untagged union fields are unchanged (still the full RBS path, so inline records etc. keep working). This lets, e.g., a discriminated-union input expose only the variants available to the current account/user.
- **Record intersection (`type x = base & { ... }`) compiles to `allOf`.** A shared `.rbs` type alias may now intersect a base type with an inline record — e.g. `type scheduler_stage = stage_common & { type: "SchedulerStage", ... }`. The base resolves first and, because it appears identically across every intersection that uses it, `with_ref_injection` hoists it into `$defs` once and `$ref`s it from each member. For a large discriminated union whose members share most of their fields, this collapses the duplicated common fields into a single `$def` (major token reduction in `tools/list`) while keeping full per-type typing. Field-level `&` in RBS type expressions also maps to `allOf`. Runtime projection (`filter_input`/`filter_output`) flattens `allOf` members — merging base + own `properties`/`required` and resolving `$ref`s — so discriminator-`const` matching and field projection work through the intersection.

### Fixed
- **Output projection honors `const` discriminators on union members.** When a `# @rbs type output` union's members are tagged by a property pinned to a literal (e.g. `type: "SchedulerStage"`), runtime projection (`filter_output`) now selects the member whose `const` matches the value's tag, rather than the member with the most incidental field overlap. A value whose tag matches no member falls through to the existing defensive pass-through (returned unchanged) instead of being mis-projected onto an unrelated variant and having its fields stripped. Non-discriminated unions (no `const` properties) are unaffected — they still pick the best-overlap variant. This makes large discriminated unions (one record per subtype, sharing a single tag field) project losslessly.
- **Shared types can now reference types defined in another imported file.** A `# @rbs import`ed `sig/shared/*.rbs` file may reference a type declared in a *different* imported file (as long as the handler imports both) — e.g. a per-type contract referencing a shared `move_rule` / `template` alias. Previously each shared file was parsed and resolved in isolation, so a cross-file reference degraded to a fallback (`{type: "object"}`/`{type: "string"}`). `build_cache` now collects the *raw* (unresolved) aliases from every imported file plus the handler's own inline `# @rbs type` definitions, merges them (local overrides imported), and resolves the whole set together, so cross-file references resolve. Within-file references and `$defs` deduplication are unchanged.

### Changed
- **Shared-type import resolution no longer requires Rails.** `resolve_import_path` now resolves absolute `shared_type_paths` directly and falls back to the current working directory when Rails is absent, instead of returning `nil` whenever `Rails` is undefined. Rails hosts using a relative path (e.g. `"sig/shared"`) are unaffected (still resolved against `Rails.root`); this makes shared imports usable — and testable — outside Rails.

## [0.5.4] - 2026-06-04

### Fixed
- **Predicate gating (`@requires`/`@feature`/`@hidden`/…) now recurses into nested record types.** ([#23](https://github.com/onboardiq/mcp_authorization/issues/23))

  Per-request gating was only applied to the top-level fields of a handler's own input record / `#:` params and to top-level output-union variants. A gated field *inside* a nested record alias (a `# @rbs type foo = { ... }` referenced as `Array[foo]`, as a nested property, or imported from `sig/shared/*.rbs`) was resolved from the statically-compiled `type_map` and never filtered against `server_context`, so it leaked into the schema for every user — silently defeating the field-shaping the DSL advertises. The compiler now threads a per-request resolution context (`server_context` + the retained, tag-intact raw record bodies) through the type visitor: when a named record alias is referenced, it is recompiled with `compile_tagged_record` so its own predicate-gated fields are filtered at any nesting depth, including across imports. A `visiting` stack guards against recursive types. Runtime enforcement (`filter_input`/`filter_output`) inherits the fix, since it projects against the same per-request schema. Predicate-free aliases still dedupe into `$defs` exactly as before.

- **`untyped` now compiles to the empty schema `{}` ("any value"), not `{type: "string"}`.** ([#22](https://github.com/onboardiq/mcp_authorization/issues/22))

  `untyped` (RBS `Bases::Any`/`Void`/`Nil`) emitted `{type: "string"}` despite the inline comment promising "no constraint". The most common casualty was `Hash[K, untyped]`, which compiled to `{type: "object", additionalProperties: {type: "string"}}` — forcing *every* property value to be a string. A payload carrying a nested object or array under such a param listed fine in `tools/list` but was rejected server-side at `tools/call` (`"… did not match the following type: string"`). `untyped` now maps to `{}`, so `Hash[K, untyped]` becomes `{type: "object", additionalProperties: {}}` (any value allowed) and bare `untyped` becomes `{}`. Relatedly, `project_against_schema` now honors `additionalProperties`: an explicitly-open object (e.g. an `untyped` hash) keeps its undeclared keys through runtime projection instead of being emptied before the handler runs, while objects with no `additionalProperties` (or `additionalProperties: false`, e.g. `@closed`) keep the closed-by-default projection that enforces `@requires` gating.

## [0.5.3] - 2026-06-03

### Fixed
- **`#` comments inside an RBS record type no longer break schema compilation.** ([#20](https://github.com/onboardiq/mcp_authorization/issues/20))

  A comment line inside a record body — whether in an inline `# @rbs type` annotation or an imported `sig/shared/*.rbs` alias — raised `ArgumentError: invalid field name token`. The line-based readers (`find_raw_type_body`, `parse_type_aliases`, `parse_rbs_file`) concatenate record-body lines without a newline separator, so a comment folded into the next field name (`"# a note describing the fields belowid"`). Comments are valid anywhere in RBS — the official lexer discards `#`-to-end-of-line everywhere — so the readers now strip line comments before splitting fields, via a new `strip_rbs_comment` helper that leaves `#` inside string literals and bracketed annotation values (e.g. `@desc(...)`) untouched.

  **Impact:** because `tools/list` maps `to_mcp_definition` over every tool in a domain, a single tool with an in-record comment took down discovery for the entire domain — and the offending comment could live far away in a shared `.rbs` alias that several tools import.

- **Narrowed `rbs` require set now loads under `rbs` 4.x.** The 0.5.2 narrowing (16-file subset instead of `require "rbs"`) was validated against `rbs` 3.x but raised `NameError: uninitialized constant RBS::AST::Ruby` on a fresh install resolving `rbs` 4.x — the same 4.x that 0.5.2's loosened `>= 3.0` constraint explicitly allows. `rbs` 4.x's C extension references the new `RBS::AST::Ruby::*` namespace and its `parser_aux` references `Pathname` at load time. The require block now loads `pathname` and the `rbs/ast/ruby/*` files when present (guarded by `rescue LoadError` so `rbs` 3.x, which lacks them, is unaffected). Verified against `rbs` 3.10 and 4.0.

### Added
- **CI workflow** (`.github/workflows/ci.yml`) running `bundle exec rake test` across Ruby 3.1–3.4 on push and pull request, plus a `sentinel check` job that fails if the committed `sig/generated/*.rbs` drift from the inline `#:` annotations. `rbs-sentinel` is now pinned as a development dependency so the signature formatting CI checks against is reproducible.

## [0.5.2] - 2026-05-28

### Changed
- **Narrowed the `rbs` require set.** `require "rbs"` pulled in ~144 files (CLI, environment loader, definition builder, prototype generators, stdlib type signatures, validator, resolver, ...) — none of which this gem touches. Replaced with a 16-file subset covering only `RBS::Parser.parse_type` and the `RBS::Types::*` AST classes the schema visitor actually visits. Measured against this gem's load path: ~1.2 MB RSS vs ~15 MB, 18 files loaded vs 144. No behavior change — same parser, same AST.
- **Loosened the `rbs` version constraint** from `>= 3.0, < 4.0` to `>= 3.0`. The upper bound locked consumers out of `rbs 4.x` even though `RBS::Parser.parse_type` is part of rbs's stable surface. Consumers who already depend on `rbs 4` for their own Steep / type-check toolchain can now use this gem without a downgrade. If a future rbs major actually breaks our parser-API usage, we'll add the upper bound back at that point — not preemptively.

## [0.5.1] - 2026-05-27

### Fixed
- **Tag values containing balanced parens, commas, or pipes no longer break the parser.** ([#15](https://github.com/onboardiq/mcp_authorization/issues/15))

  The historical regex parser used flat patterns (`[^)]*`, `[^,}]+`, bare `.split("|")`) to find delimiters. These patterns are not bracket-aware — a fundamental limitation of regular expressions (balanced delimiters are not a regular language). Symptom: silent miscompilation when any tag value contained the delimiter character.

  Five call sites were affected, all with the same root cause:
  - `extract_tags` — `@desc(foo (bar))` truncated at the inner `)`
  - `compile_tagged_record` — comma inside `@desc(...)` fragmented fields
  - `parse_record_type` — same, for nested/aliased records
  - `parse_call_params` — flat `.split(",")` mistook commas inside `@desc(...)` AND commas inside generic types (`Hash[Symbol, untyped]`) for parameter separators
  - union-splitting in `compile_tagged_union` and `rbs_type_to_json_schema` — pipe inside `@desc(...)` split the union mid-value

  All four now go through bracket-aware primitives that track `()`, `[]`, `{}` depth while scanning.

  **Concrete impact:** a field annotated `Integer @desc(The ID (NOT the question id)) @min(1)` previously compiled to `{type: "string", minLength: 1}` (wrong type AND wrong constraint keyword). Now compiles to `{type: "integer", description: "The ID (NOT the question id)", minimum: 1}`.

### Changed
- **Type-expression parsing now delegates to the official `rbs` gem.** `rbs_type_to_json_schema` previously dispatched via a regex case statement (`when "String"`, `when /\AArray\[(.+)\]\z/`, etc.). It now calls `RBS::Parser.parse_type` and walks the resulting AST through a small visitor (`visit_rbs_type`, `visit_rbs_class_instance`, `visit_rbs_union`, `visit_rbs_record`, `visit_rbs_literal`). This aligns the gem's runtime type interpretation with Steep's static interpretation — both now use the same parser, eliminating an entire class of silent divergence where the regex case statement misinterpreted types that Steep accepted.

  Side benefit: types that previously fell through to the `{type: "string"}` fallback because the regex case statement didn't recognize them (e.g. `Hash[K, V]` becomes `{type: "object", additionalProperties: …}` instead of `{type: "string"}`) now have correct JSON Schema mappings. No external behavior change for the type expressions exercised by tools shipped before 0.5.1.

### Added
- Internal helpers: `find_at_depth_zero`, `split_at_depth_zero`, `peel_trailing_tag`, `find_matching_open_paren`, `each_field_in_record`. Bracket-aware primitives used by `extract_tags` and the record/union splitters.
- **Runtime dependency on `rbs` (>= 3.0, < 4.0).** Previously transitive via Steep dev dependency; now explicit because the production code path uses it.

## [0.5.0] - 2026-05-26

### Changed (BREAKING)
- **Prefix optional marker (`?key:`) is now honored consistently across all three RBS parsers.**

  The three sibling parsers handled optional-field markers inconsistently:
  - `parse_call_params` — accepted only prefix `?key:`
  - `compile_tagged_record` — accepted only suffix `key?:`, silently treated prefix `?key:` as required
  - `parse_record_type` — recognized neither form, silently treated all fields as required

  The README documents prefix as canonical ("Prefix a param with `?` to mark it optional"), so handlers that followed the docs got unexpectedly-required fields in their compiled schemas.

  **Effect on consumers:** any field declared with prefix `?key:` in a `# @rbs type input = { ... }` record, a nested/aliased record (`# @rbs type foo = { ?bar: ... }`), or an inline record inside a `#:` signature is now correctly marked optional in the JSON Schema (omitted from `required`). For a consuming monolith with ~616 such fields, the schema's `required` array shrinks accordingly and clients (e.g. LLMs producing tool calls) will no longer treat these fields as mandatory.

  **If you relied on the buggy behavior** (prefix marker silently making the field required), declare the field with no marker (`key:`) to keep it required, or enforce presence inside `#call`.

### Deprecated
- **Suffix optional marker (`key?:`) is deprecated; will be removed in 0.6.0.** Suffix `key?:` continues to work in 0.5.0 (record types, call signatures, and nested aliased records) but now emits a single `Kernel#warn` per use with `category: :deprecated`. Silence with `Warning[:deprecated] = false` or `ruby -W:no-deprecated`. The warning embeds the handler's source-file path because the annotation is parsed as static text — the offending file is not on the Ruby call stack when the warning is emitted, so `uplevel:` cannot surface it.

### Added
- `RbsSchemaCompiler.parse_field_name(raw, source_file: nil)` — internal helper that turns a raw field-name token (everything before the `:`) into `[clean_name, optional?]`. Single source of truth for the three parsers. Raises `ArgumentError` on malformed input (empty, bare `"?"`, double-marked `"?key?"`, `"??key"`, `"key??"`). Tolerates whitespace around the marker (`" ? key"` → `["key", true]`).

### Fixed
- `parse_record_type` now recognizes optional markers at all. Previously, nested aliased record types like `# @rbs type foo = { ?bar: ... }` produced schemas where every field landed in `required` regardless of the marker. Caught only because the same bug existed in the sibling parsers under different shapes, hiding the test gap.

### Migration notes
- **No code changes required.** Suffix `key?:` annotations keep parsing; you'll see a deprecation warning per call site on first cache build of each handler. Migrate to prefix `?key:` at your own pace before 0.6.0.
- If you've been relying on prefix `?key:` being silently treated as required (the buggy behavior), audit your schemas: declared-optional fields that the handler still requires must be enforced inside `#call`, not by the schema.
- The README example in the records section was updated to use prefix `?count: Integer` to match the documented canonical form.

### Notes
- The `fountain/monolith` consumer (gem's primary downstream) has a separate migration PR tracking the suffix→prefix rewrite for ~616 affected fields, including `sig/shared/option_bank_result.rbs` and friends. That work is out of scope for this gem release and will land in the monolith repo once it bumps the `mcp_authorization` gem to 0.5.0+.

## [0.4.0] - 2026-05-21

### Added
- **Tool-level generic predicate gates.** `Tool` subclasses can now declare any number of `gate :predicate_name, :value` calls in addition to `authorization :perm`. The gate is evaluated at request time by calling `server_context.{predicate_name}?(value)`; if any gate returns false, the tool is hidden from `tools/list` and rejected from `tools/call`. This is the tool-level counterpart of the field-level `@predicate(:value)` system introduced in 0.3.0 — same semantics, same fail-open + error-isolation behavior, same backward-compat fallback for `gate :requires`.

  ```ruby
  class BulkSendSmsTool < McpAuthorization::Tool
    authorization :communications  # RBAC permission (existing behavior preserved)
    gate :feature, :sms            # hide tool unless current_account.sms_enabled?
    gate :requires, :super_user    # extra check beyond authorization
  end
  ```

- `McpAuthorization::Diagnostics` module — shared helper for the development-mode "Did you mean?" warning previously duplicated between field-level (`@predicate`) and tool-level (`gate`) sites. Single Levenshtein implementation, single warning phrasing per call site (`gate :feture, :sms` warns "Did you mean gate :feature?", `@feture(:sms)` warns "Did you mean @feature?").

### Changed
- **`authorization` migrated to the generic gate pipeline.** `authorization :perm` is now a convenience alias for `gate :requires, :perm`. The legacy dual-path in `Tool.permitted?` (one branch for `_permission`, another for gates) is gone; there is one pipeline now. Mirrors the field-level migration done in 0.3.0 (#12), where `@requires` was migrated through the same generic predicate pipeline rather than carrying its own special-cased branch. `_permission` remains exposed as before for introspection.
- `permitted?(nil_context)` now denies when gates are declared (previously crashed). A nil context reaching `permitted?` is a programmer error; fail-closed avoids silently exposing the tool.

### Migration notes
- No breaking changes for end users. Tools that use `authorization :perm` continue to work exactly as before — the only difference is the internal pipeline.
- If you read `tool_class._permission` for introspection, it still returns the declared symbol.
- Existing field-level `@requires`/`@feature` semantics are unchanged.

## [0.3.0] - 2026-05-14

### Added
- **Generic predicate tags.** Any `@tag(:value)` annotation not in the known constraint list becomes a predicate filter: the compiler calls `server_context.tag_name?(value)` at schema compile time. If the predicate returns false, the field/variant is excluded from the JSON Schema. This makes the gem infinitely extensible — define `feature?`, `tier?`, `beta?`, or any predicate on your server context without gem changes.
- Backward-compat fallback for `@requires`: if the server context lacks a `requires?` method, the compiler falls back to `server_context.current_user.can?(:flag)` directly. No deploy-ordering constraint.
- Error isolation: exceptions from individual predicates are rescued and logged. A single broken predicate no longer crashes the entire `tools/list` response.
- Development-mode warning with DidYouMean suggestion when a predicate method is not found on the server context (e.g., `@feture(:x)` warns "Did you mean @feature?").

### Changed
- `@requires` is now handled through the generic predicate path. The `tags[:requires]` key is removed; `@requires(:flag)` is stored only in `tags[:predicates]` like any other predicate.
- `predicate_excluded?` replaces the three hardcoded `current_user.can?` filter lines in `compile_tagged_record`, `compile_tagged_union`, and `filter_call_signature`.
- Configuration docs updated to describe the predicate protocol on server context objects.

### Migration notes
- Consumers using `OpenStruct` as server context continue to work — `@requires` falls back to `current_user.can?`. To use `@feature` or custom predicates, define the corresponding `?` methods on your server context.
- If you read `tags[:requires]` from parsed tag hashes (unlikely outside the gem), switch to `tags[:predicates].find { |p| p[:name] == "requires" }`.

## [0.2.1] - 2026-05-13

### Fixed
- `tools/call` responses now include `structuredContent` when the tool declares an `outputSchema` via `dynamic_contract`. Previously the response carried only text content, which spec-compliant clients rejected as a validation error. (#6)
- `RbsSchemaCompiler` now finds the handler's source file when `#call` is wrapped via `Module#prepend` (param coercion, instrumentation, `ActiveSupport::Concern`, tracing libraries). It walks `UnboundMethod#super_method` past prepended modules until the owner is the handler class itself, so `# @rbs type` and `#:` annotations are read from the right file instead of raising a contract violation. (#8)

## [0.2.0] - 2026-04-20

### Added
- `RbsSchemaCompiler.filter_input(handler, params, server_context:)` — projects inbound params onto the user's compiled input schema before the handler runs. Keys gated by `@requires` the user lacks, and any keys not declared in the schema at all, are dropped.
- `RbsSchemaCompiler.filter_output(handler, result, server_context:)` — projects the handler's return value onto the user's compiled output schema. Hidden `oneOf` variants and their fields are stripped before serialization.

### Changed
- **`@requires` is now a security boundary, not just a hint to the LLM.** Tool calls through `Tool.call` and the anonymous class produced by `Tool.materialize_for` pipe params through `filter_input` on the way in and results through `filter_output` on the way out. A crafted JSON-RPC request that sends a gated param, and a handler that accidentally emits a gated output field, can no longer leak.
- README updated to describe enforcement as a guarantee. Handler authors no longer have to remember to re-check `can?` in every branch that touches a gated field — the schema is the boundary.

### Migration notes
- If your handler's `#call` quietly accepted params that weren't declared in the `#:` annotation, those will now arrive as `nil`/default values. Declare them (with `@requires` if appropriate) or drop them.
- If your handler's output included fields that weren't in `@rbs type output`, those are now stripped. Add them to the output type definition if they should ship.

## [0.1.1] - 2026-04-02

### Added
- Added MIT license, homepage, author metadata.

## [0.1.0] - 2026-04-01

### Added
- Initial gem extraction from the monorepo. Rails engine, `RbsSchemaCompiler`, `Tool` / `ToolRegistry`, `DSL` mixin, `McpController`.
