# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

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

## [0.1.1] - earlier
- Added MIT license, homepage, author metadata.

## [0.1.0] - initial release
- Initial gem extraction from the monorepo. Rails engine, `RbsSchemaCompiler`, `Tool` / `ToolRegistry`, `DSL` mixin, `McpController`.
