require_relative "test_helper"
require "json"
require "json_schemer"

# RBS nil-able types (`T?`, `T | nil`) compile to schemas that accept null,
# checked with json_schemer — the validator the MCP gem runs on tool output.
# An optional key (`?key: T`) is a separate axis: it may be omitted, but a
# present value must still be a T.
class NullableTypeTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def test_nullable_scalar_accepts_null_and_keeps_its_constraints
    schema = record("{ note: String? @min(2) @format(email), count: Integer? }")

    assert_valid schema, { note: nil, count: nil }
    assert_valid schema, { note: "a@b.co", count: 3 }
    refute_valid schema, { note: 1, count: nil }
    refute_valid schema, { note: "a", count: nil }
    refute_valid schema, { count: nil } # T? alone still requires the key
  end

  def test_nullable_record_and_alias_accept_null
    type_map = { "owner_ref" => { type: "object", properties: { id: { type: "string" } }, required: ["id"] } }
    schema = record("{ owner: owner_ref?, inline: { id: String }?, meta: Hash[Symbol, untyped]? }", type_map)

    assert_valid schema, { owner: nil, inline: nil, meta: nil }
    assert_valid schema, { owner: { id: "u1" }, inline: { id: "i1" }, meta: { any: 1 } }
    refute_valid schema, { owner: "u1", inline: nil, meta: nil }
    refute_valid schema, { owner: {}, inline: nil, meta: nil }
  end

  def test_union_with_nil_matches_the_optional_form
    schema = record("{ note: String | nil, kind: \"a\" | \"b\" | nil }")

    assert_equal({ type: %w[string null] }, schema[:properties][:note])
    assert_valid schema, { note: "text", kind: "a" }
    assert_valid schema, { note: nil, kind: nil }
    refute_valid schema, { note: 1, kind: nil }
    refute_valid schema, { note: nil, kind: "c" }
  end

  def test_optional_key_may_be_omitted_and_only_a_nilable_type_takes_null
    schema = record("{ ?plain: String, ?both: String? }")

    assert_valid schema, {}
    assert_valid schema, { plain: "x", both: nil }
    refute_valid schema, { plain: nil }
    assert_nil schema[:required]
  end

  def test_projection_still_drops_undeclared_keys_inside_a_nullable_object
    schema = record("{ owner: { id: String }? }")

    assert_equal({ owner: { id: "u1" } }, C.send(:project_against_schema, { owner: { id: "u1", secret: "x" } }, schema, {}))
    assert_equal({ owner: nil }, C.send(:project_against_schema, { owner: nil }, schema, {}))
  end

  # The non-null branch of a nil-able union is a oneOf with no type of its
  # own; projection must still pick a member rather than pass the value through.
  def test_projection_still_drops_undeclared_keys_inside_a_nullable_union
    ["{ id: String } | { name: String } | nil", "({ id: String } | { name: String })?"].each do |type|
      schema = record("{ owner: #{type} }")

      assert_equal({ owner: { id: "u1" } }, C.send(:project_against_schema, { owner: { id: "u1", secret: "x" } }, schema, {}), type)
      assert_equal({ owner: nil }, C.send(:project_against_schema, { owner: nil }, schema, {}), type)
    end
  end

  def test_closed_applies_to_the_object_inside_a_nullable_wrapper
    type_map = { "meta_t" => { type: "object", properties: { id: { type: "string" } } } }
    schema = record("{ meta: meta_t? @closed() }", type_map)

    assert_valid schema, { meta: { id: "a" } }
    assert_valid schema, { meta: nil }
    refute_valid schema, { meta: { id: "a", extra: 1 } }
    refute type_map["meta_t"].key?(:additionalProperties), "@closed must not mutate the shared type_map entry"
  end

  # The facade parses a JSON-string argument only when the target param is an
  # object or array; a nil-able object param must still read as one.
  def test_primary_type_sees_through_the_null_branch
    assert_equal "object", C.send(:primary_type, C.send(:rbs_type_to_json_schema, "Hash[Symbol, untyped]?"))
    assert_equal "array", C.send(:primary_type, C.send(:rbs_type_to_json_schema, "Array[String] | nil"))
    assert_equal "string", C.send(:primary_type, C.send(:rbs_type_to_json_schema, "String?"))
  end

  private

  def record(body, type_map = {})
    C.send(:compile_tagged_record, body, type_map, nil)
  end

  def errors(schema, value)
    JSONSchemer.schema(JSON.parse(JSON.generate(schema))).validate(JSON.parse(JSON.generate(value))).to_a
  end

  def assert_valid(schema, value)
    errs = errors(schema, value)
    assert_empty errs, "expected #{value.inspect} to validate, got: #{errs.map { |e| e["error"] }.join("; ")}"
  end

  def refute_valid(schema, value)
    refute_empty errors(schema, value), "expected #{value.inspect} to be rejected"
  end
end
