# Documentation site

The [Zola](https://www.getzola.org) source for
<https://fountain.engineering/mcp_authorization>.

> The org's user site (`onboardiq.github.io`) carries the custom domain
> `fountain.engineering`, so this project site serves from that domain under the
> `/mcp_authorization` path. That host lives in `config.toml` as `base_url` — see the comment
> there for why it is hardcoded rather than read from `actions/configure-pages`.

**The site has no content of its own.** Every page is collected from the markdown in the repository
root by `collect.rb` at build time. Those files are the source of truth — they are what people read
on GitHub, and editing them is what updates the site.

| Source | Becomes |
|---|---|
| `README.md` | one page per `## ` section, under `/reference/`; the intro above the first `##` becomes the home page |
| `COOKBOOK.md` | one page per `## ` section, under `/guide/` (the `## Recipes` link list is dropped — the sidebar replaces it) |
| `CHANGELOG.md` | `/releases/` |
| `docs/designs/*.md` | one page each, under `/designs/` |

To add a source, add a block to `collect.rb`. The navigation, the home page, and the section
listings are all generated from whatever it produced, so no template changes are needed.

## Local development

```sh
brew install zola          # or see getzola.org/documentation/getting-started/installation

bundle exec rake site:serve   # collect + zola serve on http://127.0.0.1:1111
bundle exec rake site:build   # collect + zola build -> site/public
```

Or run the pieces directly:

```sh
ruby site/collect.rb
cd site && zola build && zola check --skip-external-links
```

`zola serve` overrides `base_url` automatically, so local links work despite the production
`base_url` carrying the `/mcp_authorization` sub-path. Note that `zola serve`'s live reload watches
`site/content/`, not the source markdown — re-run `rake site:serve` after editing `README.md`.

## Layout

```
site/
  collect.rb               the collector: split, front matter, link rewriting
  config.toml              base_url, syntax themes, extra.gem_version
  content/                 GENERATED — gitignored, never edit
  templates/               base / index / section / page / 404
  static/css/style.css     the whole stylesheet, light + dark
```

Three things under `site/` are generated and gitignored: `content/`, `public/`, and
`static/giallo-{light,dark}.css` (the syntax themes Zola writes from `[markdown.highlighting]` —
change the colors by swapping `light_theme` / `dark_theme` in `config.toml`, not by editing them).

## How links survive the split

Cross-document links in the source markdown (`README.md#tool-grouping-facades`,
`COOKBOOK.md`, `docs/designs/tool-grouping-facades.md`) are written for GitHub, where the files sit
next to each other. The collector rewrites them:

- Every heading is stamped with an explicit `{#github-slug}`, so an anchor written for GitHub still
  resolves after a document is split into pages.
- Links to a collected file become Zola internal links (`@/reference/tool-grouping-facades.md`).
- Links to anything else in the repo become absolute GitHub URLs.

`zola check` validates internal links **and anchors**, and it runs in CI, so a rewrite that misses
fails the build rather than shipping a dead link.

## Deployment

`.github/workflows/site.yml` builds on every push to `main` that touches `site/`, `README.md`,
`COOKBOOK.md`, `CHANGELOG.md`, or `docs/designs/`, and deploys to GitHub Pages. Pull requests build
and link-check without publishing.

One repository setting is required: **Settings → Pages → Build and deployment → Source: GitHub
Actions.** The workflow requests `pages: write` and `id-token: write` itself.

The workflow pins `ZOLA_VERSION`; bump it there when you want a newer Zola.

## When the gem changes

- `config.toml` → `extra.gem_version` is shown in the header and footer. Bump it with each release.
- Everything else follows from editing the repo's markdown. There is nothing to keep in sync here.
