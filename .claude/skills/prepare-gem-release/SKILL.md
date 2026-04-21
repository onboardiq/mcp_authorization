---
name: prepare-gem-release
description: Prepare a Ruby gem release PR — bump version, draft CHANGELOG from merged PRs since the last tag, run tests, smoke-build the gem, open a release branch PR. Stops at the PR. Does NOT tag, push to main, or publish to rubygems — those happen after the PR is merged via a separate release step. Use when the user says "prepare a release", "cut a release", "release X.Y.Z", "update the gem", or any variant that implies shipping a new version of a Ruby gem.
---

# Prepare Gem Release

Single-purpose skill: take a gem from "latest main is ready to ship" to "release PR open, waiting for merge". Everything that happens AFTER the merge (tag, push tag, `gem push`) is a separate concern — see the Release handoff section at the bottom.

## Scope boundary — what this skill does NOT do

- **Does not push to `main`.** Direct pushes are blocked by hook on at least some of the user's repos, and even where they aren't, a release should go through review.
- **Does not create a git tag.** Tagging happens on the merge commit, which doesn't exist yet.
- **Does not run `gem push`.** Publishing to rubygems is hard to reverse and needs the user's credentials. Leave the built `.gem` artifact in the working tree and hand it off.
- **Does not modify consumer repos** (e.g. example apps pinning `~> old.version`). Mention them in the PR body as a follow-up, don't touch them.

## Preconditions

Before doing anything, verify:

1. **In a gem repo.** Look for `*.gemspec` at the repo root and `lib/<name>/version.rb`. If either is missing, stop — this isn't a gem repo.
2. **Working tree clean.** `git status --porcelain` must be empty. If not, stop and ask the user what to do with their changes.
3. **On default branch, up to date.** `git rev-parse --abbrev-ref HEAD` == default (usually `main`), and `git fetch && git status` shows no drift.
4. **Tests runnable.** `Rakefile` has a `test` task or the gemspec tells us otherwise. Don't invent test commands.

If any precondition fails, report and stop. Don't "fix it up" silently.

## Step 1 — Decide the version

Read `lib/<name>/version.rb` for the current version. Look at commits since the last tag (`git log $(git describe --tags --abbrev=0)..HEAD --oneline`) to suggest a bump:

- **Major bump** (X.0.0): deletions from public API, breaking signature changes, or semver-major language in commit messages.
- **Minor bump** (0.X.0): new public API, new runtime behavior that could surface pre-existing bugs (e.g. stricter validation), feature additions.
- **Patch bump** (0.0.X): bug fixes, docs, internal refactors, no public-API delta.

On pre-1.0 gems, treat "minor" as the equivalent of major — a change that might require consumers to adapt should bump the minor, not the patch.

Propose a version and a one-line justification. **Ask the user to confirm** before proceeding. Don't guess and commit.

## Step 2 — Create the release branch

```sh
git checkout -b release-<version>
```

Everything that follows goes on this branch. Never commit to main.

## Step 3 — Bump `version.rb`

Edit `lib/<name>/version.rb` — change the `VERSION` constant to the new version. Nothing else in that file should move.

## Step 4 — Draft the CHANGELOG

```sh
LAST_TAG=$(git describe --tags --abbrev=0)
LAST_TAG_DATE=$(git log -1 --format=%aI "$LAST_TAG")
gh pr list --state merged --base main --search "merged:>$LAST_TAG_DATE" \
  --json number,title,body,mergedAt --limit 100
```

Group entries under Keep-a-Changelog headings: **Added**, **Changed**, **Fixed**, **Deprecated**, **Removed**, **Security**. Skip headings with no entries.

For each entry: one line, active voice, names the user-visible API surface (not the internal refactor). Example:

> - `RbsSchemaCompiler.filter_input(handler, params, server_context:)` — projects inbound params onto the user's compiled input schema before the handler runs.

If any entry represents a migration-required change (stricter validation, renamed API, dropped flag), add a **Migration notes** subsection with concrete before/after guidance.

**Show the draft to the user and let them edit it before committing.** CHANGELOG text ships with the gem — the author should own the voice.

### Template for a new CHANGELOG.md

```markdown
# Changelog

All notable changes to this gem are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

## [X.Y.Z] - YYYY-MM-DD

### Added
- ...

### Changed
- ...

### Migration notes
- ...
```

## Step 5 — Ship the CHANGELOG with the gem

Open `<name>.gemspec`. Find the `spec.files = Dir[...]` (or array literal) block. If `"CHANGELOG.md"` isn't listed alongside `"README.md"` / `"LICENSE"`, add it. Without this line the CHANGELOG won't be in the published gem — consumers lose the migration notes when they need them most.

Run both checks:

gem build <name>.gemspec
```

Both must succeed. The `gem build` is a smoke test for the gemspec (catches things like missing files, bad metadata) — the `.gem` artifact it produces is what the user will eventually push to rubygems, so **don't delete it**. Leave it in the repo root (most gem repos gitignore `*.gem` already; verify).

If tests fail, stop. Don't patch around test failures inside a release PR — they belong on a fix PR that precedes the release.

## Step 7 — Commit

One commit on the release branch, message format:

```
Release X.Y.Z

<2-3 sentences summarizing the headline change. Enough that someone
browsing git log gets the gist without opening CHANGELOG.md.>

See CHANGELOG.md for the full list and migration notes.
```

Stage only: `lib/<name>/version.rb`, `CHANGELOG.md`, `<name>.gemspec`. Do NOT stage the `.gem` artifact — that's a build output.

## Step 8 — Push and open the PR

```sh
git push -u origin release-<version>
```

Then `gh pr create` with this body structure:

```markdown
## Summary
- Bumps to X.Y.Z
- <one bullet per headline change, cross-referencing PRs that landed the code>

## Changelog
See `CHANGELOG.md`. Highlights:
- ...

## Follow-ups after merge
- Tag `vX.Y.Z` on the merge commit and push the tag
- `gem push mcp_authorization-X.Y.Z.gem` to rubygems.org
- <any consumer repos with version pins that need bumping>

## Test plan
- [x] `bundle exec rake test` — N runs, 0 failures
- [x] `gem build` produces `<name>-X.Y.Z.gem`
```

The "Follow-ups after merge" section is load-bearing. It tells the reviewer (and future-you) that this PR is step 1 of 2, and what step 2 is. Don't skip it.

## Step 9 — Hand off

Report to the user:
- PR URL
- Path to the built `.gem` artifact (for when they run `gem push` themselves)
- The merge-and-release sequence for the follow-up skill (see below)

Stop. You're done.

## Release handoff — what happens after merge

This skill intentionally stops at the PR. The post-merge sequence is:

1. User (or reviewer) merges the release PR on GitHub
2. Pull latest `main`: `git checkout main && git pull`
3. Tag the merge commit: `git tag -a vX.Y.Z -m "Release X.Y.Z"`
4. Push the tag: `git push origin vX.Y.Z`
5. User runs `gem push <name>-X.Y.Z.gem` (requires their rubygems credentials)
6. User bumps version pins in any consumer repos that depend on this gem

Steps 2–4 can be automated by a follow-on skill (not this one). Steps 5–6 should stay manual — publishing to a public registry and touching other repos are the kind of Create-Public-Surface actions that shouldn't be one-prompt-away.

## Known gotchas

- **The `CHANGELOG.md` in `spec.files` is the most-forgotten step.** The CHANGELOG is in the repo, but the gem shipped without it, so `bundle show <gem>` doesn't surface migration notes. Always check the gemspec.
- **Pre-1.0 semver is easy to undershoot.** On `0.x`, a change that breaks consumers should be a minor bump, not a patch. If in doubt, bump harder.
- **`gh pr list --search "merged:>..."` sometimes misses PRs** if the default branch was force-pushed or a PR was merged from a non-default base. Spot-check with `git log --merges $LAST_TAG..HEAD` as a cross-reference.
- **Don't run `gem yank`** under any circumstance without explicit user instruction — it's publicly visible, pulls the gem from rubygems for all consumers, and is not reversible.
