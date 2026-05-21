# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [0.4.0] - 2026-05-21

### Added
- **Tool-level generic predicate gates.** `Tool` subclasses can now declare any number of `gate :predicate_name, :value` calls in addition to `authorization :perm`. The gate is evaluated at request time by calling `server_context.{predicate_name}?(value)`; if any gate returns false, the tool is hidden from `tools/list` and rejected from `tools/call`. This is the tool-level counterpart of the field-level `@predicate(:value)` system introduced in 0.3.0 — same semantics, same fail-open + error-isolation behavior, same backward-compat fallback for `gate :requires`.

  ```ruby
  class BulkSendSmsTool < McpAuthorization::Tool
    authorization :communications  # RBAC (legacy, still supported)
    gate :feature, :sms            # hide tool unless current_account.sms_enabled?
    gate :requires, :super_user    # extra check beyond authorization
  end
  ```

- Levenshtein-based "Did you mean?" warning in development when a gate predicate is not found on the server context (e.g., `gate :feture, :sms` warns "Did you mean gate :feature?"). Mirrors the field-level diagnostic added in 0.3.0.

### Changed
- `Tool.permitted?` now combines two checks: the legacy `authorization` RBAC permission AND every declared `gate`. All checks must pass for the tool to be visible. Existing tools that use only `authorization` are unaffected — `gate` is opt-in.

### Migration notes
- No breaking changes. Tools that don't declare `gate` behave exactly as in 0.3.0.
- `Tool.permitted?` is now never called with `_permission.nil?` short-circuiting to `true` *unconditionally* — instead, gates are also evaluated. A tool with no `authorization` and no `gate` calls remains permissive (returns true).
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
