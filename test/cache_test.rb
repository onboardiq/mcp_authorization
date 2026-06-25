require_relative "test_helper"
require_relative "../lib/mcp_authorization/cache"

# Tests for the opt-in tools/list cache: stores, the recording proxy, and the
# decision-vector key (correct under feature flags, shareable across identity).
#
# Reuses StubContext/StubUser from test_helper — does NOT redefine the shared
# MCP::Tool / McpAuthorization::Tool / ToolRegistry constants (see
# keep-tests-shareable). McpAuthorization::Cache only references ToolRegistry /
# RbsSchemaCompiler inside methods, and the defs-digest path fails open to a
# stable value under the stubbed registry, so loading it here is safe.
class CacheTest < Minitest::Test
  Cache = McpAuthorization::Cache

  def setup
    Cache.reset!
    McpAuthorization.config.tools_list_cache = nil
  end

  def teardown
    McpAuthorization.config.tools_list_cache = nil
    Cache.reset!
  end

  # --- Stores -------------------------------------------------------------

  def test_null_store_never_caches
    s = Cache::NullStore.new
    s.set("k", { "a" => 1 })
    assert_nil s.get("k")
  end

  def test_memory_store_round_trips
    s = Cache::MemoryStore.new
    assert_nil s.get("k")
    s.set("k", { "tools" => [1, 2] })
    assert_equal({ "tools" => [1, 2] }, s.get("k"))
  end

  def test_memory_store_evicts_oldest_over_capacity
    s = Cache::MemoryStore.new(max_entries: 2)
    s.set("a", 1)
    s.set("b", 2)
    s.set("c", 3)
    assert_nil s.get("a"), "oldest entry should be evicted"
    assert_equal 2, s.get("b")
    assert_equal 3, s.get("c")
  end

  def test_memory_store_clear
    s = Cache::MemoryStore.new
    s.set("a", 1)
    s.clear
    assert_nil s.get("a")
  end

  # --- enabled? -----------------------------------------------------------

  def test_disabled_by_default
    refute Cache.enabled?, "caching is opt-in; default is NullStore"
  end

  def test_memory_setting_enables
    McpAuthorization.config.tools_list_cache = :memory
    Cache.reset!
    assert Cache.enabled?
    assert_instance_of Cache::MemoryStore, Cache.store
  end

  def test_custom_store_object_is_used_directly
    custom = Cache::MemoryStore.new
    McpAuthorization.config.tools_list_cache = custom
    Cache.reset!
    assert_same custom, Cache.store
  end

  # --- Recorder -----------------------------------------------------------

  def test_recorder_delegates_and_records_context_predicate
    rec = Cache::Recorder.new(StubContext.new([], features: ["sms"]))
    assert_equal true, rec.feature?(:sms)   # delegated result
    assert_equal false, rec.feature?(:mms)
    canon = rec.consulted.map(&:canonical)
    assert_includes canon, Cache::Signature.new(:context, "feature?", :sms).canonical
    assert_includes canon, Cache::Signature.new(:context, "feature?", :mms).canonical
  end

  def test_recorder_records_user_can_and_default_for
    user_ctx = StubContext.new([:admin], defaults: { funnel: "f_1" })
    rec = Cache::Recorder.new(user_ctx)
    assert_equal true, rec.current_user.can?(:admin)
    assert_equal "f_1", rec.current_user.default_for(:funnel)
    canon = rec.consulted.map(&:canonical)
    assert_includes canon, Cache::Signature.new(:user, "can?", :admin).canonical
    assert_includes canon, Cache::Signature.new(:user, "default_for", :funnel).canonical
  end

  def test_recorder_nil_user_is_nil
    ctx = Object.new
    def ctx.current_user; nil; end
    rec = Cache::Recorder.new(ctx)
    assert_nil rec.current_user
  end

  # --- Decision-vector key ------------------------------------------------

  def learn_sms_and_admin(domain)
    rec = Cache::Recorder.new(StubContext.new([:admin], features: ["sms"]))
    rec.feature?(:sms)
    rec.current_user.can?(:admin)
    Cache.learn!(domain: domain, recorder: rec)
  end

  def test_key_nil_until_domain_learned
    assert_nil Cache.tools_list_key(domain: "unlearned", server_context: StubContext.new([]))
  end

  def test_same_permissions_and_flags_share_a_key
    learn_sms_and_admin("recruiter")
    k1 = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([:admin], features: ["sms"]))
    k2 = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([:admin], features: ["sms"]))
    refute_nil k1
    assert_equal k1, k2
  end

  def test_flipping_a_feature_flag_changes_the_key
    learn_sms_and_admin("recruiter")
    on  = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([:admin], features: ["sms"]))
    off = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([:admin], features: []))
    refute_equal on, off, "an admin with a different feature flag must not share a cache entry"
  end

  def test_different_permission_changes_the_key
    learn_sms_and_admin("recruiter")
    admin = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([:admin], features: ["sms"]))
    plain = Cache.tools_list_key(domain: "recruiter", server_context: StubContext.new([], features: ["sms"]))
    refute_equal admin, plain
  end

  def test_different_default_value_changes_the_key
    rec = Cache::Recorder.new(StubContext.new([], defaults: { funnel: "f_1" }))
    rec.current_user.default_for(:funnel)
    Cache.learn!(domain: "d", recorder: rec)

    k1 = Cache.tools_list_key(domain: "d", server_context: StubContext.new([], defaults: { funnel: "f_1" }))
    k2 = Cache.tools_list_key(domain: "d", server_context: StubContext.new([], defaults: { funnel: "f_2" }))
    refute_equal k1, k2, "a baked-in default value is part of the schema, so it must be part of the key"
  end

  def test_domain_namespaces_the_key
    learn_sms_and_admin("recruiter")
    learn_sms_and_admin("admin")
    ctx = StubContext.new([:admin], features: ["sms"])
    refute_equal(
      Cache.tools_list_key(domain: "recruiter", server_context: ctx),
      Cache.tools_list_key(domain: "admin", server_context: ctx)
    )
  end

  # --- Explicit fingerprint hook -----------------------------------------

  def context_with_fingerprint(value)
    ctx = StubContext.new([])
    ctx.define_singleton_method(:mcp_cache_fingerprint) { value }
    ctx
  end

  def test_explicit_fingerprint_keys_without_learning
    # No learning step — explicit mode does not need the recorder/vocab.
    a = Cache.tools_list_key(domain: "d", server_context: context_with_fingerprint("FP-A"))
    b = Cache.tools_list_key(domain: "d", server_context: context_with_fingerprint("FP-A"))
    c = Cache.tools_list_key(domain: "d", server_context: context_with_fingerprint("FP-C"))
    refute_nil a
    assert_equal a, b
    refute_equal a, c
  end

  def test_recording_context_skips_recorder_when_fingerprint_present
    ctx = context_with_fingerprint("FP")
    effective, recorder = Cache.recording_context(ctx)
    assert_same ctx, effective
    assert_nil recorder
  end

  def test_recording_context_wraps_when_no_fingerprint
    ctx = StubContext.new([])
    effective, recorder = Cache.recording_context(ctx)
    assert_instance_of Cache::Recorder, effective
    assert_same effective, recorder
  end

  # --- End-to-end read-through (mirrors the controller flow) ---------------

  def test_cold_then_warm_read_through
    McpAuthorization.config.tools_list_cache = :memory
    Cache.reset!
    domain = "recruiter"
    ctx = StubContext.new([:admin], features: ["sms"])

    # Cold: domain not learned yet → no key → controller compiles.
    assert_nil Cache.tools_list_key(domain: domain, server_context: ctx)
    effective, recorder = Cache.recording_context(ctx)
    effective.feature?(:sms)             # simulate the compile consulting predicates
    effective.current_user.can?(:admin)
    Cache.learn!(domain: domain, recorder: recorder)

    key = Cache.tools_list_key(domain: domain, server_context: ctx)
    refute_nil key
    Cache.store.set(key, { "tools" => ["x"] }, ttl: Cache.ttl)

    # Warm: same context hits.
    assert_equal({ "tools" => ["x"] },
                 Cache.store.get(Cache.tools_list_key(domain: domain, server_context: ctx)))

    # A context with a different flag computes a different key → cache miss.
    off = StubContext.new([:admin], features: [])
    assert_nil Cache.store.get(Cache.tools_list_key(domain: domain, server_context: off))
  end
end
