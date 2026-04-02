require_relative "test_helper"

# Tests that RBS types produce correct JSON Schema structures.
class TypeResolutionTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def test_string
    assert_equal({ type: "string" }, schema("String"))
  end

  def test_integer
    assert_equal({ type: "integer" }, schema("Integer"))
  end

  def test_float
    assert_equal({ type: "number" }, schema("Float"))
  end

  def test_bool
    assert_equal({ type: "boolean" }, schema("bool"))
  end

  def test_true_literal
    assert_equal({ type: "boolean", const: true }, schema("true"))
  end

  def test_false_literal
    assert_equal({ type: "boolean", const: false }, schema("false"))
  end

  def test_array_of_strings
    expected = { type: "array", items: { type: "string" } }
    assert_equal expected, schema("Array[String]")
  end

  def test_array_of_integers
    expected = { type: "array", items: { type: "integer" } }
    assert_equal expected, schema("Array[Integer]")
  end

  def test_optional_strips_question_mark
    assert_equal({ type: "string" }, schema("String?"))
  end

  def test_inline_record
    result = schema("{ name: String, age: Integer }")
    assert_equal "object", result[:type]
    assert_equal({ type: "string" }, result[:properties][:name])
    assert_equal({ type: "integer" }, result[:properties][:age])
  end

  def test_string_literal_union
    result = schema('"pending" | "active" | "closed"')
    assert_equal "string", result[:type]
    assert_equal %w[pending active closed], result[:enum]
  end

  def test_type_union_produces_oneOf
    result = schema("String | Integer")
    assert result.key?(:oneOf)
    assert_equal 2, result[:oneOf].size
    assert_equal({ type: "string" }, result[:oneOf][0])
    assert_equal({ type: "integer" }, result[:oneOf][1])
  end

  def test_named_type_resolved_from_type_map
    type_map = { "status" => { type: "string", enum: %w[active closed] } }
    result = C.send(:rbs_type_to_json_schema, "status", type_map)
    assert_equal({ type: "string", enum: %w[active closed] }, result)
  end

  def test_unknown_type_falls_back_to_string
    assert_equal({ type: "string" }, schema("UnknownType"))
  end

  def test_nested_array_of_records
    result = schema("Array[{ id: String }]")
    assert_equal "array", result[:type]
    assert_equal "object", result[:items][:type]
    assert_equal({ type: "string" }, result[:items][:properties][:id])
  end

  private

  def schema(rbs_type, type_map = {})
    C.send(:rbs_type_to_json_schema, rbs_type, type_map)
  end
end
