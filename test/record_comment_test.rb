require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "tempfile"

# Tests for issue #20: a `#` comment line inside an RBS record type
# (`{ ... }`) must not be folded into the next field name.
#
# Comments are valid anywhere in RBS — the official lexer discards
# `#`-to-end-of-line everywhere. The compiler's line-based readers
# concatenate record-body lines *without* a newline separator, so a
# comment used to merge into the following field and raise
# `ArgumentError: invalid field name token` from `parse_field_name`,
# which (because `tools/list` maps over every tool in a domain) took
# down discovery for the whole domain.
#
# Exercised here:
#   1. The primitive: strip_rbs_comment in isolation.
#   2. Each of the 3 line-readers that concatenate record bodies
#      (find_raw_type_body, parse_type_aliases, parse_rbs_file).
#   3. End-to-end via compile_input / compile_output from a real
#      on-disk handler file — the path that surfaced the bug at runtime.
class RecordCommentTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # ----------------------------------------------------------------
  # Primitive: strip_rbs_comment
  # ----------------------------------------------------------------

  def test_strip_full_line_comment
    assert_equal "", C.send(:strip_rbs_comment, "# a note describing the fields below")
  end

  def test_strip_trailing_comment_keeps_field
    assert_equal "id: String,", C.send(:strip_rbs_comment, "id: String, # the id")
  end

  def test_no_comment_returns_line_unchanged
    assert_equal "name: String", C.send(:strip_rbs_comment, "name: String")
  end

  def test_hash_inside_parens_is_not_a_comment
    # `#` inside a bracketed annotation value (e.g. a URL fragment in
    # @desc) is part of the value, not a comment.
    line = "url: String @desc(see http://x/y#frag)"
    assert_equal line, C.send(:strip_rbs_comment, line)
  end

  def test_hash_inside_string_literal_is_not_a_comment
    line = 'tag: "a#b"'
    assert_equal line, C.send(:strip_rbs_comment, line)
  end

  def test_comment_after_closing_bracket_is_stripped
    # `]` brings depth back to 0, so the following `#` starts a comment.
    assert_equal "ids: Array[Integer],",
      C.send(:strip_rbs_comment, "ids: Array[Integer], # a list")
  end

  # ----------------------------------------------------------------
  # Reader 1: parse_type_aliases (inline `# @rbs type X = { ... }`)
  # ----------------------------------------------------------------

  def test_parse_type_aliases_with_comment_in_record
    content = <<~RUBY
      class Foo
        # @rbs type example = {
        #   # a note describing the fields below
        #   id: String,
        #   name: String
        # }
        def call; end
      end
    RUBY

    aliases = C.send(:parse_type_aliases, content)
    assert_equal %i[id name], aliases["example"][:properties].keys
    assert_equal "object", aliases["example"][:type]
  end

  def test_parse_type_aliases_with_trailing_comment_on_field
    content = <<~RUBY
      class Foo
        # @rbs type example = {
        #   id: String, # primary key
        #   name: String # display name
        # }
        def call; end
      end
    RUBY

    aliases = C.send(:parse_type_aliases, content)
    assert_equal %i[id name], aliases["example"][:properties].keys
  end

  # ----------------------------------------------------------------
  # Reader 2: parse_rbs_file (shared sig/shared/*.rbs alias)
  # ----------------------------------------------------------------

  def test_parse_rbs_file_with_comment_in_record
    file = Tempfile.new(["shared_with_comment", ".rbs"])
    file.write(<<~RBS)
      type example = {
        # a note describing the fields below
        id: String,
        name: String
      }
    RBS
    file.flush

    result = C.send(:parse_rbs_file, file.path)
    assert_equal %i[id name], result["example"][:properties].keys
  ensure
    file.close
    file.unlink
  end

  # ----------------------------------------------------------------
  # Reader 3 + end-to-end: find_raw_type_body via compile_input
  # (inline `# @rbs type input = { ... }`)
  # ----------------------------------------------------------------

  def test_compile_input_e2e_with_comment_in_input_record
    handler = build_handler(<<~RUBY)
      # @rbs type input = {
      #   # the applicant's stable identifier
      #   id: String,
      #   name: String
      # }
      #: (input) -> untyped
    RUBY

    schema = C.compile_input(handler, server_context: nil)
    assert_equal %i[id name], schema[:properties].keys
    assert_equal %w[id name], schema[:required]
  end

  # ----------------------------------------------------------------
  # End-to-end: the exact reproduction from issue #20.
  # output = example, where `example` carries an in-record comment.
  # ----------------------------------------------------------------

  def test_compile_output_e2e_matches_issue_reproduction
    handler = build_handler(<<~RUBY)
      # @rbs type example = {
      #   # a note describing the fields below
      #   id: String,
      #   name: String
      # }
      # @rbs type output = example
      #: () -> output
    RUBY

    schema = C.compile_output(handler, server_context: nil)
    assert_equal %i[id name], schema[:properties].keys
    assert_equal %w[id name], schema[:required]
  end

  # ----------------------------------------------------------------
  # Helpers (mirrors bracket_aware_parsing_test's on-disk handler
  # pattern so the source-location-based compiler has a real file).
  # ----------------------------------------------------------------

  private

  def build_handler(annotation)
    klass_name = "RecordCommentHandler_#{self.class.send(:next_serial)}"
    body = <<~RUBY
      class #{klass_name}
        #{annotation.chomp.gsub("\n", "\n  ")}
        def call(**); end
      end
    RUBY

    dir = File.join(Dir.tmpdir, "mcp_auth_record_comment_#{Process.pid}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{klass_name.downcase}.rb")
    File.write(path, body)
    load path
    C.reset_cache!
    Object.const_get(klass_name)
  end

  @@serial = 0
  def self.next_serial
    @@serial += 1
  end
end
