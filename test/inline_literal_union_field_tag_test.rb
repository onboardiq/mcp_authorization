require_relative "test_helper"
require "tmpdir"
require "fileutils"

# Regression for issue surfaced by HRAI-2065 (Fountain/Hire): a record field
# whose type is an *inline* string-literal union carrying a single
# field-level tag — `logic: "AND" | "OR" @desc(...)` — was misclassified by
# `compile_tagged_record` as a *per-member*-tagged union (the
# `stage: a @feature(x) | b @feature(y)` shape from nested_predicate_gating_test.rb).
#
# `tagged_union_field?` only checked "does the type_str contain `@`
# anywhere" + "does it split into >1 `|`-separated parts" — both true here,
# even though the `@desc(...)` tag trails the *whole field*, not an
# individual member. Misrouting into `compile_tagged_union` then calls
# `resolve_type` on each bare literal (`"AND"`, `"OR"`), which only knows
# how to resolve *named alias references*, not literals — so each member
# fell back to `{type: "object"}`, producing a meaningless
# `{type: "object", oneOf: [{type: "object"}, {type: "object"}]}` instead
# of `{type: "string", enum: ["AND", "OR"]}`.
class InlineLiteralUnionFieldTagTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def test_inline_literal_union_with_trailing_field_tag_resolves_to_enum
    handler = build_handler(<<~SRC)
      # @rbs type rule_conditions = {
      #   logic: "AND" | "OR" @desc(How condition_groups combine — AND requires all; OR requires any),
      #   condition_groups: Array[String] @desc(One or more conditions)
      # }
      class <%= klass_name %>
        #: (conditions: rule_conditions) -> untyped
        def call(**); end
      end
    SRC

    schema = C.compile_input(handler, server_context: StubContext.new([]))
    logic = schema.dig(:properties, :conditions, :properties, :logic)

    assert_equal "string", logic[:type]
    assert_equal %w[AND OR], logic[:enum]
    assert_equal "How condition_groups combine — AND requires all; OR requires any", logic[:description]
  end

  def test_inline_literal_union_field_tag_does_not_affect_genuine_per_member_tagged_union
    # Guard against a fix that over-corrects: a real per-member-tagged union
    # (every member carries its own predicate tag) must still route through
    # compile_tagged_union and gate per member.
    handler = build_handler(<<~SRC)
      # @rbs type alpha = { type: "Alpha", a: String }
      # @rbs type beta = { type: "Beta", b: String }
      class <%= klass_name %>
        # @rbs type input = {
        #   stage: alpha @stage_ok(Alpha) | beta @stage_ok(Beta)
        # }
        #: (**untyped) -> untyped
        def call(**); end
      end
    SRC

    ctx = Object.new
    def ctx.requires?(_) = true
    def ctx.feature?(_) = true
    def ctx.hidden?(_) = false
    def ctx.current_user = nil
    def ctx.stage_ok?(name) = name.to_s == "Alpha"

    schema = C.compile_input(handler, server_context: ctx)
    stage = schema.dig(:properties, :stage)

    refute stage[:oneOf], "single surviving member should not be wrapped in oneOf"
    assert_equal "Alpha", stage.dig(:properties, :type, :const)
  end

  def build_handler(template)
    klass_name = "InlineLiteralUnionFieldTagHandler_#{self.class.next_serial}"
    src = template.gsub("<%= klass_name %>", klass_name)
    dir = File.join(Dir.tmpdir, "mcp_auth_inline_literal_union_#{Process.pid}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{klass_name.downcase}.rb")
    File.write(path, src)
    load path
    C.reset_cache!
    Object.const_get(klass_name)
  end

  @@serial = 0
  def self.next_serial
    @@serial += 1
  end
end
