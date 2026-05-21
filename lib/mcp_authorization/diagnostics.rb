module McpAuthorization
  # Shared diagnostic helpers used by both the field-level
  # +RbsSchemaCompiler#predicate_excluded?+ and the tool-level
  # +Tool#gates_pass?+ paths.
  #
  # Lives in its own module so the two predicate sites — field-level
  # (compile time) and tool-level (request time) — share a single
  # "Did you mean?" warning implementation. Avoids two copies of
  # Levenshtein drifting.
  module Diagnostics
    module_function

    # Emit a development-mode warning when a predicate method is not
    # found on the server context. Helps catch typos like
    # +@feture(:x)+ or +gate :feture, :sms+.
    #
    # @param name [String, Symbol] The predicate name attempted (e.g. +"feature"+ or +:gate+).
    # @param server_context [Object] The context the predicate was looked up on.
    # @param site [Symbol] +:field+ or +:tool+ — controls the suggestion phrasing.
    # @return [void]
    #: (String | Symbol, untyped, Symbol) -> void
    def warn_unknown_predicate(name, server_context, site:)
      return unless defined?(Rails) && Rails.respond_to?(:env) && Rails.env.local?

      str = name.to_s
      available = server_context.class.public_instance_methods(true)
        .select { |m| m.to_s.end_with?("?") }
        .map { |m| m.to_s.chomp("?") }
      best = available.min_by { |a| levenshtein(a, str) }
      suggestion = best && levenshtein(best, str) <= 3 ? best : nil

      hint =
        case site
        when :tool  then suggestion ? " Did you mean gate :#{suggestion}?" : ""
        when :field then suggestion ? " Did you mean @#{suggestion}?" : ""
        else             suggestion ? " Did you mean #{suggestion}?" : ""
        end

      surface =
        case site
        when :tool  then "Gate predicate"
        when :field then "Predicate"
        else             "Predicate"
        end

      fallthrough =
        case site
        when :tool  then "Tool will be shown to all users."
        when :field then "Field will be shown to all users."
        else             ""
        end

      Rails.logger&.warn(
        "[McpAuthorization] #{surface} '#{str}?' not found on #{server_context.class}.#{hint} #{fallthrough}".strip
      )
    end

    # Minimal Levenshtein distance for typo suggestions.
    #
    # Iterative two-row implementation — O(m*n) time, O(m) extra space.
    # Used only in development for "Did you mean?" suggestions, so the
    # naive version is fine.
    #
    # @param a [String]
    # @param b [String]
    # @return [Integer]
    #: (String, String) -> Integer
    def levenshtein(a, b)
      m, n = a.length, b.length
      d = Array.new(m + 1) { |i| i }
      (1..n).each do |j|
        prev = d[0]
        d[0] = j
        (1..m).each do |i|
          cost = a[i - 1] == b[j - 1] ? 0 : 1
          temp = d[i]
          d[i] = [d[i] + 1, d[i - 1] + 1, prev + cost].min
          prev = temp
        end
      end
      d[m]
    end
  end
end
