require_relative "test_helper"

# Tests that $defs / $ref optimization works correctly per JSON Schema spec.
class RefInjectionTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def test_no_refs_when_type_used_once
    error_schema = { type: "object", properties: { code: { type: "string" } } }
    type_map = { "error" => error_schema }

    schema = {
      type: "object",
      oneOf: [
        { type: "object", properties: { success: { type: "boolean", const: true } } },
        error_schema
      ]
    }

    result = C.send(:with_ref_injection, schema, type_map)
    refute result.key?(:"$defs"), "should not emit $defs for single-use type"
  end

  def test_refs_when_type_used_twice
    error_schema = { type: "object", properties: { code: { type: "string" }, message: { type: "string" } } }
    type_map = { "error" => error_schema }

    schema = {
      type: "object",
      properties: {
        primary_error: error_schema,
        secondary_error: error_schema
      }
    }

    result = C.send(:with_ref_injection, schema, type_map)
    assert result.key?(:"$defs"), "should emit $defs for multi-use type"
    assert_equal error_schema, result[:"$defs"]["error"]
    assert_equal "#/$defs/error", result[:properties][:primary_error][:"$ref"]
    assert_equal "#/$defs/error", result[:properties][:secondary_error][:"$ref"]
  end

  def test_trivial_schemas_not_deduped
    # { type: "string" } has size 1 — cheaper to inline than $defs + $ref
    type_map = { "name" => { type: "string" } }

    schema = {
      type: "object",
      properties: {
        first_name: { type: "string" },
        last_name: { type: "string" }
      }
    }

    result = C.send(:with_ref_injection, schema, type_map)
    refute result.key?(:"$defs"), "should not create $defs for trivial schemas"
  end

  def test_refs_in_oneOf
    shared = { type: "object", properties: { id: { type: "string" }, name: { type: "string" } } }
    type_map = { "person" => shared }

    schema = {
      type: "object",
      oneOf: [shared, shared]
    }

    result = C.send(:with_ref_injection, schema, type_map)
    assert result.key?(:"$defs")
    result[:oneOf].each do |variant|
      assert_equal "#/$defs/person", variant[:"$ref"]
    end
  end

  def test_refs_in_array_items
    item_schema = { type: "object", properties: { id: { type: "string" }, value: { type: "integer" } } }
    type_map = { "item" => item_schema }

    schema = {
      type: "object",
      properties: {
        items: { type: "array", items: item_schema },
        backup_item: item_schema
      }
    }

    result = C.send(:with_ref_injection, schema, type_map)
    assert result.key?(:"$defs")
    assert_equal "#/$defs/item", result[:properties][:items][:items][:"$ref"]
    assert_equal "#/$defs/item", result[:properties][:backup_item][:"$ref"]
  end

  def test_non_hash_schema_returned_as_is
    result = C.send(:with_ref_injection, nil, {})
    assert_nil result
  end

  def test_empty_type_map_returns_schema_unchanged
    schema = { type: "object", properties: { name: { type: "string" } } }
    result = C.send(:with_ref_injection, schema, {})
    assert_equal schema, result
  end

  def test_count_usages_counts_correctly
    shared = { type: "object", properties: { x: { type: "string" } } }
    type_schemas = { "shared" => shared }
    usage = Hash.new(0)

    schema = {
      type: "object",
      properties: { a: shared, b: shared, c: { type: "string" } }
    }

    C.send(:count_usages, schema, type_schemas, usage)
    assert_equal 2, usage["shared"]
  end

  def test_deep_replace_leaves_non_targets_alone
    shared = { type: "object", properties: { x: { type: "string" } } }
    other = { type: "object", properties: { y: { type: "integer" } } }

    targets = { "shared" => 2 }
    type_schemas = { "shared" => shared }

    schema = {
      type: "object",
      properties: { a: shared, b: other }
    }

    result = C.send(:deep_replace, schema, targets, type_schemas)
    assert_equal({ "$ref": "#/$defs/shared" }, result[:properties][:a])
    assert_equal other, result[:properties][:b]
  end
end
