require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

# Cross-file shared types: a `# @rbs import`ed shared .rbs file should be able to
# reference a type defined in *another* imported shared .rbs file, when the
# handler imports both. Each shared file is parsed in isolation, so references
# across files historically degraded to a fallback ({type:object}/string). This
# pins the desired behavior so reusable nested types (e.g. move_rule, templates)
# can live in their own files and be shared across many contracts.
class CrossFileSharedTypesTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler

  def setup
    @dir = Dir.mktmpdir("mcp_auth_xfile")
    @shared = File.join(@dir, "shared")
    FileUtils.mkdir_p(@shared)
    @prev_paths = McpAuthorization.config.shared_type_paths
    McpAuthorization.config.shared_type_paths = [@shared]
  end

  def teardown
    McpAuthorization.config.shared_type_paths = @prev_paths
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    C.reset_cache!
  end

  def write_shared(name, body)
    File.write(File.join(@shared, "#{name}.rbs"), body)
  end

  def load_handler(src)
    klass = "XFileHandler#{rand(1_000_000)}"
    path = File.join(@dir, "#{klass.downcase}.rb")
    File.write(path, src.gsub("<%= klass %>", klass))
    load path
    C.reset_cache!
    Object.const_get(klass)
  end

  def ctx
    o = Object.new
    def o.requires?(_) = true
    def o.feature?(_) = true
    def o.hidden?(_) = false
    def o.current_user = nil
    o
  end

  def resolve(node, schema)
    return node unless node.is_a?(Hash)
    ref = node[:"$ref"] || node["$ref"]
    return node unless ref
    name = ref.to_s.split("/").last
    (schema[:"$defs"] || {})[name.to_sym] || (schema[:"$defs"] || {})[name] || node
  end

  def test_shared_type_references_a_type_in_another_shared_file
    write_shared("inner", <<~RBS)
      type inner = {
        a: String,
        b: Integer
      }
    RBS
    write_shared("outer", <<~RBS)
      type outer = {
        label: String,
        nested: inner,
        list: Array[inner]
      }
    RBS

    handler = load_handler(<<~SRC)
      # @rbs import inner
      # @rbs import outer
      class <%= klass %>
        #: (payload: outer) -> untyped
        def call(**); end
      end
    SRC

    schema = C.compile_input(handler, server_context: ctx)
    outer = resolve(schema.dig(:properties, :payload), schema)

    assert_equal %i[label list nested].sort, outer[:properties].keys.sort,
      "outer should resolve to its full record, not a fallback"

    nested = resolve(outer.dig(:properties, :nested), schema)
    assert_equal %i[a b].sort, nested[:properties].keys.sort,
      "cross-file reference outer.nested -> inner (other file) must resolve"

    item = resolve(outer.dig(:properties, :list, :items), schema)
    assert_equal %i[a b].sort, item[:properties].keys.sort,
      "cross-file reference inside Array[inner] must resolve"
  end
end
