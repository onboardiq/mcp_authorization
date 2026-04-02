require_relative "test_helper"
require "tempfile"

# Tests that shared .rbs file caching works correctly.
class SharedTypeCacheTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def setup
    C.reset_cache!
    @tmpfile = Tempfile.new(["test_type", ".rbs"])
    @tmpfile.write(<<~RBS)
      type status = "active"
                  | "closed"
    RBS
    @tmpfile.flush
  end

  def teardown
    @tmpfile.close
    @tmpfile.unlink
  end

  def test_parses_file_on_first_call
    result = C.send(:cached_parse_rbs_file, @tmpfile.path)
    assert result.key?("status")
    assert_equal "string", result["status"][:type]
    assert_equal %w[active closed], result["status"][:enum]
  end

  def test_returns_cached_result_on_second_call
    first = C.send(:cached_parse_rbs_file, @tmpfile.path)
    second = C.send(:cached_parse_rbs_file, @tmpfile.path)
    assert_same first, second, "should return the exact same object from cache"
  end

  def test_invalidates_when_mtime_changes
    first = C.send(:cached_parse_rbs_file, @tmpfile.path)

    # Rewrite with different content and bump mtime
    sleep 0.01 # ensure mtime differs
    @tmpfile.reopen(@tmpfile.path, "w")
    @tmpfile.write(<<~RBS)
      type status = "open"
                  | "closed"
                  | "archived"
    RBS
    @tmpfile.flush
    File.utime(Time.now + 1, Time.now + 1, @tmpfile.path)

    second = C.send(:cached_parse_rbs_file, @tmpfile.path)
    refute_same first, second, "should re-parse when mtime changes"
    assert_equal %w[open closed archived], second["status"][:enum]
  end

  def test_reset_cache_clears_shared_type_cache
    C.send(:cached_parse_rbs_file, @tmpfile.path)
    refute_empty C.shared_type_cache

    C.reset_cache!
    assert_empty C.shared_type_cache
  end

  def test_record_type_cached
    file = Tempfile.new(["record_type", ".rbs"])
    file.write(<<~RBS)
      type person = {
        name: String,
        age: Integer
      }
    RBS
    file.flush

    result = C.send(:cached_parse_rbs_file, file.path)
    assert result.key?("person")
    assert_equal "object", result["person"][:type]
    assert_equal({ type: "string" }, result["person"][:properties][:name])
    assert_equal({ type: "integer" }, result["person"][:properties][:age])
  ensure
    file.close
    file.unlink
  end
end
