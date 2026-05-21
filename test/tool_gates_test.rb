require_relative "test_helper"

# Tests for tool-level generic predicate gating via `gate :name, :value`.
#
# Mirrors the field-level predicate system (see end_to_end_schema_test.rb)
# at the Tool wrapper layer: any predicate name works, fail-open on missing
# methods, error isolation, backward compat with existing `authorization`.
class ToolGatesTest < Minitest::Test
  # Anonymous tool class factory so each test gets a fresh class with
  # isolated class-instance state (@_permission, @_gates).
  def build_tool(&block)
    Class.new(McpAuthorization::Tool, &block)
  end

  # ---------------------------------------------------------------------------
  # Backward compatibility: existing `authorization :perm` still works alone
  # ---------------------------------------------------------------------------

  def test_authorization_only_grants_when_permission_present
    tool = build_tool do
      authorization :admin
    end
    assert tool.permitted?(StubContext.new([:admin]))
  end

  def test_authorization_only_denies_when_permission_missing
    tool = build_tool do
      authorization :admin
    end
    refute tool.permitted?(StubContext.new([]))
  end

  def test_no_authorization_no_gates_always_permits
    tool = build_tool {}
    assert tool.permitted?(StubContext.new([]))
  end

  # ---------------------------------------------------------------------------
  # Single gate
  # ---------------------------------------------------------------------------

  def test_single_feature_gate_grants_when_predicate_true
    tool = build_tool { gate :feature, :premium }
    ctx = StubContext.new([], features: ["premium"])
    assert tool.permitted?(ctx)
  end

  def test_single_feature_gate_denies_when_predicate_false
    tool = build_tool { gate :feature, :premium }
    ctx = StubContext.new([], features: [])
    refute tool.permitted?(ctx)
  end

  # ---------------------------------------------------------------------------
  # Multiple gates AND together — every gate must pass
  # ---------------------------------------------------------------------------

  def test_multiple_gates_all_must_pass
    tool = build_tool do
      gate :feature, :sms
      gate :feature, :bulk_ops
    end
    ctx = StubContext.new([], features: ["sms", "bulk_ops"])
    assert tool.permitted?(ctx)
  end

  def test_multiple_gates_one_failing_denies
    tool = build_tool do
      gate :feature, :sms
      gate :feature, :bulk_ops
    end
    ctx = StubContext.new([], features: ["sms"]) # missing bulk_ops
    refute tool.permitted?(ctx)
  end

  # ---------------------------------------------------------------------------
  # Combination: authorization (RBAC) + gate (feature)
  # ---------------------------------------------------------------------------

  def test_authorization_and_gate_both_required
    tool = build_tool do
      authorization :communications
      gate :feature, :sms
    end

    ctx_ok       = StubContext.new([:communications], features: ["sms"])
    ctx_no_perm  = StubContext.new([],                features: ["sms"])
    ctx_no_feat  = StubContext.new([:communications], features: [])
    ctx_neither  = StubContext.new([],                features: [])

    assert tool.permitted?(ctx_ok),     "should permit when both pass"
    refute tool.permitted?(ctx_no_perm), "should deny when permission missing"
    refute tool.permitted?(ctx_no_feat), "should deny when feature missing"
    refute tool.permitted?(ctx_neither), "should deny when both missing"
  end

  # ---------------------------------------------------------------------------
  # Generic predicates — any predicate name on the context works
  # ---------------------------------------------------------------------------

  def test_custom_predicate_tier_grants_on_match
    tool = build_tool { gate :tier, :enterprise }
    ctx = StubContextWithTier.new([], tier: "enterprise")
    assert tool.permitted?(ctx)
  end

  def test_custom_predicate_tier_denies_on_mismatch
    tool = build_tool { gate :tier, :enterprise }
    ctx = StubContextWithTier.new([], tier: "starter")
    refute tool.permitted?(ctx)
  end

  # ---------------------------------------------------------------------------
  # Fail-open on unknown predicate (tool stays visible)
  # ---------------------------------------------------------------------------

  def test_unknown_predicate_is_permissive
    tool = build_tool { gate :nonexistent_predicate, :foo }
    # StubContext does not implement nonexistent_predicate? — fail-open
    assert tool.permitted?(StubContext.new([])),
      "tool should remain visible when context lacks the predicate method"
  end

  # ---------------------------------------------------------------------------
  # `requires` backward-compat fallback to current_user.can?
  # ---------------------------------------------------------------------------

  def test_requires_gate_falls_back_to_current_user_can
    tool = build_tool { gate :requires, :admin }
    # Context object that has current_user but no requires? method.
    ctx = OpenStruct.new(current_user: StubUser.new([:admin]))
    assert tool.permitted?(ctx),
      "gate :requires should fall back to current_user.can? when requires? is undefined"
  end

  def test_requires_gate_fallback_denies_without_permission
    tool = build_tool { gate :requires, :admin }
    ctx = OpenStruct.new(current_user: StubUser.new([])) # no :admin
    refute tool.permitted?(ctx)
  end

  def test_requires_gate_fallback_denies_with_nil_user
    tool = build_tool { gate :requires, :admin }
    ctx = OpenStruct.new(current_user: nil)
    refute tool.permitted?(ctx),
      "gate :requires with nil current_user must deny (no user = no permission)"
  end

  # ---------------------------------------------------------------------------
  # Error isolation — broken predicate does not crash tools/list
  # ---------------------------------------------------------------------------

  def test_broken_predicate_fails_open
    tool = build_tool { gate :broken, :anything }
    ctx = StubContextWithBrokenPredicate.new
    assert tool.permitted?(ctx),
      "a raising predicate must fail-open (tool stays visible), not crash"
  end

  # ---------------------------------------------------------------------------
  # No server context — gates short-circuit to true (defensive)
  # ---------------------------------------------------------------------------

  def test_no_server_context_with_gates_returns_true
    tool = build_tool { gate :feature, :sms }
    assert tool.permitted?(nil),
      "permitted? with nil context must not raise"
  end
end
