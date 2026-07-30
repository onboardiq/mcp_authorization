#!/usr/bin/env ruby
# frozen_string_literal: true

# Collects the repository's canonical markdown into site/content/ for Zola.
#
#   ruby site/collect.rb          # or: bundle exec rake site:collect
#
# The docs are authored once, in the repo root, and read there by anyone
# browsing GitHub. This script is the only thing that knows how to turn them
# into a paginated site: it splits the long files into one page per section,
# writes Zola front matter, and rewrites every cross-document link so it
# resolves inside the site rather than 404ing on a .md path.
#
# site/content/ is generated and gitignored. Never edit it — edit the source
# markdown in the repo root and re-run this.
#
# Sources, and how each is split:
#
#   README.md            -> content/reference/*  (one page per `## ` section)
#                           the intro above the first `##` becomes the home page
#   COOKBOOK.md          -> content/guide/*      (one page per `## ` section;
#                           the `## Recipes` link list is dropped — the sidebar
#                           replaces it)
#   CHANGELOG.md         -> content/releases/_index.md  (single page)
#   docs/designs/*.md    -> content/designs/*     (one page each)
#
# Anchors: every heading is stamped with an explicit `{#github-slug}` so links
# written for GitHub (`README.md#tool-grouping-facades`) keep resolving after
# the split. `zola check` validates them, so a bad rewrite fails CI.

require "fileutils"

ROOT       = File.expand_path("..", __dir__)
CONTENT    = File.join(__dir__, "content")
REPO_URL   = "https://github.com/onboardiq/mcp_authorization"
BLOB_URL   = "#{REPO_URL}/blob/main"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

# GitHub's heading-anchor algorithm, close enough for our headings: strip
# inline markdown, downcase, drop everything but word characters, spaces and
# hyphens, then hyphenate. Kept identical to GitHub's so that links authored
# against the markdown files keep working on the site.
def github_slug(text)
  text
    .gsub(/`([^`]*)`/, '\1')            # `code` -> code
    .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1') # [text](url) -> text
    .gsub(/[*_~]/, "")                   # emphasis markers
    .downcase
    .gsub(/[^a-z0-9 _-]/, "")
    .strip
    .gsub(/\s+/, "-")
end

def slugify_filename(text)
  base = github_slug(text).gsub("_", "-").gsub(/-+/, "-").gsub(/\A-|-\z/, "")
  base.empty? ? "section" : base
end

def toml_escape(text)
  text.gsub("\\", "\\\\\\\\").gsub('"', '\"')
end

# Titles are plain text — sidebar entries, <title>, card labels — so inline
# markdown in a heading ("`@requires` rules") would show up as literal
# backticks. Strip the markers, keep the words.
def plain_title(text)
  text.gsub(/`([^`]*)`/, '\1').gsub(/\*+/, "").strip
end

# Content between `<!-- site:skip -->` and `<!-- site:endskip -->` is dropped.
# It exists so the source markdown can carry repo-only asides — "read this on
# the docs site" — without them turning into self-references once collected.
def strip_skipped(markdown)
  markdown.gsub(/^[ \t]*<!--\s*site:skip\s*-->.*?<!--\s*site:endskip\s*-->[ \t]*\n?/m, "")
end

# First prose line of a section, flattened into a one-line description for the
# page card and the <meta description>.
def derive_description(body)
  in_fence = false
  line = body.lines.find do |l|
    if l.start_with?("```")
      in_fence = !in_fence
      next false
    end
    next false if in_fence # code is never a description

    s = l.strip
    # Skip headings, tables, quotes, comments and list items — but not a line
    # opening with bold (`**Problem.** ...`), which is exactly the sentence
    # every recipe wants as its description.
    !s.empty? && !s.start_with?("#", "|", ">", "<!--") && !s.match?(/\A([-+]|\*(?!\*)|\d+\.)\s/)
  end
  return nil unless line

  text = line.strip
             .gsub(/`([^`]*)`/, '\1')
             .gsub(/\[([^\]]*)\]\([^)]*\)/, '\1')
             .sub(/\A\*\*(Problem|Solution|Result)\.?\*\*\s*/i, "") # recipe labels
             .gsub(/\*+/, "") # emphasis only — `_` is left alone, it occurs in identifiers
  text = "#{text[0, 157].rstrip}..." if text.length > 160
  text
end

# Split a markdown document on `## ` headings that are not inside a fenced
# code block. Returns [intro, [{title:, body:}, ...]].
def split_sections(markdown)
  intro = +""
  sections = []
  current = nil
  in_fence = false

  markdown.each_line do |line|
    in_fence = !in_fence if line.start_with?("```")

    if !in_fence && line.start_with?("## ")
      current = { title: line.sub(/\A##\s+/, "").strip, body: +"" }
      sections << current
    elsif current
      current[:body] << line
    elsif line.start_with?("# ") && !in_fence
      next # document H1 becomes the page/site title, not body copy
    else
      intro << line
    end
  end

  [intro.strip, sections]
end

# Shift `###` and deeper up one level, because the section's own `##` heading
# has become the page title (an h1). Without this every page would start at h3
# and the table of contents would be empty.
def promote_headings(body)
  in_fence = false
  body.each_line.map do |line|
    in_fence = !in_fence if line.start_with?("```")
    next line if in_fence

    line.sub(/\A(\#{3,})(\s)/) { "#{::Regexp.last_match(1)[1..]}#{::Regexp.last_match(2)}" }
  end.join
end

# Stamp `{#slug}` on every heading so anchors survive the split intact.
def stamp_anchors(body, slugs_out)
  in_fence = false
  body.each_line.map do |line|
    in_fence = !in_fence if line.start_with?("```")
    next line if in_fence
    next line unless (m = line.match(/\A(\#{1,6})\s+(.*?)\s*\z/))

    slug = github_slug(m[2])
    slugs_out << slug
    "#{m[1]} #{m[2]} {##{slug}}\n"
  end.join
end

def front_matter(title:, weight:, description:, source:)
  lines = ["+++"]
  lines << "# Generated by site/collect.rb from #{source}. Do not edit — edit the source."
  lines << %(title = "#{toml_escape(title)}")
  lines << "weight = #{weight}" if weight
  lines << %(description = "#{toml_escape(description)}") if description
  lines << "[extra]"
  lines << %(source = "#{source}")
  lines << %(source_url = "#{BLOB_URL}/#{source}")
  lines << "+++"
  lines.join("\n")
end

def write_page(path, front, body)
  FileUtils.mkdir_p(File.dirname(path))
  # The `---` rules separating sections in the source files are page breaks
  # once each section is its own page; a trailing one renders as a stray line.
  cleaned = body.strip.sub(/\n+-{3,}\s*\z/, "")
  File.write(path, "#{front}\n\n#{cleaned.strip}\n")
end

# --------------------------------------------------------------------------
# link rewriting
# --------------------------------------------------------------------------

# Every anchor the site can resolve: "README.md#some-anchor" => "@/reference/x.md#some-anchor".
# Populated while splitting, applied in a second pass once every page exists.
class LinkIndex
  def initialize
    @pages = {}   # source file => [{ zola_path:, slugs:, own_slug: }]
    @roots = {}   # source file => zola path of the section index
  end

  def add_page(source, zola_path, own_slug, slugs)
    (@pages[source] ||= []) << { zola_path: zola_path, own_slug: own_slug, slugs: slugs }
  end

  def add_root(source, zola_path)
    @roots[source] = zola_path
  end

  def target_for(source, anchor)
    pages = @pages[source] || []

    if anchor.nil? || anchor.empty?
      return @roots[source]
    end

    # A link to a heading that became a page title lands on the page itself.
    page = pages.find { |p| p[:own_slug] == anchor }
    return page[:zola_path] if page

    page = pages.find { |p| p[:slugs].include?(anchor) }
    return "#{page[:zola_path]}##{anchor}" if page

    # Unknown anchor in a known file: fall back to the file's index page rather
    # than emitting a link `zola check` will reject.
    @roots[source]
  end

  def known?(source)
    @pages.key?(source) || @roots.key?(source)
  end
end

# Rewrites markdown links that point at repo paths. In-site targets become
# Zola internal links (`@/...`, which zola check validates); everything else
# becomes an absolute GitHub URL so it still resolves for a site reader.
#
# `source` is the document this body came from, which is what makes bare
# `#anchor` links work: in README.md they were same-page links, but after the
# split the target usually lives on a *different* page, so they resolve
# through the same index as any cross-document link.
def rewrite_links(body, index, source)
  body.gsub(/\]\((#?[^)\s]*)\)/) do
    whole = ::Regexp.last_match(0)
    href  = ::Regexp.last_match(1)

    next whole if href.empty?
    next whole if href.match?(%r{\A(?:[a-z][a-z0-9+.-]*:)}) # http:, https:, mailto:, ...

    target, anchor = href.split("#", 2)
    target = target.to_s.sub(%r{\A\./}, "")

    if target.empty?
      resolved = index.target_for(source, anchor)
      resolved ? "](#{resolved})" : whole
    elsif index.known?(target)
      resolved = index.target_for(target, anchor)
      resolved ? "](#{resolved})" : "](#{BLOB_URL}/#{target})"
    else
      "](#{BLOB_URL}/#{target.sub(%r{/\z}, '')})"
    end
  end
end

# --------------------------------------------------------------------------
# collection
# --------------------------------------------------------------------------

index = LinkIndex.new
staged = []   # [path, front_matter, raw_body] — bodies get links rewritten after indexing

def stage(staged, index, source:, path:, title:, weight:, body:, own_slug: nil)
  slugs = []
  stamped = stamp_anchors(body, slugs)
  description = derive_description(body)
  front = front_matter(title: title, weight: weight, description: description, source: source)
  staged << [path, front, stamped, source]
  index.add_page(source, zola_link(path), own_slug, slugs)
end

# content/reference/foo.md -> @/reference/foo.md
def zola_link(path)
  "@/#{path.sub(%r{\A#{Regexp.escape(CONTENT)}/}, '')}"
end

FileUtils.rm_rf(CONTENT)
FileUtils.mkdir_p(CONTENT)

# --- README.md -> home intro + reference pages ----------------------------

readme_intro, readme_sections = split_sections(strip_skipped(File.read(File.join(ROOT, "README.md"))))
index.add_root("README.md", "@/reference/_index.md")

readme_sections.each_with_index do |section, i|
  path = File.join(CONTENT, "reference", "#{slugify_filename(section[:title])}.md")
  stage(staged, index,
        source: "README.md",
        path: path,
        title: plain_title(section[:title]),
        weight: i + 1,
        body: promote_headings(section[:body]),
        own_slug: github_slug(section[:title]))
end

# --- COOKBOOK.md -> guide pages -------------------------------------------

cookbook_intro, cookbook_sections = split_sections(strip_skipped(File.read(File.join(ROOT, "COOKBOOK.md"))))
index.add_root("COOKBOOK.md", "@/guide/_index.md")

# The `## Recipes` bullet list is a hand-maintained table of contents; the
# sidebar is generated from the same pages, so shipping both is duplication.
cookbook_sections.reject! { |s| s[:title] == "Recipes" }

cookbook_sections.each_with_index do |section, i|
  # "16. Group a large domain into facades" -> file 16-group-...; the leading
  # number is meaningful (recipes are referred to by number) so it stays in
  # both the slug and the title.
  path = File.join(CONTENT, "guide", "#{slugify_filename(section[:title])}.md")
  stage(staged, index,
        source: "COOKBOOK.md",
        path: path,
        title: plain_title(section[:title]),
        weight: i + 1,
        body: promote_headings(section[:body]),
        own_slug: github_slug(section[:title]))
end

# --- CHANGELOG.md -> releases section -------------------------------------

changelog = strip_skipped(File.read(File.join(ROOT, "CHANGELOG.md")))
changelog_body = changelog.sub(/\A#[^\n]*\n/, "")
index.add_root("CHANGELOG.md", "@/releases/_index.md")

changelog_slugs = []
staged << [
  File.join(CONTENT, "releases", "_index.md"),
  [
    "+++",
    "# Generated by site/collect.rb from CHANGELOG.md. Do not edit — edit the source.",
    %(title = "Releases"),
    "weight = 4",
    %(description = "Every released version, what changed in it, and why."),
    %(sort_by = "weight"),
    %(template = "section.html"),
    "[extra]",
    %(source = "CHANGELOG.md"),
    %(source_url = "#{BLOB_URL}/CHANGELOG.md"),
    "+++"
  ].join("\n"),
  stamp_anchors(changelog_body, changelog_slugs),
  "CHANGELOG.md"
]
index.add_page("CHANGELOG.md", "@/releases/_index.md", nil, changelog_slugs)

# --- docs/designs/*.md -> designs section ---------------------------------

design_files = Dir[File.join(ROOT, "docs", "designs", "*.md")].sort
design_files.each_with_index do |file, i|
  source = file.sub("#{ROOT}/", "")
  raw = strip_skipped(File.read(file))
  h1 = raw[/\A#\s+(.*)$/, 1] || File.basename(file, ".md")
  body = raw.sub(/\A#[^\n]*\n/, "")

  path = File.join(CONTENT, "designs", "#{File.basename(file, '.md')}.md")
  stage(staged, index,
        source: source,
        path: path,
        title: plain_title(h1.sub(/\ADesign:\s*/, "")),
        weight: i + 1,
        body: body,
        own_slug: nil)
  index.add_root(source, zola_link(path))
end

# --- generated section indexes and home -----------------------------------

staged << [
  File.join(CONTENT, "_index.md"),
  [
    "+++",
    "# Generated by site/collect.rb from README.md. Do not edit — edit the source.",
    %(title = "mcp_authorization"),
    %(sort_by = "weight"),
    "+++"
  ].join("\n"),
  readme_intro,
  "README.md"
]

staged << [
  File.join(CONTENT, "guide", "_index.md"),
  [
    "+++",
    "# Generated by site/collect.rb from COOKBOOK.md. Do not edit — edit the source.",
    %(title = "Cookbook"),
    %(description = "Task-oriented recipes: I want to do X, what do I write?"),
    "weight = 1",
    %(sort_by = "weight"),
    %(template = "section.html"),
    %(page_template = "page.html"),
    "[extra]",
    %(source = "COOKBOOK.md"),
    %(source_url = "#{BLOB_URL}/COOKBOOK.md"),
    "+++"
  ].join("\n"),
  cookbook_intro,
  "COOKBOOK.md"
]

staged << [
  File.join(CONTENT, "reference", "_index.md"),
  [
    "+++",
    "# Generated by site/collect.rb from README.md. Do not edit — edit the source.",
    %(title = "Reference"),
    %(description = "Every option, DSL method, annotation tag, and lifecycle detail."),
    "weight = 2",
    %(sort_by = "weight"),
    %(template = "section.html"),
    %(page_template = "page.html"),
    "[extra]",
    %(source = "README.md"),
    %(source_url = "#{BLOB_URL}/README.md"),
    "+++"
  ].join("\n"),
  "One page per section of the project README.",
  "README.md"
]

staged << [
  File.join(CONTENT, "designs", "_index.md"),
  [
    "+++",
    "# Generated by site/collect.rb from docs/designs/. Do not edit — edit the source.",
    %(title = "Design docs"),
    %(description = "The reasoning behind larger features, as written before they shipped."),
    "weight = 3",
    %(sort_by = "weight"),
    %(template = "section.html"),
    %(page_template = "page.html"),
    "[extra]",
    %(source = "docs/designs"),
    %(source_url = "#{REPO_URL}/tree/main/docs/designs"),
    "+++"
  ].join("\n"),
  "Design documents for features large enough to warrant one. These describe intent at the time of writing and are not updated as the implementation evolves.",
  "docs/designs"
]

# --- write everything, with links rewritten now that the index is complete --

staged.each do |path, front, body, source|
  write_page(path, front, rewrite_links(body, index, source))
end

puts "collected #{staged.size} pages into #{CONTENT.sub("#{ROOT}/", '')}/"
puts "  README.md      -> #{readme_sections.size} reference pages"
puts "  COOKBOOK.md    -> #{cookbook_sections.size} guide pages"
puts "  CHANGELOG.md   -> 1 releases page"
puts "  docs/designs/  -> #{design_files.size} design pages"
