require_relative "test_helper"

class StrictSanitizeTest < Minitest::Test
  def setup
    McpAuthorization.config.strict_schema = false
  end

  def teardown
    McpAuthorization.config.strict_schema = false
  end

  def sanitize(schema)
    McpAuthorization::RbsSchemaCompiler.send(:strict_sanitize, schema)
  end

  def test_strips_unsupported_numeric_constraints
    schema = { type: "integer", minimum: 1, maximum: 100, exclusiveMinimum: 0 }
    result = sanitize(schema)
    assert_equal({ type: "integer" }, result)
  end

  def test_strips_unsupported_string_constraints
    schema = { type: "string", minLength: 1, maxLength: 255 }
    result = sanitize(schema)
    assert_equal({ type: "string" }, result)
  end

  def test_strips_unsupported_array_constraints
    schema = { type: "array", items: { type: "string" }, maxItems: 10, uniqueItems: true }
    result = sanitize(schema)
    assert_equal({ type: "array", items: { type: "string" } }, result)
  end

  def test_keeps_minItems_0_and_1
    schema = { type: "array", items: { type: "string" }, minItems: 1 }
    result = sanitize(schema)
    assert_equal 1, result[:minItems]
  end

  def test_strips_minItems_above_1
    schema = { type: "array", items: { type: "string" }, minItems: 3 }
    result = sanitize(schema)
    refute result.key?(:minItems)
  end

  def test_preserves_supported_keywords
    schema = { type: "string", format: "email", pattern: "^.+@.+$", default: "a@b.com", description: "Email" }
    result = sanitize(schema)
    assert_equal "email", result[:format]
    assert_equal "^.+@.+$", result[:pattern]
    assert_equal "a@b.com", result[:default]
    assert_equal "Email", result[:description]
  end

  def test_strips_annotation_keywords
    schema = { type: "string", deprecated: true, readOnly: true, title: "Name", examples: ["foo"] }
    result = sanitize(schema)
    assert_equal({ type: "string" }, result)
  end

  def test_converts_oneOf_to_anyOf
    schema = { type: "object", oneOf: [{ type: "string" }, { type: "integer" }] }
    result = sanitize(schema)
    refute result.key?(:oneOf)
    assert_equal [{ type: "string" }, { type: "integer" }], result[:anyOf]
  end

  def test_adds_additionalProperties_false_to_objects
    schema = { type: "object", properties: { name: { type: "string" } } }
    result = sanitize(schema)
    assert_equal false, result[:additionalProperties]
  end

  def test_does_not_override_existing_additionalProperties
    schema = { type: "object", properties: { name: { type: "string" } }, additionalProperties: true }
    result = sanitize(schema)
    assert_equal true, result[:additionalProperties]
  end

  def test_recursively_sanitizes_properties
    schema = {
      type: "object",
      properties: {
        age: { type: "integer", minimum: 0, maximum: 150 },
        name: { type: "string", minLength: 1 }
      }
    }
    result = sanitize(schema)
    assert_equal({ type: "integer" }, result[:properties][:age])
    assert_equal({ type: "string" }, result[:properties][:name])
  end

  def test_recursively_sanitizes_defs
    schema = {
      type: "object",
      properties: {},
      "$defs": { addr: { type: "object", properties: { zip: { type: "string", minLength: 5 } } } }
    }
    result = sanitize(schema)
    addr = result[:"$defs"][:addr]
    assert_equal({ type: "string" }, addr[:properties][:zip])
    assert_equal false, addr[:additionalProperties]
  end

  def test_strips_dependentRequired
    schema = { type: "object", properties: { a: { type: "string" } }, dependentRequired: { a: ["b"] } }
    result = sanitize(schema)
    refute result.key?(:dependentRequired)
  end
end
