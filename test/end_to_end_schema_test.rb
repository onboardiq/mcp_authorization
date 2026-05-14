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

  # --- Generic predicate filtering (record) ---

  def test_record_excludes_feature_gated_field
    ctx = StubContext.new([], features: [])
    schema = C.send(:compile_tagged_record, "{ name: String, tier: String @feature(:premium) }", {}, ctx)
    assert schema[:properties].key?(:name)
    refute schema[:properties].key?(:tier)
  end

  def test_record_includes_feature_gated_field_when_enabled
    ctx = StubContext.new([], features: ["premium"])
    schema = C.send(:compile_tagged_record, "{ name: String, tier: String @feature(:premium) }", {}, ctx)
    assert schema[:properties].key?(:name)
    assert schema[:properties].key?(:tier)
  end

  def test_record_requires_backwards_compat_via_predicate
    ctx = StubContext.new([], features: [])
    schema = C.send(:compile_tagged_record, "{ name: String, secret: String @requires(:admin) }", {}, ctx)
    assert schema[:properties].key?(:name)
    refute schema[:properties].key?(:secret)
  end

  def test_record_requires_passes_via_predicate
    ctx = StubContext.new([:admin])
    schema = C.send(:compile_tagged_record, "{ name: String, secret: String @requires(:admin) }", {}, ctx)
    assert schema[:properties].key?(:name)
    assert schema[:properties].key?(:secret)
  end

  def test_combined_requires_and_feature_both_must_pass
    ctx = StubContext.new([:admin], features: [])
    schema = C.send(:compile_tagged_record, "{ force: bool @requires(:admin) @feature(:bulk_ops) }", {}, ctx)
    refute schema[:properties].key?(:force), "should be excluded — feature not enabled"
  end

  def test_combined_requires_and_feature_both_pass
    ctx = StubContext.new([:admin], features: ["bulk_ops"])
    schema = C.send(:compile_tagged_record, "{ force: bool @requires(:admin) @feature(:bulk_ops) }", {}, ctx)
    assert schema[:properties].key?(:force)
  end

  def test_unknown_predicate_skipped_when_context_lacks_method
    ctx = StubContext.new([])
    schema = C.send(:compile_tagged_record, "{ name: String, x: String @tier(:enterprise) }", {}, ctx)
    # StubContext doesn't have tier?, so the predicate is skipped (permissive)
    assert schema[:properties].key?(:x)
  end

  # --- Generic predicate filtering (union) ---

  def test_union_excludes_feature_gated_variant
    ctx = StubContext.new([], features: [])
    type_map = { "basic" => { type: "object", properties: { name: { type: "string" } } },
                 "premium_detail" => { type: "object", properties: { tier: { type: "string" } } } }
    schema = C.send(:compile_tagged_union, "basic | premium_detail @feature(:premium)", type_map, ctx)
    # Only basic remains — returned directly without oneOf wrapper
    assert_equal "object", schema[:type]
    assert schema[:properties].key?(:name)
    refute schema.key?(:oneOf)
  end

  def test_union_includes_feature_gated_variant_when_enabled
    ctx = StubContext.new([], features: ["premium"])
    type_map = { "basic" => { type: "object", properties: { name: { type: "string" } } },
                 "premium_detail" => { type: "object", properties: { tier: { type: "string" } } } }
    schema = C.send(:compile_tagged_union, "basic | premium_detail @feature(:premium)", type_map, ctx)
    assert schema.key?(:oneOf)
    assert_equal 2, schema[:oneOf].size
  end

  # --- Custom predicate (not requires/feature) ---

  def test_custom_predicate_excludes_field
    ctx = StubContextWithTier.new([], tier: nil)
    schema = C.send(:compile_tagged_record, "{ name: String, x: String @tier(:enterprise) }", {}, ctx)
    refute schema[:properties].key?(:x)
  end

  def test_custom_predicate_includes_field
    ctx = StubContextWithTier.new([], tier: "enterprise")
    schema = C.send(:compile_tagged_record, "{ name: String, x: String @tier(:enterprise) }", {}, ctx)
    assert schema[:properties].key?(:x)
  end

  # --- @requires backward compat (OpenStruct without requires?) ---

  def test_requires_falls_back_to_current_user_can
    # Simulate old-style server_context (OpenStruct, no requires? method)
    user = StubUser.new([:admin])
    ctx = OpenStruct.new(current_user: user)
    schema = C.send(:compile_tagged_record, "{ name: String, secret: String @requires(:admin) }", {}, ctx)
    assert schema[:properties].key?(:secret), "should fall back to current_user.can?"
  end

  def test_requires_fallback_excludes_when_no_permission
    user = StubUser.new([])
    ctx = OpenStruct.new(current_user: user)
    schema = C.send(:compile_tagged_record, "{ name: String, secret: String @requires(:admin) }", {}, ctx)
    refute schema[:properties].key?(:secret), "should exclude — user lacks :admin"
  end

  # --- Error isolation ---

  def test_predicate_error_does_not_crash
    ctx = StubContextWithBrokenPredicate.new
    # broken? raises RuntimeError, but field should still be included (fail-open)
    schema = C.send(:compile_tagged_record, "{ name: String, x: String @broken(:anything) }", {}, ctx)
    assert schema[:properties].key?(:x), "should fail-open when predicate raises"
  end

  private

  # Simulate the full pipeline for a single field type annotation.
  def compile_field(type_annotation, type_map = {}, server_context: nil)
    type_str, tags = C.send(:extract_tags, type_annotation)
    schema = C.send(:rbs_type_to_json_schema, type_str, type_map)
    C.send(:apply_tags, schema, tags, server_context: server_context)
  end
end
