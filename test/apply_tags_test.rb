require_relative "test_helper"

# Tests that apply_tags produces correct JSON Schema keywords for each type.
# Each test name maps to the JSON Schema keyword being validated.
class ApplyTagsTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # --- String constraints -> minLength / maxLength ---

  def test_min_on_string_produces_minLength
    schema = C.send(:apply_tags, { type: "string" }, { min: 1 })
    assert_equal 1, schema[:minLength]
    refute schema.key?(:minimum), "must not set minimum on strings"
    refute schema.key?(:minItems), "must not set minItems on strings"
  end

  def test_max_on_string_produces_maxLength
    schema = C.send(:apply_tags, { type: "string" }, { max: 255 })
    assert_equal 255, schema[:maxLength]
    refute schema.key?(:maximum)
    refute schema.key?(:maxItems)
  end

  # --- Number constraints -> minimum / maximum ---

  def test_min_on_integer_produces_minimum
    schema = C.send(:apply_tags, { type: "integer" }, { min: 0 })
    assert_equal 0, schema[:minimum]
    refute schema.key?(:minLength)
    refute schema.key?(:minItems)
  end

  def test_max_on_integer_produces_maximum
    schema = C.send(:apply_tags, { type: "integer" }, { max: 100 })
    assert_equal 100, schema[:maximum]
    refute schema.key?(:maxLength)
  end

  def test_min_on_number_produces_minimum
    schema = C.send(:apply_tags, { type: "number" }, { min: 0.0 })
    assert_equal 0.0, schema[:minimum]
  end

  def test_max_on_number_produces_maximum
    schema = C.send(:apply_tags, { type: "number" }, { max: 1.0 })
    assert_equal 1.0, schema[:maximum]
  end

  # --- Array constraints -> minItems / maxItems / uniqueItems ---

  def test_min_on_array_produces_minItems
    schema = C.send(:apply_tags, { type: "array" }, { min: 1 })
    assert_equal 1, schema[:minItems]
    refute schema.key?(:minimum)
    refute schema.key?(:minLength)
  end

  def test_max_on_array_produces_maxItems
    schema = C.send(:apply_tags, { type: "array" }, { max: 10 })
    assert_equal 10, schema[:maxItems]
    refute schema.key?(:maximum)
    refute schema.key?(:maxLength)
  end

  def test_unique_produces_uniqueItems
    schema = C.send(:apply_tags, { type: "array" }, { unique: true })
    assert_equal true, schema[:uniqueItems]
  end

  # --- Numeric-only constraints ---

  def test_exclusiveMinimum
    schema = C.send(:apply_tags, { type: "integer" }, { exclusive_min: 0 })
    assert_equal 0, schema[:exclusiveMinimum]
  end

  def test_exclusiveMaximum
    schema = C.send(:apply_tags, { type: "number" }, { exclusive_max: 1.0 })
    assert_equal 1.0, schema[:exclusiveMaximum]
  end

  def test_multipleOf
    schema = C.send(:apply_tags, { type: "integer" }, { multiple_of: 5 })
    assert_equal 5, schema[:multipleOf]
  end

  # --- String-only constraints ---

  def test_pattern
    schema = C.send(:apply_tags, { type: "string" }, { pattern: "^app-\\d+$" })
    assert_equal "^app-\\d+$", schema[:pattern]
  end

  def test_format
    schema = C.send(:apply_tags, { type: "string" }, { format: "email" })
    assert_equal "email", schema[:format]
  end

  # --- Annotation keywords ---

  def test_title
    schema = C.send(:apply_tags, { type: "string" }, { title: "Email" })
    assert_equal "Email", schema[:title]
  end

  def test_description_from_desc
    schema = C.send(:apply_tags, { type: "string" }, { desc: "A user email" })
    assert_equal "A user email", schema[:description]
  end

  def test_examples
    schema = C.send(:apply_tags, { type: "string" }, { examples: ["foo", "bar"] })
    assert_equal ["foo", "bar"], schema[:examples]
  end

  def test_default_value
    schema = C.send(:apply_tags, { type: "string" }, { default: "pending" })
    assert_equal "pending", schema[:default]
  end

  def test_default_false_preserved
    schema = C.send(:apply_tags, { type: "boolean" }, { default: false })
    assert_equal false, schema[:default]
  end

  def test_default_nil_preserved
    schema = C.send(:apply_tags, { type: "string" }, { default: nil })
    assert_nil schema[:default]
    assert schema.key?(:default), "default key must be present even when nil"
  end

  def test_default_for_resolves_via_server_context
    ctx = StubContext.new([], defaults: { timezone: "America/Chicago" })
    schema = C.send(:apply_tags, { type: "string" }, { default_for: :timezone }, server_context: ctx)
    assert_equal "America/Chicago", schema[:default]
  end

  def test_default_for_nil_omits_default
    ctx = StubContext.new([], defaults: { timezone: nil })
    schema = C.send(:apply_tags, { type: "string" }, { default_for: :timezone }, server_context: ctx)
    refute schema.key?(:default), "nil from default_for should not set default"
  end

  def test_default_for_unknown_key_omits_default
    ctx = StubContext.new([], defaults: {})
    schema = C.send(:apply_tags, { type: "string" }, { default_for: :nonexistent }, server_context: ctx)
    refute schema.key?(:default)
  end

  def test_default_for_without_server_context_is_noop
    schema = C.send(:apply_tags, { type: "string" }, { default_for: :timezone })
    refute schema.key?(:default)
  end

  def test_static_default_still_works
    schema = C.send(:apply_tags, { type: "string" }, { default: "pending" })
    assert_equal "pending", schema[:default]
  end

  def test_deprecated
    schema = C.send(:apply_tags, { type: "string" }, { deprecated: true })
    assert_equal true, schema[:deprecated]
  end

  def test_readOnly
    schema = C.send(:apply_tags, { type: "string" }, { read_only: true })
    assert_equal true, schema[:readOnly]
  end

  def test_writeOnly
    schema = C.send(:apply_tags, { type: "string" }, { write_only: true })
    assert_equal true, schema[:writeOnly]
  end

  # --- Niche constraints ---

  def test_additionalProperties_false
    schema = C.send(:apply_tags, { type: "object" }, { closed: true })
    assert_equal false, schema[:additionalProperties]
  end

  def test_contentMediaType
    schema = C.send(:apply_tags, { type: "string" }, { media_type: "application/json" })
    assert_equal "application/json", schema[:contentMediaType]
  end

  def test_contentEncoding
    schema = C.send(:apply_tags, { type: "string" }, { encoding: "base64" })
    assert_equal "base64", schema[:contentEncoding]
  end

  # --- No spurious keys ---

  def test_empty_tags_adds_nothing
    schema = C.send(:apply_tags, { type: "string" }, {})
    assert_equal({ type: "string" }, schema)
  end

  def test_min_max_on_boolean_adds_nothing
    schema = C.send(:apply_tags, { type: "boolean" }, { min: 1, max: 10 })
    assert_equal({ type: "boolean" }, schema)
  end
end
