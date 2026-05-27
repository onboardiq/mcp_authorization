require_relative "test_helper"

# Cross-cutting tests for the bracket-aware parsing helpers introduced
# in 0.5.1 to close issue #15 and the broader family of "parser breaks
# when tag values contain the delimiter character" bugs.
#
# The historical regex parser used flat patterns like `[^)]*`, `[^,}]+`
# and bare `.split("|")` to find delimiters. These cannot track nested
# brackets — a fundamental limitation of regular expressions. The
# bracket-aware helpers count `()`, `[]`, `{}` depth while scanning,
# so delimiters inside any balanced pair are skipped.
#
# Each section exercises one of:
#   1. The primitives in isolation: find_at_depth_zero,
#      split_at_depth_zero, peel_trailing_tag, find_matching_open_paren.
#   2. Each of the 4 call sites that historically had a flat-regex bug
#      (extract_tags, compile_tagged_record, parse_record_type,
#      compile_tagged_union / rbs_type_to_json_schema union split).
#   3. Sentinel test for the original set_concept-style bug
#      (nested parens in @desc) so future regressions are caught.
#   4. End-to-end via compile_input from a real on-disk handler file —
#      the path that no unit test was exercising and let the bug ship.
class BracketAwareParsingTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # ----------------------------------------------------------------
  # Primitive: find_at_depth_zero
  # ----------------------------------------------------------------

  def test_find_at_depth_zero_simple_match
    assert_equal 1, C.send(:find_at_depth_zero, "a,b", [","])
  end

  def test_find_at_depth_zero_skips_paren_pair
    # The comma inside () is at depth 1, so we skip it and return
    # the position of the comma at depth 0.
    assert_equal 12, C.send(:find_at_depth_zero, "a, b, (c, d), e", [","], start: 5)
  end

  def test_find_at_depth_zero_skips_square_brackets
    # Array literal commas should not split a tag value.
    assert_nil C.send(:find_at_depth_zero, "[a, b, c]", [","])
  end

  def test_find_at_depth_zero_skips_braces
    assert_nil C.send(:find_at_depth_zero, "{a: 1, b: 2}", [","])
  end

  def test_find_at_depth_zero_returns_nil_when_no_match
    assert_nil C.send(:find_at_depth_zero, "(no delim here)", [","])
  end

  def test_find_at_depth_zero_multiple_delimiters
    # Find the first of "," or ";" at depth 0.
    assert_equal 3, C.send(:find_at_depth_zero, "abc; def, ghi", [",", ";"])
  end

  def test_find_at_depth_zero_start_offset
    # "a, b, c" — commas at positions 1 and 4. Starting at position 2
    # (past the first comma), the next match is the comma at 4.
    assert_equal 4, C.send(:find_at_depth_zero, "a, b, c", [","], start: 2)
  end

  def test_find_at_depth_zero_empty_string
    assert_nil C.send(:find_at_depth_zero, "", [","])
  end

  # ----------------------------------------------------------------
  # Primitive: split_at_depth_zero
  # ----------------------------------------------------------------

  def test_split_at_depth_zero_basic
    assert_equal ["a", " b", " c"], C.send(:split_at_depth_zero, "a, b, c", ",")
  end

  def test_split_at_depth_zero_preserves_paren_groups
    # The (c, d) group should stay intact as a single segment.
    assert_equal ["a", " b", " (c, d)", " e"],
      C.send(:split_at_depth_zero, "a, b, (c, d), e", ",")
  end

  def test_split_at_depth_zero_pipe_in_union
    parts = C.send(:split_at_depth_zero, "String | Integer | Float", "|").map(&:strip)
    assert_equal %w[String Integer Float], parts
  end

  def test_split_at_depth_zero_pipe_inside_paren_protected
    # `option a | b` inside @desc(...) must not split the union.
    parts = C.send(:split_at_depth_zero, "a @desc(option a | b) | c", "|").map(&:strip)
    assert_equal ["a @desc(option a | b)", "c"], parts
  end

  def test_split_at_depth_zero_empty_string
    assert_equal [""], C.send(:split_at_depth_zero, "", ",")
  end

  def test_split_at_depth_zero_no_delim
    assert_equal ["abc"], C.send(:split_at_depth_zero, "abc", ",")
  end

  # ----------------------------------------------------------------
  # Primitive: peel_trailing_tag
  # ----------------------------------------------------------------

  def test_peel_trailing_tag_simple
    assert_equal ["Integer", "min", "1"], C.send(:peel_trailing_tag, "Integer @min(1)")
  end

  def test_peel_trailing_tag_with_nested_parens
    # The very bug from set_concept.rb in the monolith.
    result = C.send(:peel_trailing_tag, "Integer @desc(foo (bar). Required.)")
    assert_equal ["Integer", "desc", "foo (bar). Required."], result
  end

  def test_peel_trailing_tag_with_commas_in_value
    # Andrew's issue #15.
    result = C.send(:peel_trailing_tag, "String @desc(Hello, world)")
    assert_equal ["String", "desc", "Hello, world"], result
  end

  def test_peel_trailing_tag_with_pipes_in_value
    result = C.send(:peel_trailing_tag, "String @desc(option a | b)")
    assert_equal ["String", "desc", "option a | b"], result
  end

  def test_peel_trailing_tag_with_brackets_in_value
    result = C.send(:peel_trailing_tag, "String @example([1, 2, 3])")
    assert_equal ["String", "example", "[1, 2, 3]"], result
  end

  def test_peel_trailing_tag_multiple_tags_peels_last
    # @min(1) is the trailing one. @desc is left for the next peel.
    type_str, name, value = C.send(:peel_trailing_tag, "Integer @desc(foo (bar)) @min(1)")
    assert_equal ["Integer @desc(foo (bar))", "min", "1"], [type_str, name, value]
  end

  def test_peel_trailing_tag_empty_value
    # @deprecated() — no-arg boolean tags.
    assert_equal ["String", "deprecated", ""], C.send(:peel_trailing_tag, "String @deprecated()")
  end

  def test_peel_trailing_tag_no_tag_returns_nil
    assert_nil C.send(:peel_trailing_tag, "Integer")
  end

  def test_peel_trailing_tag_unbalanced_parens_returns_nil
    # Unclosed paren — defensive, don't pretend to parse it.
    assert_nil C.send(:peel_trailing_tag, "Integer @desc(unclosed")
  end

  def test_peel_trailing_tag_at_without_whitespace_rejected
    # "Integer@desc(...)" — no whitespace before @, so it's not a tag
    # boundary. Matches prior regex semantics with \s+ before @.
    # (This is a guard against accidentally chopping identifiers.)
    assert_nil C.send(:peel_trailing_tag, "foo@bar()")
  end

  def test_peel_trailing_tag_at_at_start_is_valid
    # "@desc(foo)" alone — @ at position 0, no preceding char needed.
    result = C.send(:peel_trailing_tag, "@desc(foo)")
    assert_equal ["", "desc", "foo"], result
  end

  # ----------------------------------------------------------------
  # Call site 1: extract_tags with nested/commaed/piped values
  # ----------------------------------------------------------------

  def test_extract_tags_nested_parens_in_desc
    # The exact failure mode of the monolith's set_concept.rb @desc.
    type_str, tags = C.send(:extract_tags,
      "Integer @desc(The DataKey ID (NOT the question id). Required.) @min(1)")
    assert_equal "Integer", type_str
    assert_equal "The DataKey ID (NOT the question id). Required.", tags[:desc]
    assert_equal 1, tags[:min]
  end

  def test_extract_tags_comma_in_desc
    # Issue #15 — Andrew's original report.
    type_str, tags = C.send(:extract_tags, "String @desc(Hello, world)")
    assert_equal "String", type_str
    assert_equal "Hello, world", tags[:desc]
  end

  def test_extract_tags_pipe_in_desc
    type_str, tags = C.send(:extract_tags, "String @desc(option a | option b)")
    assert_equal "String", type_str
    assert_equal "option a | option b", tags[:desc]
  end

  def test_extract_tags_brackets_in_example
    type_str, tags = C.send(:extract_tags, "Array[Integer] @example([1, 2, 3])")
    assert_equal "Array[Integer]", type_str
    # @example parses through parse_default_value, which falls through
    # to delete quotes — for non-quoted bracket-strings, it returns
    # the literal text. Confirm the tag was at least extracted.
    assert tags[:examples].is_a?(Array)
    assert_equal 1, tags[:examples].size
  end

  def test_extract_tags_multiple_with_internal_punctuation
    type_str, tags = C.send(:extract_tags,
      "String @desc(prefix, NOT suffix) @format(email) @pattern(^[a-z]+$)")
    assert_equal "String", type_str
    assert_equal "prefix, NOT suffix", tags[:desc]
    assert_equal "email", tags[:format]
    assert_equal "^[a-z]+$", tags[:pattern]
  end

  def test_extract_tags_no_tag_returns_input_unchanged
    type_str, tags = C.send(:extract_tags, "Integer")
    assert_equal "Integer", type_str
    assert_equal({}, tags)
  end

  # ----------------------------------------------------------------
  # Call site 2: compile_tagged_record with commas inside @desc
  # ----------------------------------------------------------------

  def test_record_field_with_comma_in_desc_preserves_field_boundary
    # Pre-fix: the inner comma in @desc(Hello, world) was treated as a
    # field separator, fragmenting the record. Post-fix: the comma
    # stays inside the tag value, fields parse correctly.
    schema = C.send(:compile_tagged_record,
      "{ name: String @desc(Hello, world), age: Integer }", {}, nil)
    assert_equal %i[name age], schema[:properties].keys
    assert_equal "Hello, world", schema[:properties][:name][:description]
    assert_equal "integer", schema[:properties][:age][:type]
  end

  def test_record_field_with_nested_parens_in_desc
    schema = C.send(:compile_tagged_record,
      "{ data_key_id: Integer @desc(The ID (NOT the question id)) @min(1) }", {}, nil)
    assert_equal "integer", schema[:properties][:data_key_id][:type],
      "type must be integer, not the string fallback the pre-fix parser produced"
    assert_equal "The ID (NOT the question id)", schema[:properties][:data_key_id][:description]
    assert_equal 1, schema[:properties][:data_key_id][:minimum],
      "@min(1) on Integer must become :minimum, not :minLength"
  end

  def test_record_field_with_nested_record_in_type
    # Field with inline nested record. Outer comma split must skip the
    # inner braces.
    schema = C.send(:compile_tagged_record,
      "{ user: { name: String, age: Integer }, status: String }", {}, nil)
    assert_equal %i[user status], schema[:properties].keys
    assert_equal "object", schema[:properties][:user][:type]
    assert_equal %i[name age], schema[:properties][:user][:properties].keys
  end

  # ----------------------------------------------------------------
  # Call site 3: parse_record_type (nested/aliased records)
  # ----------------------------------------------------------------

  def test_parse_record_type_with_comma_in_desc
    schema = C.send(:parse_record_type, "{ label: String @desc(yes, no, maybe) }")
    assert_equal "yes, no, maybe", schema[:properties][:label][:description]
  end

  def test_parse_record_type_with_nested_parens
    schema = C.send(:parse_record_type, "{ id: Integer @desc(some (clarification) here) }")
    assert_equal "integer", schema[:properties][:id][:type]
    assert_equal "some (clarification) here", schema[:properties][:id][:description]
  end

  # ----------------------------------------------------------------
  # Call site 4: union splitting with pipe inside @desc
  # ----------------------------------------------------------------

  def test_union_split_protects_pipe_inside_tag
    # The split_at_depth_zero refactor: the | inside @desc must NOT
    # split the union. Pre-fix .split("|") would have produced 3 parts.
    type_map = {
      "alpha" => { type: "object", properties: { x: { type: "string" } } },
      "beta"  => { type: "object", properties: { y: { type: "string" } } }
    }
    schema = C.send(:compile_tagged_union,
      "alpha @desc(option a | b) | beta", type_map, nil)
    # Both variants present → wrapped in oneOf.
    assert schema.key?(:oneOf)
    assert_equal 2, schema[:oneOf].size
  end

  def test_inline_union_in_rbs_type_to_json_schema
    # rbs_type_to_json_schema's union branch is what handles unions
    # nested inside a record type expression.
    schema = C.send(:rbs_type_to_json_schema, '"red" | "green" | "blue"')
    assert_equal "string", schema[:type]
    assert_equal %w[red green blue], schema[:enum]
  end

  # ----------------------------------------------------------------
  # Sentinel test — documents the pre-0.5.1 set_concept bug
  # ----------------------------------------------------------------

  def test_set_concept_style_field_used_to_silently_miscompile
    # Pre-0.5.1: @desc(... (NOT the question id) ...) caused:
    #   1. extract_tags failed to peel the @desc (the inner ")" stopped [^)]*)
    #   2. type_str = "Integer @desc(...)" passed to rbs_type_to_json_schema
    #   3. None of the case branches matched → fallback {type: "string"}
    #   4. apply_tags({type: "string"}, {min: 1}) → minLength: 1 (wrong keyword)
    #
    # Final pre-fix schema:
    #   { type: "string", minLength: 1 }   ← WRONG type, wrong constraint
    #
    # Post-fix:
    #   { type: "integer", description: "...", minimum: 1 }   ← correct
    schema = C.send(:compile_tagged_record,
      "{ data_key_id: Integer @desc(The DataKey ID (NOT the question id). Required.) @min(1) }",
      {}, nil)

    field = schema[:properties][:data_key_id]
    assert_equal "integer", field[:type],
      "post-fix: type must be integer (pre-fix fallback was \"string\")"
    assert_equal 1, field[:minimum],
      "post-fix: @min(1) on Integer must produce :minimum (pre-fix produced :minLength on a string)"
    refute field.key?(:minLength),
      "post-fix: no :minLength leak from the string-fallback path"
    assert_match(/NOT the question id/, field[:description].to_s,
      "post-fix: nested-paren @desc must be captured verbatim")
  end

  # ----------------------------------------------------------------
  # End-to-end via compile_input from a real handler file —
  # this was the missing test that let issue #15 ship.
  # ----------------------------------------------------------------

  def test_compile_input_e2e_with_nested_parens_in_desc
    handler = build_handler(<<~SIG)
      #: (
      #:   data_key_id: Integer @desc(The DataKey ID (NOT the question id)) @min(1)
      #: ) -> untyped
    SIG

    schema = C.compile_input(handler, server_context: nil)
    field = schema[:properties][:data_key_id]
    assert_equal "integer", field[:type]
    assert_equal 1, field[:minimum]
    assert_match(/NOT the question id/, field[:description].to_s)
  end

  def test_compile_input_e2e_record_with_comma_in_desc
    handler = build_handler_with_record(<<~ANNOTATION)
      # @rbs type input = {
      #   label: String @desc(yes, no, maybe),
      #   ?count: Integer
      # }
    ANNOTATION

    schema = C.compile_input(handler, server_context: nil)
    assert_equal %i[label count], schema[:properties].keys
    assert_equal "yes, no, maybe", schema[:properties][:label][:description]
    assert_equal ["label"], schema[:required]
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  private

  def build_handler(sig)
    body = <<~RUBY
      class <%= klass_name %>
        #{sig.chomp}
        def call(**); end
      end
    RUBY
    write_handler(body)
  end

  def build_handler_with_record(annotation)
    body = <<~RUBY
      #{annotation}
      class <%= klass_name %>
        def call(**); end
      end
    RUBY
    write_handler(body)
  end

  def write_handler(template)
    require "tmpdir"
    require "fileutils"
    klass_name = "BracketAwareHandler_#{self.class.send(:next_serial)}"
    src = template.sub("<%= klass_name %>", klass_name)
    dir = File.join(Dir.tmpdir, "mcp_auth_bracket_#{Process.pid}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{klass_name.downcase}.rb")
    File.write(path, src)
    load path
    klass = Object.const_get(klass_name)
    C.reset_cache!
    klass
  end

  @@serial = 0
  def self.next_serial
    @@serial += 1
  end
end
