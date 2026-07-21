require_relative "test_helper"
require_relative "../lib/mcp_authorization/facade_builder"
require_relative "../lib/mcp_authorization/cache"
require "tmpdir"
require "fileutils"
require "json"

# Tests for declarative tool grouping (issue #30): a faceted domain presents
# grouped facade tools with routing-only descriptions and deferred per-tool
# schemas, and dispatches facade calls through the real tool call path.
#
# Reuses StubContext/StubUser and the real ToolRegistry from test_helper —
# does NOT redefine shared constants (see keep-tests-shareable). Every test
# uses a per-test-unique domain so registered anonymous tool classes never
# leak into another test's grouping.
class FacadeTest < Minitest::Test
  C = McpAuthorization::RbsSchemaCompiler
  FB = McpAuthorization::FacadeBuilder

  LIST_HANDLER = <<~RUBY
    class FacadeListWidgetsHandler
      # @rbs type result = {
      #   widgets: Array[String]
      # }

      # @rbs type output = result

      def initialize(server_context:)
        @ctx = server_context
      end

      def description
        "List widgets in the system.\nSecond line is not part of the one-liner."
      end

      #: (?status: String) -> Hash[Symbol, untyped]
      def call(status: "all")
        { widgets: ["w1-\#{status}"] }
      end
    end
  RUBY

  UPDATE_HANDLER = <<~RUBY
    class FacadeUpdateWidgetHandler
      # @rbs type meta = {
      #   note: String
      # }

      # @rbs type result = {
      #   id: String,
      #   note: String,
      #   forced: bool
      # }

      # @rbs type output = result

      def initialize(server_context:)
        @ctx = server_context
      end

      def description
        "Update a widget."
      end

      #: (id: String, meta: meta, ?force: bool @requires(:admin)) -> Hash[Symbol, untyped]
      def call(id:, meta: {}, force: false)
        note = meta[:note] || meta["note"] || ""
        { id: id, note: note, forced: force }
      end
    end
  RUBY

  BILLING_HANDLER = <<~RUBY
    class FacadeBillingHandler
      # @rbs type result = {
      #   ok: bool
      # }

      # @rbs type output = result

      def initialize(server_context:)
        @ctx = server_context
      end

      def description
        "Manage billing profiles."
      end

      #: (invoice: String) -> Hash[Symbol, untyped]
      def call(invoice:)
        { ok: true }
      end
    end
  RUBY

  HANDLER_CONSTANTS = %i[FacadeListWidgetsHandler FacadeUpdateWidgetHandler FacadeBillingHandler]

  def setup
    @tmpdir = Dir.mktmpdir
    C.reset_cache!
    load_handlers
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    HANDLER_CONSTANTS.each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
    McpAuthorization.config.faceted_domains.clear
    McpAuthorization.config.category_summaries.clear
    McpAuthorization.config.strict_schema = false
    C.reset_cache!
  end

  def load_handlers
    { "facade_list_widgets_handler.rb" => LIST_HANDLER,
      "facade_update_widget_handler.rb" => UPDATE_HANDLER,
      "facade_billing_handler.rb" => BILLING_HANDLER }.each do |filename, fixture|
      path = File.join(@tmpdir, filename)
      File.write(path, fixture)
      load path
    end
  end

  # Unique domain per test so the shared registry never crosses tests.
  def domain
    @domain ||= "facade_#{name}"
  end

  # Standard fixture: two widget tools (different permissions) + one billing
  # tool, all in this test's domain. Tool names are domain-suffixed so
  # find-by-name lookups stay unambiguous in the shared registry.
  def define_standard_tools
    d = domain
    list_h = FacadeListWidgetsHandler
    update_h = FacadeUpdateWidgetHandler
    billing_h = FacadeBillingHandler

    @list_tool = Class.new(McpAuthorization::Tool) do
      tool_name "list_widgets_#{d}"
      tags d
      authorization :view_widgets
      category :widgets
      dynamic_contract list_h
    end
    @update_tool = Class.new(McpAuthorization::Tool) do
      tool_name "update_widget_#{d}"
      tags d
      authorization :manage_widgets
      category :widgets
      dynamic_contract update_h
    end
    @billing_tool = Class.new(McpAuthorization::Tool) do
      tool_name "billing_#{d}"
      tags d
      authorization :billing
      category :billing
      dynamic_contract billing_h
    end
  end

  def facet!(**opts)
    McpAuthorization.config.facet_domain(domain, group_by: :category, **opts)
  end

  def full_ctx
    StubContext.new([:view_widgets, :manage_widgets, :billing, :admin])
  end

  # --------------------------------------------------------------------------
  # category DSL
  # --------------------------------------------------------------------------

  def test_category_dsl_records_category_and_summary
    tool = Class.new(McpAuthorization::Tool) do
      category :orders, summary: "Order tools."
    end
    assert_equal :orders, tool._category
    assert_equal "Order tools.", tool._category_summary
  end

  def test_facet_domain_rejects_unknown_strategy_and_mode
    assert_raises(ArgumentError) do
      McpAuthorization.config.facet_domain(domain, group_by: :category, schema_strategy: :bogus)
    end
    assert_raises(ArgumentError) do
      McpAuthorization.config.facet_domain(domain, group_by: :category, uncategorized: :bogus)
    end
  end

  # --------------------------------------------------------------------------
  # Grouping + RBAC-filtered advertisement
  # --------------------------------------------------------------------------

  def test_one_facade_per_nonempty_category
    define_standard_tools
    facet!
    facades = FB.facades_for(domain: domain, server_context: full_ctx)
    assert_equal ["billing_tools", "widgets_tools"], facades.map(&:tool_name).sort
  end

  def test_group_with_no_permitted_tools_is_hidden
    define_standard_tools
    facet!
    ctx = StubContext.new([:view_widgets]) # no :billing
    facades = FB.facades_for(domain: domain, server_context: ctx)
    assert_equal ["widgets_tools"], facades.map(&:tool_name),
      "a facade must not exist for a group with zero permitted tools (no empty enum)"
  end

  def test_facade_advertises_only_permitted_tools
    define_standard_tools
    facet!
    ctx = StubContext.new([:view_widgets]) # not :manage_widgets
    facade = FB.facades_for(domain: domain, server_context: ctx).first

    schema = facade.input_schema
    enum = schema[:properties][:tool_name][:enum]
    assert_equal ["list_widgets_#{domain}"], enum
    refute_includes facade.description, "update_widget_#{domain}",
      "an unpermitted tool must not appear in the facade description"
  end

  def test_non_faceted_domain_returns_no_facades
    define_standard_tools
    assert_empty FB.facades_for(domain: domain, server_context: full_ctx)
  end

  def test_facade_for_finds_single_group_by_name
    define_standard_tools
    facet!
    facade = FB.facade_for(domain: domain, name: "billing_tools", server_context: full_ctx)
    assert_equal "billing_tools", facade.tool_name
    assert_nil FB.facade_for(domain: domain, name: "nonexistent_tools", server_context: full_ctx)
  end

  # --------------------------------------------------------------------------
  # Description: summary + one-liners, no schemas
  # --------------------------------------------------------------------------

  def test_description_uses_central_summary_and_one_liners
    define_standard_tools
    facet!
    McpAuthorization.config.categories do
      summary :widgets, "Inspect and modify widgets."
    end

    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: full_ctx)
    assert_includes facade.description, "Inspect and modify widgets."
    assert_includes facade.description, "- list_widgets_#{domain} — List widgets in the system."
    refute_includes facade.description, "Second line",
      "only the first line of a tool description is used as its one-liner"
  end

  def test_tool_level_summary_used_when_central_registry_lacks_entry
    d = domain
    billing_h = FacadeBillingHandler
    Class.new(McpAuthorization::Tool) do
      tool_name "billing_#{d}"
      tags d
      category :billing, summary: "Colocated billing summary."
      dynamic_contract billing_h
    end
    facet!
    facade = FB.facade_for(domain: domain, name: "billing_tools", server_context: full_ctx)
    assert_includes facade.description, "Colocated billing summary."
  end

  def test_central_summary_wins_over_tool_level_summary
    d = domain
    billing_h = FacadeBillingHandler
    Class.new(McpAuthorization::Tool) do
      tool_name "billing_#{d}"
      tags d
      category :billing, summary: "Colocated billing summary."
      dynamic_contract billing_h
    end
    facet!
    McpAuthorization.config.categories do
      summary :billing, "Central billing summary."
    end
    facade = FB.facade_for(domain: domain, name: "billing_tools", server_context: full_ctx)
    assert_includes facade.description, "Central billing summary."
    refute_includes facade.description, "Colocated billing summary."
  end

  # --------------------------------------------------------------------------
  # Schema strategies
  # --------------------------------------------------------------------------

  def test_vendor_extension_schema_shape
    define_standard_tools
    facet! # default strategy
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: full_ctx)
    schema = facade.input_schema

    assert_equal "object", schema[:type]
    assert_equal %w[tool_name arguments], schema[:required]
    assert_equal ["list_widgets_#{domain}", "update_widget_#{domain}"].sort,
                 schema[:properties][:tool_name][:enum].sort
    # inputSchema itself stays standards-clean — no non-standard key that a
    # strict Zod client or strict-mode LLM tool-calling would reject.
    refute schema.key?(:"x-tool-input-schemas"),
      "per-tool schemas must not live inside inputSchema"

    # ...they ship on the facade's _meta instead.
    per_tool = facade.meta["tool-input-schemas"]
    update_schema = per_tool["update_widget_#{domain}"]
    assert update_schema[:properties].key?(:id), "per-tool schema must carry real argument shapes"
    assert update_schema[:properties].key?(:force),
      "admin caller sees the @requires(:admin) field in the deferred schema"
  end

  def test_vendor_extension_filters_gated_fields_per_caller
    define_standard_tools
    facet!
    ctx = StubContext.new([:view_widgets, :manage_widgets]) # not :admin
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    update_schema = facade.meta["tool-input-schemas"]["update_widget_#{domain}"]
    refute update_schema[:properties].key?(:force),
      "@requires(:admin) field must be filtered out of the deferred schema for non-admins"
  end

  def test_facet_domain_rejects_unknown_schema_strategy
    # :discriminated_union / :auto were removed — a top-level combinator is
    # invalid in an LLM tool input_schema, so only the flat strategies remain.
    assert_raises(ArgumentError) { facet!(schema_strategy: :discriminated_union) }
    assert_raises(ArgumentError) { facet!(schema_strategy: :auto) }
  end

  def test_no_facade_strategy_emits_a_top_level_combinator
    define_standard_tools
    McpAuthorization::Configuration::SCHEMA_STRATEGIES.each do |strategy|
      McpAuthorization.config.instance_variable_set(:@faceted_domains, {})
      facet!(schema_strategy: strategy)
      schema = FB.facade_for(domain: domain, name: "widgets_tools", server_context: full_ctx).input_schema
      assert_equal "object", schema[:type], "#{strategy}: root must be an object"
      %i[oneOf anyOf allOf].each do |combinator|
        refute schema.key?(combinator), "#{strategy}: inputSchema must not have a top-level #{combinator}"
      end
    end
  end

  def test_lazy_schema_carries_names_only
    define_standard_tools
    facet!(schema_strategy: :lazy)
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: full_ctx)
    schema = facade.input_schema

    assert_equal ["list_widgets_#{domain}", "update_widget_#{domain}"].sort,
                 schema[:properties][:tool_name][:enum].sort
    refute schema.key?(:"x-tool-input-schemas")
    refute schema.key?(:oneOf)
    assert_nil facade.meta, "lazy strategy carries no per-tool schemas anywhere"
  end

  # --------------------------------------------------------------------------
  # Uncategorized tools
  # --------------------------------------------------------------------------

  def test_uncategorized_tool_falls_back_to_uncategorized_group
    d = domain
    list_h = FacadeListWidgetsHandler
    Class.new(McpAuthorization::Tool) do
      tool_name "stray_#{d}"
      tags d
      dynamic_contract list_h
    end
    facet!
    facades = FB.facades_for(domain: domain, server_context: full_ctx)
    assert_equal ["uncategorized_tools"], facades.map(&:tool_name)
  end

  def test_uncategorized_error_mode_raises
    d = domain
    list_h = FacadeListWidgetsHandler
    Class.new(McpAuthorization::Tool) do
      tool_name "stray_#{d}"
      tags d
      dynamic_contract list_h
    end
    facet!(uncategorized: :error)
    assert_raises(FB::UncategorizedToolError) do
      FB.facades_for(domain: domain, server_context: full_ctx)
    end
  end

  # --------------------------------------------------------------------------
  # Facade name collisions
  # --------------------------------------------------------------------------

  def test_facade_name_colliding_with_real_tool_raises
    d = domain
    cat = :"cat_#{d}" # test-unique category so the colliding name never leaks to other tests
    list_h = FacadeListWidgetsHandler
    Class.new(McpAuthorization::Tool) do
      tool_name "cat_#{d}_tools" # shadows the category's facade name
      tags d
      category cat
      dynamic_contract list_h
    end
    facet!
    assert_raises(FB::FacadeNameCollisionError) do
      FB.facades_for(domain: domain, server_context: full_ctx)
    end
  end

  # --------------------------------------------------------------------------
  # Dispatch: real call path, gating enforced, coercion against target schema
  # --------------------------------------------------------------------------

  def test_dispatch_reaches_target_tool_through_real_call_path
    define_standard_tools
    facet!
    ctx = full_ctx
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    response = facade.call(
      server_context: ctx,
      tool_name: "list_widgets_#{domain}",
      arguments: { status: "active" }
    )
    assert_instance_of MCP::Tool::Response, response
    assert_equal ["w1-active"], response.structured_content[:widgets]
  end

  def test_dispatch_rejects_tool_name_not_advertised_to_caller
    define_standard_tools
    facet!
    ctx = StubContext.new([:view_widgets])
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    err = assert_raises(ArgumentError) do
      facade.call(server_context: ctx, tool_name: "update_widget_#{domain}", arguments: {})
    end
    assert_match(/unknown tool_name/, err.message)
  end

  def test_dispatch_reruns_permitted_even_for_advertised_names
    define_standard_tools
    facet!
    # Facade built for a privileged caller, but invoked with a weaker
    # context: the advertised set passes, but tool_class_for re-checks
    # permitted? and must deny.
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: full_ctx)
    weak_ctx = StubContext.new([])

    assert_raises(McpAuthorization::Tool::NotAuthorizedError) do
      facade.call(server_context: weak_ctx, tool_name: "list_widgets_#{domain}", arguments: {})
    end
  end

  def test_dispatch_coerces_json_string_arguments_blob
    define_standard_tools
    facet!
    ctx = full_ctx
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    response = facade.call(
      server_context: ctx,
      tool_name: "update_widget_#{domain}",
      arguments: JSON.generate(id: "w9", meta: { note: "hi" })
    )
    assert_equal "w9", response.structured_content[:id]
    assert_equal "hi", response.structured_content[:note]
  end

  def test_dispatch_coerces_nested_json_string_against_target_schema
    define_standard_tools
    facet!
    ctx = full_ctx
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    # meta is an object in the *target* tool's schema but arrives as a JSON
    # string — the facade's generic `arguments: object` contract alone could
    # not know to parse it.
    response = facade.call(
      server_context: ctx,
      tool_name: "update_widget_#{domain}",
      arguments: { id: "w2", meta: JSON.generate(note: "nested") }
    )
    assert_equal "nested", response.structured_content[:note]
  end

  def test_dispatch_rejects_malformed_json_arguments
    define_standard_tools
    facet!
    ctx = full_ctx
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    err = assert_raises(ArgumentError) do
      facade.call(server_context: ctx, tool_name: "list_widgets_#{domain}", arguments: "{not json")
    end
    assert_match(/not valid JSON/, err.message)
  end

  def test_dispatch_strips_permission_gated_fields_like_a_direct_call
    define_standard_tools
    facet!
    ctx = StubContext.new([:view_widgets, :manage_widgets]) # not :admin
    facade = FB.facade_for(domain: domain, name: "widgets_tools", server_context: ctx)

    response = facade.call(
      server_context: ctx,
      tool_name: "update_widget_#{domain}",
      arguments: { id: "w3", meta: { note: "x" }, force: true }
    )
    assert_equal false, response.structured_content[:forced],
      "@requires(:admin) input must be stripped before the handler, same as a direct call"
  end

  # --------------------------------------------------------------------------
  # ToolRegistry delegation
  # --------------------------------------------------------------------------

  def test_registry_delegates_facades_for_and_facade_for
    define_standard_tools
    facet!
    facades = McpAuthorization::ToolRegistry.facades_for(domain: domain, server_context: full_ctx)
    assert_equal ["billing_tools", "widgets_tools"], facades.map(&:tool_name).sort

    one = McpAuthorization::ToolRegistry.facade_for(
      domain: domain, name: "widgets_tools", server_context: full_ctx
    )
    assert_equal "widgets_tools", one.tool_name
  end

  # --------------------------------------------------------------------------
  # tools/list cache: facet config is part of the defs digest
  # --------------------------------------------------------------------------

  def test_facet_config_and_summaries_change_defs_digest
    define_standard_tools
    base = McpAuthorization::Cache.send(:compute_defs_digest)

    facet!
    faceted = McpAuthorization::Cache.send(:compute_defs_digest)
    refute_equal base, faceted, "toggling grouping must invalidate cached tools/list"

    McpAuthorization.config.categories { summary :widgets, "Widget tools." }
    with_summary = McpAuthorization::Cache.send(:compute_defs_digest)
    refute_equal faceted, with_summary, "editing a group summary must invalidate cached tools/list"
  end

  def test_facades_are_not_registered_as_tools
    define_standard_tools
    facet!
    facades = FB.facades_for(domain: domain, server_context: full_ctx)
    facades.each do |facade|
      refute_includes McpAuthorization::ToolRegistry.registered_tools, facade,
        "facades are per-request synthetics and must never enter the registry"
    end
  end
end
