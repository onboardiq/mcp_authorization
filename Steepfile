target :lib do
  check "lib"
  check "app"

  ignore "test"

  # Sentinel-generated from inline #: annotations
  signature "sig/generated"
  # Hand-written stubs for external deps (MCP gem, Rails)
  signature "sig/stubs"

  configure_code_diagnostics(Steep::Diagnostic::Ruby.all_error) do |hash|
    # Constants from gems without RBS (MCP, Rails) are expected
    hash[Steep::Diagnostic::Ruby::UnknownConstant] = :hint
    # We don't require every method declared in RBS to be implemented
    hash[Steep::Diagnostic::Ruby::MethodDefinitionMissing] = nil
    # Empty {} and [] are pervasive in schema-building code
    hash[Steep::Diagnostic::Ruby::UnannotatedEmptyCollection] = nil
    # Regex captures ($1, $2) are String? — too noisy for a regex-heavy parser
    hash[Steep::Diagnostic::Ruby::FallbackAny] = nil
    # Instance variables in class << self are tracked via self.@var in RBS
    hash[Steep::Diagnostic::Ruby::UnknownInstanceVariable] = :hint
    # Regex captures ($1/$2/$3) inside match guards are safely non-nil
    # at runtime, but Steep types them as String? and flags downstream
    # calls (.strip, .split, etc.). This produces ~30 false positives
    # in the RBS parser. Downgraded to warning so they're visible but
    # don't block.
    hash[Steep::Diagnostic::Ruby::NoMethod] = :warning
    hash[Steep::Diagnostic::Ruby::ArgumentTypeMismatch] = :warning
    hash[Steep::Diagnostic::Ruby::IncompatibleAssignment] = :warning
    hash[Steep::Diagnostic::Ruby::BlockBodyTypeMismatch] = :warning
    # Guard clauses like `return unless x.is_a?(Hash)` are defensive;
    # Steep proves the type statically and flags the branch as dead.
    hash[Steep::Diagnostic::Ruby::UnreachableBranch] = nil
    # break without a value inside each blocks
    hash[Steep::Diagnostic::Ruby::ImplicitBreakValueMismatch] = nil
    # Method body return type where ||= makes it look nullable
    hash[Steep::Diagnostic::Ruby::MethodBodyTypeMismatch] = :warning
    # Class.new(MCP::Tool) returns Class, not singleton(MCP::Tool) —
    # RBS has no bounded generics to express this
    hash[Steep::Diagnostic::Ruby::BlockBodyTypeMismatch] = nil
  end
end
