require_relative "test_helper"

# End-to-end tests: RBS annotation string → complete JSON Schema output.
# Verifies the full pipeline (extract_tags + type resolution + apply_tags)
# produces schemas that conform to JSON Schema 2020-12 keywords.
class EndToEndSchemaTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # --- String with full constraints ---

  def test_string_with_length_and_format
    schema = compile_field("String @min(1) @max(100) @format(email)")
    assert_equal "string", schema[:type]
    assert_equal 1, schema[:minLength]
    assert_equal 100, schema[:maxLength]
    assert_equal "email", schema[:format]
    refute schema.key?(:minimum), "string must not have minimum"
  end

  def test_string_with_pattern_and_desc
    schema = compile_field('String @pattern(^[A-Z]{2}\d+$) @desc(ISO code)')
    assert_equal "^[A-Z]{2}\\d+$", schema[:pattern]
    assert_equal "ISO code", schema[:description]
  end

  # --- Integer with full constraints ---

  def test_integer_with_range_and_step
    schema = compile_field("Integer @min(0) @max(100) @multiple_of(5)")
    assert_equal "integer", schema[:type]
    assert_equal 0, schema[:minimum]
    assert_equal 100, schema[:maximum]
    assert_equal 5, schema[:multipleOf]
    refute schema.key?(:minLength), "integer must not have minLength"
  end

  def test_integer_with_exclusive_bounds
    schema = compile_field("Integer @exclusive_min(0) @exclusive_max(100)")
    assert_equal 0, schema[:exclusiveMinimum]
    assert_equal 100, schema[:exclusiveMaximum]
  end

  # --- Float with constraints ---

  def test_float_with_exclusive_range
    schema = compile_field("Float @exclusive_min(0.0) @exclusive_max(1.0)")
    assert_equal "number", schema[:type]
    assert_equal 0.0, schema[:exclusiveMinimum]
    assert_equal 1.0, schema[:exclusiveMaximum]
  end

  # --- Array with constraints ---

  def test_array_with_items_and_constraints
    schema = compile_field("Array[String] @min(1) @max(10) @unique()")
    assert_equal "array", schema[:type]
    assert_equal({ type: "string" }, schema[:items])
    assert_equal 1, schema[:minItems]
    assert_equal 10, schema[:maxItems]
    assert_equal true, schema[:uniqueItems]
    refute schema.key?(:minimum), "array must not have minimum"
    refute schema.key?(:minLength), "array must not have minLength"
  end

  # --- Annotation keywords ---

  def test_field_with_all_annotations
    schema = compile_field("String @title(Email) @desc(User email) @default(user@example.com) @example(a@b.com) @deprecated()")
    assert_equal "Email", schema[:title]
    assert_equal "User email", schema[:description]
    assert_equal "user@example.com", schema[:default]
    assert_equal ["a@b.com"], schema[:examples]
    assert_equal true, schema[:deprecated]
  end

  def test_read_only_field
    schema = compile_field("String @read_only()")
    assert_equal true, schema[:readOnly]
  end

  def test_write_only_field
    schema = compile_field("String @write_only()")
    assert_equal true, schema[:writeOnly]
  end

  # --- Niche constraints ---

  def test_closed_object
    # @closed applies to a record field that resolves to an object
    schema = C.send(:apply_tags, { type: "object", properties: {} }, { closed: true })
    assert_equal false, schema[:additionalProperties]
  end

  def test_content_media_type_and_encoding
    schema = compile_field("String @media_type(application/json) @encoding(base64)")
    assert_equal "application/json", schema[:contentMediaType]
    assert_equal "base64", schema[:contentEncoding]
  end

  # --- Record parsing with constraints ---

  def test_record_fields_with_mixed_constraints
    record = "{ name: String @min(1) @max(50), age: Integer @min(0) @max(150), email: String @format(email) }"
    schema = C.send(:parse_record_type, record)

    assert_equal "object", schema[:type]
    assert_equal 1, schema[:properties][:name][:minLength]
    assert_equal 50, schema[:properties][:name][:maxLength]
    assert_equal 0, schema[:properties][:age][:minimum]
    assert_equal 150, schema[:properties][:age][:maximum]
    assert_equal "email", schema[:properties][:email][:format]
  end

  # --- Default values ---

  def test_default_false_not_dropped
    schema = compile_field("bool @default(false)")
    assert_equal false, schema[:default]
    assert schema.key?(:default)
  end

  def test_default_zero_not_dropped
    schema = compile_field("Integer @default(0)")
    assert_equal 0, schema[:default]
    assert schema.key?(:default)
  end

  def test_default_nil_preserved
    schema = compile_field("String? @default(nil)")
    assert_nil schema[:default]
    assert schema.key?(:default)
  end

  # --- Dynamic defaults via @default_for ---

  def test_default_for_resolves_from_user
    ctx = StubContext.new([], defaults: { timezone: "America/Chicago" })
    schema = compile_field("String @default_for(:timezone)", {}, server_context: ctx)
    assert_equal "string", schema[:type]
    assert_equal "America/Chicago", schema[:default]
  end

  def test_default_for_with_other_constraints
    ctx = StubContext.new([], defaults: { locale: "en-US" })
    schema = compile_field("String @min(2) @max(10) @default_for(:locale)", {}, server_context: ctx)
    assert_equal 2, schema[:minLength]
    assert_equal 10, schema[:maxLength]
    assert_equal "en-US", schema[:default]
  end

  private

  # Simulate the full pipeline for a single field type annotation.
  def compile_field(type_annotation, type_map = {}, server_context: nil)
    type_str, tags = C.send(:extract_tags, type_annotation)
    schema = C.send(:rbs_type_to_json_schema, type_str, type_map)
    C.send(:apply_tags, schema, tags, server_context: server_context)
  end
end
