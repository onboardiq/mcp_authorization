---
name: keep-tests-shareable
description: Audit test/ for patterns that break `rake test` when files load into one Ruby process — top-level redefinitions of `MCP::Tool`, `McpAuthorization::Tool`, `McpAuthorization::ToolRegistry`, `McpAuthorization::DSL`, or `StubContext`/`StubUser`. The gem's tests stub the MCP gem and the gem's own internals; if more than one file defines the same constant with a different shape (e.g. `class Tool` vs `class Tool < MCP::Tool`), Ruby raises `superclass mismatch` and the whole rake task aborts. Use whenever a test file is added, edited, or moved, before opening a PR, and whenever `bundle exec rake test` fails with a `TypeError` / `superclass mismatch` / `constant redefined` error. Also use when triaging issue #10 or any successor.
---

# Keep tests shareable

Single-purpose skill: make sure every `test/*_test.rb` file plays nicely with every other file when minitest loads them into one Ruby process via `bundle exec rake test`. The historical failure mode is a `superclass mismatch for class Tool` `TypeError` — see issue #10 for the original incident.

## The rule

**Test files must not define top-level stubs of constants the gem owns.** All stubs for `MCP::*`, `McpAuthorization::*`, `StubUser`, and `StubContext` live in `test/test_helper.rb`. New test files start with:

```ruby
require_relative "test_helper"
```

and nothing else of the form `module MCP` / `module McpAuthorization` / `class StubUser`. If you need something the helper doesn't expose, add it to the helper — don't re-stub in the file.

## Why this rule exists (read before changing it)

`Rake::TestTask` (`Rakefile` ~line 3) loads `FileList["test/**/*_test.rb"]` into a **single Ruby process**. Ruby's constant resolution treats `class Tool` and `class Tool < MCP::Tool` as a re-open of the same constant — and re-opening with a different superclass raises `TypeError: superclass mismatch for class Tool`. The first file to `require` `lib/mcp_authorization/tool.rb` (which declares `class Tool < MCP::Tool`) wins; any later file that opens `class Tool` with no superclass crashes the whole rake task.

The fix landed for issue #10 is to define every gem-owned constant **exactly once** in `test/test_helper.rb`, then `require_relative "../lib/mcp_authorization/tool"` from inside the helper. Every test file imports the helper and gets the same definitions. No per-file shadowing.

## Scope boundary — what this skill does NOT do

- **Does not rewrite production code under `lib/`.** If a test needs a stub the helper doesn't have, add the stub to the helper. Don't change the real `Tool` class to "make testing easier" — the test surface is what's wrong, not the gem.
- **Does not switch the test framework.** Stays on minitest + `Rake::TestTask`. Don't suggest RSpec or per-file processes as the fix — the fix is helper discipline.
- **Does not move tests to a `spec/` or `test_helper`-per-subdir layout.** Flat `test/` is the convention; preserve it.
- **Does not silently merge user code.** When consolidating stubs into the helper, show the diff and explain what moved, since the user reviews test-helper changes carefully (one slip and `rake test` is broken again).

## Step 1 — Run `rake test` first

Before changing anything, capture the current state:

```sh
bundle exec rake test 2>&1 | tail -20
```

- **Green?** The audit is a forward-looking lint. Continue to Step 2 and flag any drift you'd block at PR time, but don't churn passing code.
- **Red with `superclass mismatch` / `TypeError`?** The collision is live. Step 2 will localize it.
- **Red with normal test failures?** Out of scope. Hand back to the user — this skill is for isolation issues, not behavioral bugs.

## Step 2 — Find the collision

Run the audit grep — one screen of evidence, no interpretation needed:

```sh
grep -nE "^(module|class) (MCP|McpAuthorization|StubUser|StubContext)( |$|<)" test/*_test.rb
```

Expected output: **zero hits** outside `test/test_helper.rb`. Any line printed is a candidate offender.

Cross-check by listing what the helper already provides:

```sh
grep -nE "^(module|class) (MCP|McpAuthorization|StubUser|StubContext)" test/test_helper.rb
```

For each offender file, decide:

- **Identical to helper** → delete the duplicate, replace requires with `require_relative "test_helper"`.
- **Strict subset of helper** → delete; the helper already covers it.
- **Adds something new** (a new MCP method, a new stub flavor) → move the addition into `test_helper.rb`, then delete the file-local block.
- **Conflicts with helper** (e.g. helper says `class Tool < MCP::Tool`, file says bare `class Tool`) → this is the bug. The file-local version loses; delete it. If the test genuinely needs a different shape, raise it with the user — the answer is almost always to fix the test, not fork the stub.

## Step 3 — Consolidate

For each offender:

1. Open the file. Remove the top-level `module MCP` / `module McpAuthorization` / `class StubUser` / `class StubContext` blocks.
2. Replace the now-redundant `require_relative "../lib/mcp_authorization/configuration"` and `require_relative "../lib/mcp_authorization/rbs_schema_compiler"` requires with one `require_relative "test_helper"`.
3. Keep file-local `require`s for stdlib bits the helper doesn't need (`tmpdir`, `fileutils`, `json`, `tempfile`).
4. Leave fixture classes (test-only handler classes, anonymous `Class.new(McpAuthorization::Tool)` constructs inside test methods) alone — those are scoped to the test and don't collide.

## Step 4 — Verify both modes pass

```sh
bundle exec rake test 2>&1 | tail -5
```

Then the existing per-file convention (which `CLAUDE.md` documents):

```sh
for f in test/*_test.rb; do
  bundle exec ruby -Itest -Ilib "$f" || { echo "FAIL $f"; break; }
done
```

Both must be green. If only `rake test` passes but a file fails standalone, you've made the helper too aggressive — likely it's now loading something the standalone file already required, masking a missing require in the standalone file. Restore the file's own bare-minimum requires.

## Step 5 — Commit and PR

Branch name: `fix/test-helper-shared-stubs` (or similar). Commit message format:

```
Consolidate test stubs in test_helper.rb

Closes #<issue>.

<2-3 sentences: which constants moved, which file(s) were de-duplicated,
how this prevents the `superclass mismatch` regression.>
```

PR body should call out:

- The exact `TypeError` this prevents (paste the original error)
- Before/after of `bundle exec rake test`
- That per-file runs still pass (preserving the CLAUDE.md workflow)
- Issue link

## Known gotchas

- **`require_relative "../lib/mcp_authorization/tool"` MUST happen inside `test_helper.rb`, after `MCP::Tool` is stubbed.** If a test file loads `tool.rb` before `MCP::Tool` exists, you get `NameError: uninitialized constant MCP`. The helper orders this correctly; don't break the order.
- **Don't add `Minitest.autorun` to individual files.** `test_helper.rb` already does `require "minitest/autorun"`. Doubling it is harmless but noisy and confuses people skimming the file.
- **Anonymous subclasses of `McpAuthorization::Tool` are fine.** `Class.new(McpAuthorization::Tool) do ... end` inside a test method does not register a top-level constant — it's local to the test. The collision rule only applies to *named* top-level definitions.
- **`StubUser` / `StubContext` shapes have drifted before.** PR #6 (`materialize_for_test.rb`) shipped with a `StubUser` whose `initialize` only took `permissions` (no `defaults:` kwarg), diverging from the helper's two-arg version. If you find two `StubUser` definitions with different `initialize` signatures, the helper's signature wins — pick the more permissive one and have everything use it.
- **The `Rakefile` is not the problem.** It's a thin `Rake::TestTask` wrapper. Don't "fix" it by forking subprocesses per file; that hides the real issue and slows the suite. Fix the stubs.

## When this skill is overkill

If the user is adding a single test method to an existing file, you don't need the full audit — just check the file already imports `test_helper.rb` and doesn't redefine anything. The full audit is for: new test files, post-merge cleanup, triaging `rake test` failures, and CI green-check restoration.
