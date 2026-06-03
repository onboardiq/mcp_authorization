# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [0.5.3] - 2026-06-03

### Fixed
- **`#` comments inside an RBS record type no longer break schema compilation.** ([#20](https://github.com/onboardiq/mcp_authorization/issues/20))

  A comment line inside a record body — whether in an inline `# @rbs type` annotation or an imported `sig/shared/*.rbs` alias — raised `ArgumentError: invalid field name token`. The line-based readers (`find_raw_type_body`, `parse_type_aliases`, `parse_rbs_file`) concatenate record-body lines without a newline separator, so a comment folded into the next field name (`"# a note describing the fields belowid"`). Comments are valid anywhere in RBS — the official lexer discards `#`-to-end-of-line everywhere — so the readers now strip line comments before splitting fields, via a new `strip_rbs_comment` helper that leaves `#` inside string literals and bracketed annotation values (e.g. `@desc(...)`) untouched.

  **Impact:** because `tools/list` maps `to_mcp_definition` over every tool in a domain, a single tool with an in-record comment took down discovery for the entire domain — and the offending comment could live far away in a shared `.rbs` alias that several tools import.

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
