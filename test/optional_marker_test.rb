require_relative "test_helper"
require "stringio"
require "tmpdir"
require "fileutils"

# Cross-cutting tests for the prefix/suffix optional marker parsing fix
# introduced in 0.5.0. Exercises all three sibling parsers
# (+compile_tagged_record+, +parse_record_type+, +parse_call_params+)
# plus the +parse_field_name+ helper they share, the deprecation
# warning surface, and the end-to-end compile_input path that the
# original bug made silently produce wrong schemas.
#
# Sentinel test: the docstring on +test_prefix_marker_used_to_be_silently_ignored+
# documents the pre-0.5.0 behavior so a future regression is caught.
class OptionalMarkerTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # ----------------------------------------------------------------
  # parse_field_name helper — edge cases the reviewers called out
  # ----------------------------------------------------------------

  def test_helper_unmarked
    assert_equal ["name", false], C.send(:parse_field_name, "name")
  end

  def test_helper_prefix
    assert_equal ["name", true], C.send(:parse_field_name, "?name")
  end

  def test_helper_suffix_emits_deprecation
    silence_deprecation { assert_equal ["name", true], C.send(:parse_field_name, "name?") }
  end

  def test_helper_strips_whitespace_after_prefix_marker
    # " ? key" must yield "key" (not " key") even though there's a
    # space between the marker and the identifier. Belongs in the helper,
    # not the call-site regex, so all three parsers get this for free.
    # (Pure prefix — never triggers the suffix-deprecation path.)
    assert_equal ["key", true], C.send(:parse_field_name, " ? key")
  end

  def test_helper_empty_raises
    assert_raises(ArgumentError) { C.send(:parse_field_name, "") }
    assert_raises(ArgumentError) { C.send(:parse_field_name, "   ") }
  end

  def test_helper_nil_raises
    # Defensive — the parser regex never captures nil in practice, but
    # the helper guards against it explicitly so a misuse from a future
    # caller fails loudly instead of producing a NoMethodError on String#strip.
    assert_raises(ArgumentError) { C.send(:parse_field_name, nil) }
  end

  def test_helper_bare_marker_raises
    assert_raises(ArgumentError) { C.send(:parse_field_name, "?") }
  end

  def test_helper_double_marked_raises
    # "?key?" raises via the `prefix && suffix` guard before the
    # suffix-deprecation warn is reached — no Warning silencing needed.
    err = assert_raises(ArgumentError) { C.send(:parse_field_name, "?key?") }
    assert_match(/double-marked/, err.message)
  end

  def test_helper_double_prefix_raises
    assert_raises(ArgumentError) { C.send(:parse_field_name, "??key") }
  end

  def test_helper_double_suffix_raises
    # "key??" raises via the \A\w+\z match guard (bare="key?" after
    # stripping one trailing `?`) before the suffix-deprecation warn
    # is reached — no Warning silencing needed.
    assert_raises(ArgumentError) { C.send(:parse_field_name, "key??") }
  end

  # ----------------------------------------------------------------
  # compile_tagged_record — formerly accepted ONLY suffix form
  # ----------------------------------------------------------------

  def test_record_prefix_marker_is_optional
    schema = silence_deprecation do
      C.send(:compile_tagged_record, "{ name: String, ?count: Integer }", {}, nil)
    end
    assert_includes schema[:properties].keys, :name
    assert_includes schema[:properties].keys, :count
    assert_equal ["name"], schema[:required]
  end

  def test_record_suffix_marker_is_optional_with_deprecation
    msg = capture_deprecation do
      schema = C.send(:compile_tagged_record, "{ name: String, count?: Integer }", {}, nil)
      assert_equal ["name"], schema[:required]
      assert_includes schema[:properties].keys, :count
    end
    assert_match(/Deprecated optional marker.*`count\?:`/, msg)
    assert_match(/Use prefix form `\?count:`/, msg)
  end

  def test_record_unmarked_is_required
    schema = C.send(:compile_tagged_record, "{ name: String, count: Integer }", {}, nil)
    assert_equal %w[name count], schema[:required]
  end

  def test_record_prefix_marker_combines_with_requires_tag
    # The original failure mode of the bug was prefix + tag interaction:
    # `?secret: String @requires(:admin)` got the tag applied but the
    # field was silently required. Verify the combo works now.
    ctx = StubContext.new([:admin])
    schema = silence_deprecation do
      C.send(:compile_tagged_record, "{ name: String, ?secret: String @requires(:admin) }", {}, ctx)
    end
    assert_includes schema[:properties].keys, :secret
    assert_equal ["name"], schema[:required], "?secret is optional and must not be in required"
  end

  def test_record_double_marked_raises
    silence_deprecation do
      assert_raises(ArgumentError) do
        C.send(:compile_tagged_record, "{ ?key?: Integer }", {}, nil)
      end
    end
  end

  # ----------------------------------------------------------------
  # parse_record_type — formerly recognized NEITHER form
  # ----------------------------------------------------------------

  def test_parse_record_type_prefix_marker
    schema = silence_deprecation do
      C.send(:parse_record_type, "{ name: String, ?count: Integer }")
    end
    assert_equal ["name"], schema[:required]
    assert_includes schema[:properties].keys, :count
  end

  def test_parse_record_type_suffix_marker_with_deprecation
    msg = capture_deprecation do
      schema = C.send(:parse_record_type, "{ name: String, count?: Integer }")
      assert_equal ["name"], schema[:required]
    end
    assert_match(/Deprecated optional marker.*`count\?:`/, msg)
  end

  def test_parse_record_type_unmarked
    schema = C.send(:parse_record_type, "{ name: String, count: Integer }")
    assert_equal %w[name count], schema[:required]
  end

  def test_parse_record_type_double_marked_raises
    silence_deprecation do
      assert_raises(ArgumentError) do
        C.send(:parse_record_type, "{ ?key?: Integer }")
      end
    end
  end

  # ----------------------------------------------------------------
  # parse_call_params — formerly accepted ONLY prefix form
  # ----------------------------------------------------------------

  def test_parse_call_params_prefix_marker
    src = <<~RUBY
      #: (name: String, ?count: Integer) -> untyped
      def call(name:, count: nil); end
    RUBY
    params = C.send(:parse_call_params, src)
    count = params.find { |p| p[:name] == "count" }
    refute_nil count
    refute count[:required], "?count must be optional"

    name = params.find { |p| p[:name] == "name" }
    assert name[:required], "name (unmarked) must be required"
  end

  def test_parse_call_params_suffix_marker_with_deprecation
    src = <<~RUBY
      #: (name: String, count?: Integer) -> untyped
      def call(name:, count: nil); end
    RUBY

    msg = capture_deprecation do
      params = C.send(:parse_call_params, src)
      count = params.find { |p| p[:name] == "count" }
      refute_nil count
      refute count[:required], "count? must be optional"
    end
    assert_match(/Deprecated optional marker.*`count\?:`/, msg)
  end

  def test_parse_call_params_nullable_type_still_optional
    # Preserved behavior (out-of-scope to change): nullable type
    # `Integer?` makes the param non-required even without a marker.
    src = <<~RUBY
      #: (name: String, count: Integer?) -> untyped
      def call(name:, count: nil); end
    RUBY
    params = C.send(:parse_call_params, src)
    count = params.find { |p| p[:name] == "count" }
    refute count[:required], "Integer? type makes param optional"
  end

  def test_parse_call_params_double_marked_raises
    src = <<~RUBY
      #: (?count?: Integer) -> untyped
      def call(count: nil); end
    RUBY
    silence_deprecation do
      assert_raises(ArgumentError) { C.send(:parse_call_params, src) }
    end
  end

  # ----------------------------------------------------------------
  # End-to-end: compile_input from a fake handler — the inconsistency
  # between parsers used to be invisible because no single test
  # exercised the full pipeline. This one would have caught it.
  # ----------------------------------------------------------------

  def test_compile_input_record_prefix_marker_e2e
    handler = build_handler_with_input(<<~ANNOTATION)
      # @rbs type input = {
      #   name: String,
      #   ?count: Integer
      # }
    ANNOTATION

    schema = silence_deprecation { C.compile_input(handler, server_context: nil) }
    assert_equal ["name"], schema[:required]
    assert_includes schema[:properties].keys, :count
  end

  def test_compile_input_call_signature_prefix_marker_e2e
    handler = build_handler_with_call(<<~SIG)
      #: (name: String, ?count: Integer) -> untyped
    SIG

    schema = C.compile_input(handler, server_context: nil)
    # Call-signature path wraps in a top-level object envelope.
    assert_equal ["name"], schema[:required]
    assert_includes schema[:properties].keys, :count
  end

  # ----------------------------------------------------------------
  # Sentinel test — documents the pre-fix bug so future regressions
  # are flagged.
  # ----------------------------------------------------------------

  def test_prefix_marker_used_to_be_silently_ignored
    # Pre-0.5.0 bug: `?count: Integer` in a record was parsed as a
    # field literally named "?count" (because the inner regex was
    # `(\w+\??)`, which doesn't allow a leading `?`), so the scan
    # produced no match, the field was dropped, and any field that
    # DID match was treated as required regardless of its marker.
    # Post-fix: the field is captured AND correctly excluded from
    # `required`.
    schema = silence_deprecation do
      C.send(:compile_tagged_record, "{ ?count: Integer }", {}, nil)
    end

    # The pre-fix behavior would have yielded:
    #   { type: "object", properties: {} } (no count, no required)
    # The post-fix behavior:
    assert_includes schema[:properties].keys, :count,
      "post-fix: ?count must be captured as a property"
    refute_includes(schema[:required] || [], "count",
      "post-fix: ?count must not be in required")
    refute_includes schema[:properties].keys, :"?count",
      "post-fix: the field name must not include the leading marker"
  end

  # ----------------------------------------------------------------
  # Deprecation warning semantics
  # ----------------------------------------------------------------

  def test_deprecation_silenced_by_warning_category_flag
    # Standard Ruby silencing: Warning[:deprecated] = false suppresses
    # warnings emitted with category: :deprecated. We rely on this
    # instead of a custom gem-specific dedup or env var.
    prior = Warning[:deprecated]
    Warning[:deprecated] = false
    begin
      out = capture_stderr do
        C.send(:parse_field_name, "name?")
      end
      assert_equal "", out
    ensure
      Warning[:deprecated] = prior
    end
  end

  def test_deprecation_includes_source_file_when_provided
    msg = capture_deprecation do
      C.send(:parse_field_name, "name?", source_file: "/path/to/handler.rb")
    end
    assert_match %r{/path/to/handler\.rb}, msg
  end

  def test_deprecation_omits_source_file_clause_when_absent
    msg = capture_deprecation do
      C.send(:parse_field_name, "name?")
    end
    refute_match(/\(in /, msg)
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  private

  def capture_stderr
    prior = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = prior
  end

  def capture_deprecation(&block)
    capture_stderr(&block)
  end

  def silence_deprecation
    prior = Warning[:deprecated]
    Warning[:deprecated] = false
    yield
  ensure
    Warning[:deprecated] = prior
  end

  # Build a handler class whose source file contains the given
  # `# @rbs type input = { ... }` annotation followed by a `#call`
  # method. The schema compiler's source-file discovery walks
  # `Method#source_location`, so we have to write a real file the
  # `instance_method(:call)` of our fake class points at.
  def build_handler_with_input(annotation)
    body = <<~RUBY
      #{annotation}
      class <%= klass_name %>
        def call(**); end
      end
    RUBY
    write_handler(body)
  end

  def build_handler_with_call(sig)
    body = <<~RUBY
      class <%= klass_name %>
        #{sig.chomp}
        def call(**); end
      end
    RUBY
    write_handler(body)
  end

  def write_handler(template)
    klass_name = "OptMarkerHandler_#{self.class.send(:next_serial)}"
    src = template.sub("<%= klass_name %>", klass_name)

    dir = File.join(Dir.tmpdir, "mcp_auth_optmarker_#{Process.pid}")
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
