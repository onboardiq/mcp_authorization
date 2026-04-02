require_relative "test_helper"

class ExtractTagsTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  # --- Existing tags ---

  def test_requires
    type, tags = C.send(:extract_tags, "String @requires(:admin)")
    assert_equal "String", type
    assert_equal :admin, tags[:requires]
  end

  def test_depends_on
    type, tags = C.send(:extract_tags, "String? @depends_on(:workflow_id)")
    assert_equal "String?", type
    assert_equal "workflow_id", tags[:depends_on]
  end

  def test_min_integer
    type, tags = C.send(:extract_tags, "Integer @min(1)")
    assert_equal "Integer", type
    assert_equal 1, tags[:min]
  end

  def test_min_float
    type, tags = C.send(:extract_tags, "Float @min(0.5)")
    assert_equal "Float", type
    assert_equal 0.5, tags[:min]
  end

  def test_max_integer
    type, tags = C.send(:extract_tags, "Integer @max(100)")
    assert_equal "Integer", type
    assert_equal 100, tags[:max]
  end

  def test_pattern
    type, tags = C.send(:extract_tags, 'String @pattern(^app-\d+$)')
    assert_equal "String", type
    assert_equal '^app-\d+$', tags[:pattern]
  end

  def test_format
    type, tags = C.send(:extract_tags, "String @format(email)")
    assert_equal "String", type
    assert_equal "email", tags[:format]
  end

  def test_default_boolean
    _, tags = C.send(:extract_tags, "bool @default(false)")
    assert_equal false, tags[:default]
  end

  def test_default_integer
    _, tags = C.send(:extract_tags, "Integer @default(42)")
    assert_equal 42, tags[:default]
  end

  def test_default_string
    _, tags = C.send(:extract_tags, 'String @default("pending")')
    assert_equal "pending", tags[:default]
  end

  def test_default_nil
    _, tags = C.send(:extract_tags, "String? @default(nil)")
    assert_nil tags[:default]
  end

  def test_default_for
    type, tags = C.send(:extract_tags, "String @default_for(:timezone)")
    assert_equal "String", type
    assert_equal :timezone, tags[:default_for]
  end

  def test_desc
    _, tags = C.send(:extract_tags, "String @desc(Use fetch_latest_applicant to find this)")
    assert_equal "Use fetch_latest_applicant to find this", tags[:desc]
  end

  # --- Numeric constraints ---

  def test_exclusive_min_integer
    type, tags = C.send(:extract_tags, "Integer @exclusive_min(0)")
    assert_equal "Integer", type
    assert_equal 0, tags[:exclusive_min]
  end

  def test_exclusive_min_float
    _, tags = C.send(:extract_tags, "Float @exclusive_min(0.0)")
    assert_equal 0.0, tags[:exclusive_min]
  end

  def test_exclusive_max_integer
    _, tags = C.send(:extract_tags, "Integer @exclusive_max(100)")
    assert_equal 100, tags[:exclusive_max]
  end

  def test_exclusive_max_float
    _, tags = C.send(:extract_tags, "Float @exclusive_max(1.0)")
    assert_equal 1.0, tags[:exclusive_max]
  end

  def test_multiple_of_integer
    _, tags = C.send(:extract_tags, "Integer @multiple_of(5)")
    assert_equal 5, tags[:multiple_of]
  end

  def test_multiple_of_float
    _, tags = C.send(:extract_tags, "Float @multiple_of(0.01)")
    assert_equal 0.01, tags[:multiple_of]
  end

  # --- Array constraints ---

  def test_unique
    _, tags = C.send(:extract_tags, "Array[String] @unique()")
    assert_equal true, tags[:unique]
  end

  # --- Annotation keywords ---

  def test_title
    _, tags = C.send(:extract_tags, "String @title(User email address)")
    assert_equal "User email address", tags[:title]
  end

  def test_single_example
    _, tags = C.send(:extract_tags, "String @example(hello)")
    assert_equal ["hello"], tags[:examples]
  end

  def test_multiple_examples
    _, tags = C.send(:extract_tags, "String @example(world) @example(hello)")
    assert_includes tags[:examples], "hello"
    assert_includes tags[:examples], "world"
    assert_equal 2, tags[:examples].size
  end

  def test_example_numeric
    _, tags = C.send(:extract_tags, "Integer @example(42)")
    assert_equal [42], tags[:examples]
  end

  def test_deprecated
    _, tags = C.send(:extract_tags, "String @deprecated()")
    assert_equal true, tags[:deprecated]
  end

  def test_read_only
    _, tags = C.send(:extract_tags, "String @read_only()")
    assert_equal true, tags[:read_only]
  end

  def test_write_only
    _, tags = C.send(:extract_tags, "String @write_only()")
    assert_equal true, tags[:write_only]
  end

  # --- Niche constraints ---

  def test_closed
    _, tags = C.send(:extract_tags, "String @closed()")
    assert_equal true, tags[:closed]
  end

  def test_strict_aliases_to_closed
    _, tags = C.send(:extract_tags, "String @strict()")
    assert_equal true, tags[:closed]
  end

  def test_media_type
    _, tags = C.send(:extract_tags, "String @media_type(application/json)")
    assert_equal "application/json", tags[:media_type]
  end

  def test_encoding
    _, tags = C.send(:extract_tags, "String @encoding(base64)")
    assert_equal "base64", tags[:encoding]
  end

  # --- Compound tags ---

  def test_multiple_tags_extracted
    type, tags = C.send(:extract_tags, "String @min(1) @max(100) @format(email)")
    assert_equal "String", type
    assert_equal 1, tags[:min]
    assert_equal 100, tags[:max]
    assert_equal "email", tags[:format]
  end

  def test_no_tags
    type, tags = C.send(:extract_tags, "String")
    assert_equal "String", type
    assert_empty tags
  end
end
