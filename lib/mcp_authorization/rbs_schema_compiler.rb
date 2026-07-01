# Narrow require set: we use only RBS::Parser.parse_type and a handful of
# RBS::Types::* AST classes. Avoid `require "rbs"`, which pulls in ~144
# files (CLI, environment loader, definition builder, prototype generators,
# stdlib type signatures, ...) we never touch — ~15 MB RSS vs ~1.2 MB for
# the subset below. Load order matters: location_aux uses the C-defined
# RBS::Location, and rbs_extension assumes RBS::AST::* namespaces exist.
require "pathname" # rbs 4.x's parser_aux references Pathname at load time
require "rbs/version"
require "rbs/errors"
require "rbs/buffer"
require "rbs/namespace"
require "rbs/type_name"
require "rbs/types"
require "rbs/method_type"
require "rbs/ast/type_param"
require "rbs/ast/directives"
require "rbs/ast/declarations"
require "rbs/ast/members"
require "rbs/ast/annotation"
require "rbs/ast/comment"
# rbs 4.x's C extension (rbs_extension) references the RBS::AST::Ruby::*
# namespace, which did not exist on rbs 3.x. Require those files when the
# installed rbs ships them so the narrow load path stays correct across
# the gemspec's supported range (rbs >= 3.0); ignore on versions that
# predate the namespace, where rbs_extension does not need it.
%w[
  rbs/ast/ruby/helpers/constant_helper
  rbs/ast/ruby/helpers/location_helper
  rbs/ast/ruby/annotations
  rbs/ast/ruby/comment_block
  rbs/ast/ruby/declarations
  rbs/ast/ruby/members
].each do |feature|
  require feature
rescue LoadError
  # rbs < 4: file absent and rbs_extension does not reference it.
end
require "rbs_extension"
require "rbs/location_aux"
require "rbs/parser_aux"

require_relative "diagnostics"

module McpAuthorization
  # Compiles RBS-style type annotations in Ruby source files into JSON Schema,
  # with per-request filtering based on +@requires+ permission tags.
  #
  # This is the heart of the schema-shaping authorization approach. Rather
  # than defining JSON Schema separately, handler authors annotate their
  # Ruby source files with RBS-style comments:
  #
  #   # @rbs type output = success | admin_detail @requires(:admin)
  #
  #   #: (name: String, ?force: bool @requires(:admin)) -> Hash[Symbol, untyped]
  #   def call(name:, force: false)
  #
  # The compiler parses these annotations *once* and caches the result.
  # On each request, only the +@requires+ filtering runs — checking which
  # fields/variants the current user can see and building a tailored schema.
  #
  # == Two-phase design
  #
  # *Parse phase* (cached, runs once per handler class):
  # - Locate the handler's source file via +Method#source_location+
  # - Load shared types from +# @rbs import+ statements
  # - Parse local +# @rbs type+ definitions into a type map
  # - Parse the +#:+ annotation above +def call+ into parameter descriptors
  #
  # *Compile phase* (per-request):
  # - Filter parameters/variants by +@requires+ tags against +current_user.can?+
  # - Apply constraint tags (+@min+, +@format+, etc.) to JSON Schema keywords
  # - Inject +$ref/$defs+ when named types appear more than once (saves space)
  #
  # == Supported annotation tags
  #
  # See +extract_tags+ for the full list. Key tags:
  # - +@requires(:flag)+ — field is omitted from schema if user lacks this permission
  # - +@min(n)+, +@max(n)+ — type-aware: becomes minLength/maxLength on strings,
  #   minimum/maximum on numbers, minItems/maxItems on arrays
  # - +@format(name)+ — JSON Schema format (email, uri, date-time, etc.)
  # - +@default(value)+ / +@default_for(:key)+ — static or user-specific defaults
  # - +@desc(text)+, +@title(text)+ — JSON Schema annotation keywords
  #
  class RbsSchemaCompiler
    class << self
      # ---------------------------------------------------------------
      # Public API
      # ---------------------------------------------------------------

      # Compile the input JSON Schema for a handler class, filtered for the
      # current user's permissions.
      #
      # Supports two annotation styles:
      # 1. +# @rbs type input = { ... }+ — an explicit record type
      # 2. +#:+ annotation above +def call+ — inferred from method signature
      #
      #: (untyped, server_context: untyped) -> Hash[Symbol, untyped]
      def compile_input(handler_class, server_context:)
        cached = cache_for(handler_class)
        rctx = build_rctx(server_context, cached)

        schema = if cached[:raw_input]&.dig(:kind) == :record
          compile_tagged_record(cached[:raw_input][:body], cached[:type_map], server_context, source_file: cached[:source_file], rctx: rctx)
        else
          build_input_schema(
            filter_call_signature(cached[:call_params], cached[:type_map], server_context, rctx: rctx)
          )
        end

        schema = with_ref_injection(schema, cached[:type_map])
        McpAuthorization.config.strict_schema ? strict_sanitize(schema) : schema
      end

      # Compile the output JSON Schema for a handler class, filtered for
      # the current user's permissions.
      #
      #: (untyped, server_context: untyped) -> Hash[Symbol, untyped]?
      def compile_output(handler_class, server_context:)
        cached = cache_for(handler_class)

        if cached[:raw_output]&.dig(:kind) == :union
          schema = compile_tagged_union(cached[:raw_output][:body], cached[:type_map], server_context, rctx: build_rctx(server_context, cached))
          schema = with_ref_injection(schema, cached[:type_map])
          return McpAuthorization.config.strict_schema ? strict_sanitize(schema) : schema
        end
      end

      # Filter incoming params against the user's compiled input schema.
      #
      # Any key that is not in the schema for this user is dropped — including
      # +@requires+-gated fields the user lacks permission for, and any
      # unknown fields not declared in the schema. This is the runtime
      # enforcement counterpart to the input-shaping that +compile_input+ did.
      #
      # @param handler_class [Class]
      # @param params [Hash] Params as received from the MCP client.
      # @param server_context [Object] Per-request context.
      # @return [Hash] Filtered params safe to pass to the handler.
      #: (untyped, Hash[untyped, untyped], server_context: untyped) -> Hash[untyped, untyped]
      def filter_input(handler_class, params, server_context:)
        return params unless params.is_a?(Hash)
        schema = compile_input_for_filter(handler_class, server_context: server_context)
        return params unless schema
        project_against_schema(params, schema, defs_from(schema))
      end

      # Filter the handler's return value against the user's compiled output
      # schema. Any field/variant not visible to this user is stripped from
      # the result.
      #
      # This is the runtime counterpart to +compile_output+: even if a handler
      # bug or auth confusion causes it to emit fields the user shouldn't see,
      # they never cross the wire. Passes the result through unchanged if no
      # +@rbs type output+ is defined.
      #
      # @param handler_class [Class]
      # @param result [Object] Handler return value (hash/array/primitive).
      # @param server_context [Object] Per-request context.
      # @return [Object] Projected result, matching the user's output schema.
      #: (untyped, untyped, server_context: untyped) -> untyped
      def filter_output(handler_class, result, server_context:)
        schema = compile_output_for_filter(handler_class, server_context: server_context)
        return result unless schema
        project_against_schema(result, schema, defs_from(schema))
      end

      # Strip JSON Schema keywords unsupported by Anthropic's strict tool
      # use mode, and add additionalProperties: false to all objects.
      # Converts oneOf to anyOf (strict mode supports anyOf but not oneOf).
      #
      #: (Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
      def strict_sanitize(schema)
        return schema unless schema.is_a?(Hash)

        # Keywords that cause 400 in strict mode
        unsupported = %i[
          minLength maxLength minimum maximum
          exclusiveMinimum exclusiveMaximum multipleOf
          maxItems uniqueItems
          dependentRequired deprecated readOnly writeOnly
          title examples contentMediaType contentEncoding
        ]

        result = {}
        schema.each do |key, value|
          next if unsupported.include?(key)

          result[key] = case key
          when :properties
            value.transform_values { |v| strict_sanitize(v) }
          when :items
            strict_sanitize(value)
          when :oneOf
            # strict mode supports anyOf but not oneOf
            result.delete(key)
            result[:anyOf] = value.map { |s| strict_sanitize(s) }
            next
          when :anyOf, :allOf
            value.map { |s| strict_sanitize(s) }
          when :minItems
            # strict mode only supports 0 and 1
            value <= 1 ? value : nil
          when :"$defs"
            value.transform_values { |v| strict_sanitize(v) }
          else
            value
          end
        end

        # Strict mode requires additionalProperties: false on objects
        if result[:type] == "object" && result[:properties] && !result.key?(:additionalProperties)
          result[:additionalProperties] = false
        end

        result.compact
      end

      # Global cache for parsed shared +.rbs+ files. Keyed by file path;
      # each entry stores the file's mtime so stale entries are recompiled
      # when the file changes on disk.
      #
      #: () -> Hash[String, untyped]
      def shared_type_cache
        @shared_type_cache ||= {}
      end

      # Clear all cached type maps and shared type caches. Called by the
      # Engine's reloader on code change in development so that modified
      # annotations are re-parsed on the next request.
      #: () -> void
      def reset_cache!
        @cache = {}
        @shared_type_cache = {}
      end

      private

      # ---------------------------------------------------------------
      # Runtime enforcement — project values against the user's schema
      # ---------------------------------------------------------------

      # Like +compile_input+ but keeps +$defs+ inline-resolvable and skips
      # the LLM-facing +strict_sanitize+ pass. Used by +filter_input+ so
      # enforcement operates on the same semantic schema the LLM was given
      # without any strict-mode transforms that would lose type info.
      #: (untyped, server_context: untyped) -> Hash[Symbol, untyped]
      def compile_input_for_filter(handler_class, server_context:)
        cached = cache_for(handler_class)
        rctx = build_rctx(server_context, cached)

        schema = if cached[:raw_input]&.dig(:kind) == :record
          compile_tagged_record(cached[:raw_input][:body], cached[:type_map], server_context, source_file: cached[:source_file], rctx: rctx)
        else
          build_input_schema(
            filter_call_signature(cached[:call_params], cached[:type_map], server_context, rctx: rctx)
          )
        end

        with_ref_injection(schema, cached[:type_map])
      end

      # Like +compile_output+ but skips +strict_sanitize+. Returns nil when
      # the handler has no +# @rbs type output+ declaration.
      #: (untyped, server_context: untyped) -> Hash[Symbol, untyped]?
      def compile_output_for_filter(handler_class, server_context:)
        cached = cache_for(handler_class)
        return nil unless cached[:raw_output]&.dig(:kind) == :union

        schema = compile_tagged_union(cached[:raw_output][:body], cached[:type_map], server_context, rctx: build_rctx(server_context, cached))
        with_ref_injection(schema, cached[:type_map])
      end

      # Extract the +$defs+ table from a compiled schema for +$ref+ resolution.
      #: (Hash[Symbol, untyped]?) -> Hash[String, Hash[Symbol, untyped]]
      def defs_from(schema)
        return {} unless schema.is_a?(Hash)
        (schema[:"$defs"] || {}).each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      end

      # If +schema+ is a +$ref+ pointer, resolve it against +defs+. Otherwise
      # return the schema unchanged.
      #: (Hash[Symbol, untyped]?, Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]?
      def resolve_ref(schema, defs)
        return schema unless schema.is_a?(Hash)
        ref = schema[:"$ref"] || schema["$ref"]
        return schema unless ref
        name = ref.to_s.sub(%r{\A#/\$defs/}, "")
        defs[name] || schema
      end

      # Recursively project a runtime value onto a compiled JSON Schema.
      #
      # The semantics: the schema is authoritative — the result only contains
      # what the schema allows for this user.
      #
      # * Objects keep only declared +properties+; everything else is dropped.
      # * Arrays recurse into +items+.
      # * +oneOf+/+anyOf+ picks the best-matching variant (by present/required
      #   keys) and projects against it; unmatched variants are ignored.
      # * Primitives (and un-typed schemas) pass through unchanged.
      #
      # This is how +@requires+-gated fields are enforced at runtime: they
      # are already absent from +schema[:properties]+ for a user who lacks
      # the flag, so the projection simply drops them from the value.
      #: (untyped, Hash[Symbol, untyped]?, Hash[String, Hash[Symbol, untyped]]) -> untyped
      def project_against_schema(value, schema, defs)
        return value if schema.nil?
        schema = resolve_ref(schema, defs)
        return value unless schema.is_a?(Hash)

        variants = schema[:oneOf] || schema[:anyOf]
        if variants.is_a?(Array) && !variants.empty?
          # Flatten so intersection (allOf) members project like the object
          # they describe — their discriminator const and merged fields live
          # across the allOf branches.
          resolved = variants.map { |v| flatten_all_of(v, defs) }
          best = best_variant_for(value, resolved)
          return best ? project_against_schema(value, best, defs) : value
        end

        # A bare intersection (allOf) — merge its branches and project.
        return project_against_schema(value, flatten_all_of(schema, defs), defs) if schema[:allOf].is_a?(Array)

        case schema[:type]
        when "object"
          return value unless value.is_a?(Hash)
          props = schema[:properties] || {}
          # additionalProperties governs keys with no declared property.
          # Absent (nil) keeps the closed-by-default projection that drops
          # undeclared keys — the enforcement that hides @requires-gated
          # fields. An explicit non-false value (a schema or true) means the
          # author opted the value open (e.g. Hash[K, untyped] compiles to
          # additionalProperties: {}), so unknown keys are preserved and
          # projected against that schema rather than stripped (issue #22).
          addl = schema[:additionalProperties]
          value.each_with_object({}) do |(k, v), acc|
            prop_schema = props[k.to_sym] || props[k.to_s] || props[k]
            if prop_schema
              acc[k] = project_against_schema(v, prop_schema, defs)
            elsif addl == false || addl.nil?
              next
            elsif addl.is_a?(Hash) && !addl.empty?
              acc[k] = project_against_schema(v, addl, defs)
            else
              acc[k] = v
            end
          end
        when "array"
          return value unless value.is_a?(Array)
          items = schema[:items]
          items ? value.map { |v| project_against_schema(v, items, defs) } : value
        else
          value
        end
      end

      # Choose the best-matching variant of a union for a given value.
      #
      # Discriminated unions come first: if a variant pins a property to a
      # +const+ (e.g. +type: "SchedulerStage"+) and the value carries that key
      # with a different value, the variant is disqualified outright. This makes
      # tagged unions project onto the exact matching member instead of the one
      # with the most incidental field overlap — and lets a value whose tag
      # matches no variant fall through to the defensive pass-through below.
      #
      # Otherwise: count how many of the value's keys appear in the variant's
      # +properties+, minus how many are unknown. Disqualify variants missing
      # any of the value's keys from their +required+ list that isn't present.
      # Returns nil if no variant can accommodate the value — in which case
      # the caller should leave the value unchanged (defensive pass-through).
      #: (untyped, Array[Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]?
      def best_variant_for(value, variants)
        return variants.first unless value.is_a?(Hash)

        value_keys = value.keys.map(&:to_s)
        scored = variants.filter_map do |variant|
          next unless variant.is_a?(Hash) && variant[:type] == "object"
          props = variant[:properties] || {}
          prop_keys = props.keys.map(&:to_s)
          required = (variant[:required] || []).map(&:to_s)

          next if (required - value_keys).any?
          next if const_discriminator_mismatch?(value, props)

          known = (value_keys & prop_keys).size
          unknown = (value_keys - prop_keys).size
          [known - unknown, variant]
        end

        return nil if scored.empty?
        scored.max_by { |score, _| score }&.last
      end

      # Merge an +allOf+ (intersection) schema into a single object schema by
      # unioning the +properties+/+required+ of every branch (each resolved
      # through +$ref+). Non-intersection schemas are returned resolved and
      # unchanged. This lets the union projection treat +allOf: [{$ref base},
      # {own fields}]+ — the shape produced by a +base & { ... }+ contract —
      # as the flat record it logically is, so the discriminator const and the
      # merged field set are visible to +best_variant_for+ and projection.
      #: (untyped, Hash[String, Hash[Symbol, untyped]]) -> untyped
      def flatten_all_of(schema, defs)
        schema = resolve_ref(schema, defs)
        return schema unless schema.is_a?(Hash) && schema[:allOf].is_a?(Array)

        props = {}
        required = [] #: Array[untyped]
        additional = nil
        schema[:allOf].each do |branch|
          b = flatten_all_of(branch, defs)
          next unless b.is_a?(Hash)
          props.merge!(b[:properties]) if b[:properties].is_a?(Hash)
          required.concat(Array(b[:required]))
          additional = b[:additionalProperties] if b.key?(:additionalProperties)
        end

        merged = { type: "object", properties: props } #: Hash[Symbol, untyped]
        merged[:required] = required.uniq unless required.empty?
        merged[:additionalProperties] = additional unless additional.nil?
        # Preserve any sibling keys set alongside allOf (rare, defensive).
        schema.each { |k, v| merged[k] ||= v unless k == :allOf }
        merged
      end

      # True when +value+ carries a key that +props+ pins to a +const+ but with
      # a different value — i.e. a discriminated-union tag mismatch. Keys absent
      # from the value never disqualify (that's a +required+ concern).
      #: (Hash[untyped, untyped], Hash[untyped, untyped]) -> bool
      def const_discriminator_mismatch?(value, props)
        props.any? do |key, schema|
          next false unless schema.is_a?(Hash) && schema.key?(:const)

          present = value.key?(key.to_sym) || value.key?(key.to_s)
          next false unless present

          actual = value.key?(key.to_sym) ? value[key.to_sym] : value[key.to_s]
          actual.to_s != schema[:const].to_s
        end
      end

      # ---------------------------------------------------------------
      # Tag extraction — unified parser for all @tag(...) annotations
      # ---------------------------------------------------------------

      # Extract all +@tag(value)+ annotations from a type string.
      #
      # Annotations are parsed right-to-left from the end of the string,
      # peeling off one +@tag(...)+ at a time until none remain. This
      # returns the clean RBS type (without tags) and a hash of parsed
      # tag values.
      #
      # @example
      #   extract_tags("String @min(1) @max(100)")
      #   #=> ["String", { min: 1, max: 100 }]
      #
      #   extract_tags("bool @requires(:admin)")
      #   #=> ["bool", { requires: :admin }]
      #
      # @param type_str [String] An RBS type string, possibly with trailing tags.
      # @return [Array(String, Hash)] +[clean_type, tags_hash]+
      #
      # Supported tags:
      #   @requires(:symbol)      -> added to :predicates (calls server_context.requires?)
      #   @depends_on(:field)     -> { depends_on: "field" }
      #   @min(n)                 -> { min: n }
      #   @max(n)                 -> { max: n }
      #   @exclusive_min(n)       -> { exclusive_min: n }
      #   @exclusive_max(n)       -> { exclusive_max: n }
      #   @multiple_of(n)         -> { multiple_of: n }
      #   @pattern(regex)         -> { pattern: "regex" }
      #   @format(name)           -> { format: "name" }
      #   @default(value)         -> { default: value }
      #   @default_for(:key)     -> { default_for: :key } (resolved via current_user.default_for)
      #   @desc(text)             -> { desc: "text" }
      #   @title(text)            -> { title: "text" }
      #   @example(value)         -> { examples: [value, ...] }
      #   @deprecated()           -> { deprecated: true }
      #   @read_only()            -> { read_only: true }
      #   @write_only()           -> { write_only: true }
      #   @unique()               -> { unique: true }
      #   @closed() / @strict()   -> { closed: true }
      #   @media_type(type)       -> { media_type: "type" }
      #   @encoding(enc)          -> { encoding: "enc" }
      #
      # Any tag not listed above is treated as a **predicate filter**:
      #   @feature(:flag)         -> added to predicates, calls server_context.feature?(:flag)
      #   @tier(:enterprise)      -> added to predicates, calls server_context.tier?(:enterprise)
      #   @custom(:value)         -> added to predicates, calls server_context.custom?(:value)
      #
      # Predicate filters exclude the field/variant from the schema when the
      # predicate returns false. The server_context must respond to +tag_name?+.
      #: (String) -> [String, Hash[Symbol, untyped]]
      def extract_tags(type_str)
        tags = {}

        # Extract all @tag(...) annotations from right to left, using a
        # bracket-aware peeler so tag values can contain balanced parens,
        # commas, and pipes (e.g. +@desc(foo (bar). Required.)+).
        while (peeled = peel_trailing_tag(type_str))
          type_str, tag_name, tag_value = peeled

          case tag_name
          when "requires"
            (tags[:predicates] ||= []) << { name: "requires", value: tag_value.delete_prefix(":") }
          when "depends_on"
            tags[:depends_on] = tag_value.delete_prefix(":")
          when "min"
            tags[:min] = tag_value.include?(".") ? tag_value.to_f : tag_value.to_i
          when "max"
            tags[:max] = tag_value.include?(".") ? tag_value.to_f : tag_value.to_i
          when "exclusive_min"
            tags[:exclusive_min] = tag_value.include?(".") ? tag_value.to_f : tag_value.to_i
          when "exclusive_max"
            tags[:exclusive_max] = tag_value.include?(".") ? tag_value.to_f : tag_value.to_i
          when "multiple_of"
            tags[:multiple_of] = tag_value.include?(".") ? tag_value.to_f : tag_value.to_i
          when "pattern"
            tags[:pattern] = tag_value
          when "format"
            tags[:format] = tag_value
          when "default"
            tags[:default] = parse_default_value(tag_value)
          when "default_for"
            tags[:default_for] = tag_value.delete_prefix(":").to_sym
          when "desc"
            tags[:desc] = tag_value
          when "title"
            tags[:title] = tag_value
          when "example"
            (tags[:examples] ||= []) << parse_default_value(tag_value)
          when "deprecated"
            tags[:deprecated] = true
          when "read_only"
            tags[:read_only] = true
          when "write_only"
            tags[:write_only] = true
          when "unique"
            tags[:unique] = true
          when "closed", "strict"
            tags[:closed] = true
          when "media_type"
            tags[:media_type] = tag_value
          when "encoding"
            tags[:encoding] = tag_value
          else
            (tags[:predicates] ||= []) << { name: tag_name, value: tag_value.delete_prefix(":") }
          end
        end

        [type_str, tags]
      end

      # ---------------------------------------------------------------
      # Bracket-aware parsing primitives
      #
      # The historical regex parser used flat patterns like +[^)]*+,
      # +[^,}]++, and bare +.split("|")+ to find delimiters in RBS-flavored
      # annotations. Those patterns can't track nested brackets — a classic
      # limitation of regular expressions (regex are finite automata with
      # no counter; balanced delimiters are not a regular language). The
      # symptom was silent miscompilation when tag values contained the
      # delimiter characters (e.g. +@desc(foo (bar). baz)+ would terminate
      # the +)+ scan at the inner +)+, leaving the outer +@desc(...)+
      # un-extracted and the field's type misparsed).
      #
      # These helpers walk the string character-by-character tracking
      # +()+, +[]+, +{}+ depth so delimiters inside any balanced bracket
      # pair are skipped. Used by:
      # - +extract_tags+              — locate +@tag(...)+ with balanced value
      # - +compile_tagged_record+     — split fields on +,+ at depth 0
      # - +parse_record_type+         — same
      # - +compile_tagged_union+      — split variants on +|+ at depth 0
      # - +rbs_type_to_json_schema+   — same
      #
      # See the 0.5.1 CHANGELOG for the bug-class history. This is the
      # foundation that Phase 2 of the parser migration will reuse.
      # ---------------------------------------------------------------

      # Find the position of the first character in +delims+ that occurs
      # at bracket depth 0, scanning left-to-right from +start+. Returns
      # +nil+ if no such position exists.
      #
      # Tracks +()+, +[]+, +{}+ as balanced pairs. A delimiter inside any
      # of these pairs is skipped.
      #
      # @example
      #   find_at_depth_zero("a, b, (c, d), e", [","])  #=> 1
      #   find_at_depth_zero("a, b, (c, d), e", [","], start: 2)  #=> 4
      #   find_at_depth_zero("(no delim here)", [","])  #=> nil
      #
      #: (String, Array[String], ?start: Integer) -> Integer?
      def find_at_depth_zero(str, delims, start: 0)
        depth = 0
        pos = start
        while pos < str.length
          ch = str[pos].to_s
          return pos if depth.zero? && delims.include?(ch)
          if "([{".include?(ch)
            depth += 1
          elsif ")]}".include?(ch)
            depth -= 1
          end
          pos += 1
        end
        nil
      end

      # Split +str+ on every occurrence of +delim+ at bracket depth 0.
      # Returns an array of substrings (NOT stripped, NOT filtered).
      # Callers strip / reject empties as needed to match prior semantics.
      #
      # @example
      #   split_at_depth_zero("a, b, (c, d), e", ",")
      #   #=> ["a", " b", " (c, d)", " e"]
      #
      #: (String, String) -> Array[String]
      def split_at_depth_zero(str, delim)
        parts = []
        start = 0
        while (pos = find_at_depth_zero(str, [delim], start: start))
          parts << str[start...pos].to_s
          start = pos + 1
        end
        parts << str[start..].to_s
        parts
      end

      # Peel the rightmost +@tag(...)+ off +type_str+ if one exists,
      # respecting balanced parentheses inside the tag value.
      #
      # Returns +[remaining_type_str, tag_name, tag_value]+ on success, or
      # +nil+ if no trailing tag is found. The remainder is right-stripped.
      # The tag value is not stripped (preserves intentional whitespace
      # in +@desc(...)+ for example).
      #
      # The +@+ must be preceded by whitespace or be at position 0, so
      # +"@foo"+ in the middle of a type expression isn't mistaken for a
      # tag (this matches the prior regex semantics with +\s+@+).
      #
      # @example
      #   peel_trailing_tag("Integer @desc(a (b) c) @min(1)")
      #   #=> ["Integer @desc(a (b) c)", "min", "1"]
      #
      #   peel_trailing_tag("Integer @desc(a (b) c)")
      #   #=> ["Integer", "desc", "a (b) c"]
      #
      #: (String) -> [String, String, String]?
      def peel_trailing_tag(type_str)
        trimmed = type_str.rstrip
        return nil unless trimmed.end_with?(")")

        close_pos = trimmed.length - 1
        open_pos = find_matching_open_paren(trimmed, close_pos)
        return nil unless open_pos
        return nil if open_pos.zero?

        # Walk backward from open_pos to capture the tag name (\w+).
        name_end = open_pos
        name_start = name_end
        while name_start > 0 && trimmed[name_start - 1].to_s.match?(/\w/)
          name_start -= 1
        end
        return nil if name_start == name_end

        # The character immediately before the name must be '@'.
        at_pos = name_start - 1
        return nil unless at_pos >= 0 && trimmed[at_pos] == "@"

        # The '@' must be preceded by whitespace or be at the start, so we
        # don't accidentally peel an '@' embedded in an identifier.
        return nil unless at_pos.zero? || trimmed[at_pos - 1].to_s.match?(/\s/)

        tag_name = trimmed[name_start...name_end].to_s
        tag_value = trimmed[(open_pos + 1)...close_pos].to_s
        remainder = trimmed[0...at_pos].to_s.rstrip

        [remainder, tag_name, tag_value]
      end

      # Find the position of the +(+ that matches the +)+ at +close_pos+
      # in +str+. Walks backward, counting nested parens. Returns +nil+
      # if no balanced match exists.
      #
      # Only tracks +()+ — other brackets inside the tag value are
      # transparent (e.g. +@example([1, 2])+ works because +[+ and +]+
      # don't affect paren depth).
      #
      #: (String, Integer) -> Integer?
      def find_matching_open_paren(str, close_pos)
        depth = 1
        i = close_pos - 1
        while i >= 0
          case str[i]
          when ")"
            depth += 1
          when "("
            depth -= 1
            return i if depth.zero?
          end
          i -= 1
        end
        nil
      end

      # Parse a field-name token (the part before +:+ in a record entry or
      # call signature parameter) into its clean name and an optional flag.
      #
      # Recognizes both forms:
      # - Prefix (RBS canonical, per README):     +?name:+ -> ["name", true]
      # - Suffix (legacy, deprecated for 0.6.0):  +name?:+ -> ["name", true]
      # - Unmarked:                                +name:+  -> ["name", false]
      #
      # The suffix form was historically accepted by parts of this gem
      # but is not standard RBS. Recognizing it consistently across all
      # three parsers (this method's callers) preserves backward
      # compatibility while a single +Kernel#warn+ with
      # +category: :deprecated+ steers consumers toward the prefix form.
      # Users can silence via +Warning[:deprecated] = false+ or
      # +-W:no-deprecated+ — the standard Ruby mechanisms.
      #
      # Raises +ArgumentError+ on malformed tokens. The helper produces
      # three distinct error messages — categories grouped by which
      # branch raises:
      # - empty, whitespace-only, or nil input -> "empty field name"
      # - double-marked optional after stripping (e.g. +"?key?"+) ->
      #   "is double-marked optional"
      # - any other shape that does not reduce to a bare +\w+
      #   identifier (e.g. +"?"+, +"??key"+, +"key??"+, or tokens with
      #   non-word characters) -> "invalid field name token"
      #
      # Whitespace adjacent to the marker is tolerated:
      # +" ? key"+ -> ["key", true]. (Note: the three production call
      # sites never produce such a token — their regexes don't permit
      # internal whitespace — so this tolerance only matters if the
      # helper is invoked directly.)
      #
      # @param raw [String] Token before the +:+ separator.
      # @param source_file [String, nil] Path included in the deprecation
      #   warning so consumers can locate the offending annotation. The
      #   handler source file is read as text during parsing, so it is
      #   not on the Ruby call stack — embedding the path in the message
      #   is the only way to make the warning actionable.
      # @return [Array(String, Boolean)] +[clean_name, optional?]+.
      #: (String, ?source_file: String?) -> [String, bool]
      def parse_field_name(raw, source_file: nil)
        raise ArgumentError, "empty field name" if raw.nil? || raw.to_s.strip.empty?

        trimmed = raw.to_s.strip
        prefix = trimmed.start_with?("?")
        suffix = trimmed.end_with?("?")

        bare = trimmed
        bare = bare.sub(/\A\?/, "").strip if prefix
        bare = bare.sub(/\?\z/, "").strip if suffix

        unless bare.match?(/\A\w+\z/)
          raise ArgumentError, "invalid field name token: #{raw.inspect}"
        end

        if prefix && suffix
          raise ArgumentError,
            "field #{bare.inspect} is double-marked optional (both ?prefix and suffix?); pick one"
        end

        warn_deprecated_suffix_marker(bare, source_file) if suffix

        [bare, prefix || suffix]
      end

      # Emit a deprecation warning for the legacy suffix optional marker
      # (+key?:+). Uses +Kernel#warn+ with +category: :deprecated+ so
      # silencing follows the standard Ruby mechanism
      # (+Warning[:deprecated] = false+, +-W:no-deprecated+) and not a
      # gem-specific env var.
      #
      # The source file path is embedded in the message because the
      # handler annotation is parsed as static text — the offending file
      # is not on the Ruby call stack at warn time, so +uplevel:+ cannot
      # surface it. Embedding the path keeps the warning actionable for
      # consumers grepping for the field name.
      #: (String, String?) -> void
      def warn_deprecated_suffix_marker(name, source_file)
        location = source_file ? " (in #{source_file})" : ""
        Kernel.warn(
          "[mcp_authorization] Deprecated optional marker syntax: " \
          "`#{name}?:`#{location}. Use prefix form `?#{name}:` instead. " \
          "The suffix form will be removed in 0.6.0.",
          category: :deprecated
        )
      end

      # Coerce a default value string from an annotation into its Ruby type.
      # Handles booleans, nil/null, integers, floats, and bare strings.
      #
      # @param value [String] Raw value from +@default(...)+ or +@example(...)+.
      # @return [Object] Coerced Ruby value.
      #: (String) -> untyped
      def parse_default_value(value)
        case value
        when "true" then true
        when "false" then false
        when "nil", "null" then nil
        when /\A-?\d+\z/ then value.to_i
        when /\A-?\d+\.\d+\z/ then value.to_f
        else value.delete('"').delete("'")
        end
      end

      # Map a parsed tag hash onto JSON Schema keywords in a schema hash.
      #
      # This is *type-aware*: +@min(5)+ becomes +minLength: 5+ on a string,
      # +minimum: 5+ on an integer, and +minItems: 5+ on an array. This lets
      # handler authors use a single annotation vocabulary regardless of the
      # underlying JSON Schema type.
      #
      # @param schema [Hash] JSON Schema hash (must already have +:type+ set).
      # @param tags [Hash] Parsed tags from +extract_tags+.
      # @param server_context [Object, nil] Needed to resolve +@default_for+ tags.
      # @return [Hash] The same schema hash, mutated with additional keywords.
      #: (Hash[Symbol, untyped], Hash[Symbol, untyped], ?server_context: untyped?) -> Hash[Symbol, untyped]
      def apply_tags(schema, tags, server_context: nil)
        # Type-aware min/max
        if tags[:min]
          case schema[:type]
          when "string" then schema[:minLength] = tags[:min]
          when "integer", "number" then schema[:minimum] = tags[:min]
          when "array" then schema[:minItems] = tags[:min]
          end
        end
        if tags[:max]
          case schema[:type]
          when "string" then schema[:maxLength] = tags[:max]
          when "integer", "number" then schema[:maximum] = tags[:max]
          when "array" then schema[:maxItems] = tags[:max]
          end
        end

        # Numeric constraints
        schema[:exclusiveMinimum] = tags[:exclusive_min] if tags[:exclusive_min]
        schema[:exclusiveMaximum] = tags[:exclusive_max] if tags[:exclusive_max]
        schema[:multipleOf] = tags[:multiple_of] if tags[:multiple_of]

        # String constraints
        schema[:pattern] = tags[:pattern] if tags[:pattern]
        schema[:format] = tags[:format] if tags[:format]

        # Array constraints
        schema[:uniqueItems] = true if tags[:unique]

        # Annotation keywords
        schema[:title] = tags[:title] if tags[:title]
        schema[:description] = tags[:desc] if tags[:desc]
        schema[:examples] = tags[:examples] if tags[:examples]
        if tags[:default_for] && server_context
          val = server_context.current_user.default_for(tags[:default_for])
          schema[:default] = val unless val.nil?
        elsif tags.key?(:default)
          schema[:default] = tags[:default]
        end
        schema[:deprecated] = true if tags[:deprecated]
        schema[:readOnly] = true if tags[:read_only]
        schema[:writeOnly] = true if tags[:write_only]

        # Niche constraints
        schema[:additionalProperties] = false if tags[:closed]
        schema[:contentMediaType] = tags[:media_type] if tags[:media_type]
        schema[:contentEncoding] = tags[:encoding] if tags[:encoding]

        schema
      end

      # ---------------------------------------------------------------
      # Cache — source files are parsed once; per-request work is only
      # the @requires filtering and tag application.
      # ---------------------------------------------------------------

      # Return the cached parse result for a handler class, building it
      # on first access.
      #
      # @param handler_class [Class]
      # @return [Hash] with keys +:type_map+, +:raw_input+, +:raw_output+,
      #   +:call_params+, +:source_file+.
      #: (untyped) -> Hash[Symbol, untyped]
      def cache_for(handler_class)
        cache = (@cache ||= {})
        cache[handler_class] ||= build_cache(handler_class)
      end

      # Parse a handler class's source file and build the type map and
      # parameter descriptors that the compile phase uses.
      #
      # The type map is built in two layers:
      # 1. Shared types from +# @rbs import+ statements (e.g. common enums)
      # 2. Local +# @rbs type+ definitions in the handler file (override shared)
      #
      # @param handler_class [Class]
      # @return [Hash]
      #: (untyped) -> Hash[Symbol, untyped]
      def build_cache(handler_class)
        source_file = find_source_file(handler_class)
        content = source_file && File.exist?(source_file) ? File.read(source_file) : ""

        # Build type map: collect the *raw* (unresolved) aliases from every
        # imported shared file plus the handler's own inline `# @rbs type`
        # definitions, merge them (local overrides imported), then resolve the
        # whole set together. Resolving as one set — rather than per file — is
        # what lets a shared type reference a type defined in another imported
        # file (e.g. a per-stage contract referencing a shared `move_rule`).
        raw_aliases = load_import_aliases(content).merge(collect_inline_aliases(content))
        type_map = resolve_collected_aliases(raw_aliases, source_file: source_file)

        # Retain the un-stripped record bodies (tags intact) so nested
        # record aliases can be recompiled per request with predicate
        # filtering — see resolve_named_type / build_rctx (issue #23).
        # Local definitions override imported ones, matching type_map.
        raw_record_bodies = load_import_raw_bodies(content).merge(collect_inline_record_bodies(content))

        {
          type_map: type_map,
          raw_input: find_raw_type_body(content, "input"),
          raw_output: find_raw_type_body(content, "output"),
          call_params: parse_call_params(content, source_file: source_file),
          source_file: source_file,
          raw_record_bodies: raw_record_bodies
        }
      end

      # ---------------------------------------------------------------
      # Predicate filtering — the per-request compile phase
      # ---------------------------------------------------------------

      # Build the per-request resolution context threaded through the type
      # visitor so that predicate filtering (+@requires+, +@feature+, ...)
      # recurses into nested record-type aliases — not just the top-level
      # fields (issue #23).
      #
      # +:raw_bodies+ holds the *un-stripped* record body for each named
      # record alias (tags intact), so a referenced alias can be recompiled
      # per request against +server_context+ via +compile_tagged_record+
      # rather than served from the statically-resolved +type_map+ (which
      # has already discarded its predicate tags). +:visiting+ tracks alias
      # names currently being expanded so a self- or mutually-recursive type
      # falls back to the static schema instead of looping forever.
      #
      #: (untyped, Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
      def build_rctx(server_context, cached)
        {
          server_context: server_context,
          raw_bodies: cached[:raw_record_bodies] || {},
          source_file: cached[:source_file],
          visiting: []
        }
      end

      # Resolve a named type reference during per-request compilation.
      #
      # If the name maps to a record alias whose raw body we retained, the
      # alias is recompiled with +compile_tagged_record+ so its own
      # predicate-gated fields are filtered against this request's
      # +server_context+ — making gating work at any nesting depth. A name
      # already on the +visiting+ stack (recursive type) or absent from
      # +raw_bodies+ falls back to the statically-resolved +type_map+ entry,
      # then to +fallback+.
      #
      #: (String, Hash[String, Hash[Symbol, untyped]], Hash[Symbol, untyped]?, Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
      def resolve_named_type(name, type_map, rctx, fallback)
        raw = rctx && rctx[:raw_bodies] && rctx[:raw_bodies][name]
        if raw && !rctx[:visiting].include?(name)
          child = rctx.merge(visiting: rctx[:visiting] + [name])
          compile_tagged_record(raw, type_map, rctx[:server_context], source_file: rctx[:source_file], rctx: child)
        else
          type_map[name] || fallback
        end
      end

      # Returns true if any predicate tag on a field/variant evaluates to
      # false, meaning the field should be excluded from the schema.
      #
      # For each predicate, calls +server_context.tag_name?(value)+.
      # If the server_context doesn't respond to the method, the predicate
      # is skipped (fail-open — unknown predicates don't block). This is
      # intentional: predicates shape the schema for the LLM, they are not
      # a security boundary. Hiding a field by accident (typo) is worse
      # than showing one extra field. Runtime enforcement (+filter_input+)
      # is the actual security layer.
      #
      # Special case: +@requires+ falls back to +current_user.can?+ when
      # the server_context lacks a +requires?+ method, for backward
      # compatibility with consumers that haven't migrated to predicates.
      #
      # Exceptions from individual predicates are rescued and logged so
      # that a single broken predicate doesn't crash the entire tools/list.
      #
      # @param tags [Hash] Parsed tags from +extract_tags+.
      # @param server_context [Object] Per-request context.
      # @return [Boolean] true if the field should be excluded.
      #: (Hash[Symbol, untyped], untyped) -> bool
      def predicate_excluded?(tags, server_context)
        return false unless tags[:predicates] && server_context
        tags[:predicates].any? do |pred|
          method = :"#{pred[:name]}?"
          if server_context.respond_to?(method)
            !server_context.public_send(method, pred[:value])
          elsif pred[:name] == "requires" && server_context.respond_to?(:current_user)
            # Backward compat: fall back to direct user permission check.
            # Note: nil current_user → &.can? returns nil → !nil is true → field excluded.
            # This is intentional: no user = no permissions = hide restricted fields.
            !server_context.current_user&.can?(pred[:value].to_sym)
          else
            warn_unknown_predicate(pred[:name], server_context)
            false # Fail-open: include the field
          end
        rescue => e
          if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
            Rails.logger.error("[McpAuthorization] predicate #{pred[:name]}?(#{pred[:value]}) raised: #{e.message}")
          end
          false # Fail-open on error: include the field
        end
      end

      # Emit a development-mode warning when a predicate method is not
      # found on the server_context. Delegates to the shared diagnostic
      # helper so the field-level (+@predicate+) and tool-level (+gate+)
      # warning shapes stay in sync.
      #: (String, untyped) -> void
      def warn_unknown_predicate(name, server_context)
        McpAuthorization::Diagnostics.warn_unknown_predicate(name, server_context, site: :field)
      end

      # Compile a record-style input type (+# @rbs type input = { ... }+)
      # with field-level predicate filtering.
      #
      # Fields whose predicate tags (e.g. +@requires+, +@feature+) evaluate
      # to false are silently omitted from the resulting JSON Schema.
      #
      # @param raw_body [String] The raw record body, e.g. +"{name: String, force: bool @requires(:admin)}"+.
      # @param type_map [Hash] Resolved type definitions for +$ref+ lookups.
      # @param server_context [Object] Per-request context.
      # @return [Hash] JSON Schema object with +properties+, +required+, etc.
      #: (String, Hash[String, Hash[Symbol, untyped]], untyped, ?source_file: String?, ?rctx: Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def compile_tagged_record(raw_body, type_map, server_context, source_file: nil, rctx: nil)
        rctx ||= { server_context: server_context, raw_bodies: {}, source_file: source_file, visiting: [] }
        properties = {}
        required = []
        dependent_required = {}

        each_field_in_record(raw_body) do |key, type_str|
          # A union field whose members carry their own predicate tags (e.g.
          # account-gated variants: `stage: a @feature(x) | b @feature(y)`)
          # routes through compile_tagged_union so each member is filtered per
          # request. The normal path's field-level extract_tags would otherwise
          # bind a member's tag to the whole field. Only triggers when the field
          # is a multi-member union AND carries a tag, so untagged union fields
          # keep the full RBS-library path (which handles inline records, etc.).
          if tagged_union_field?(type_str)
            clean_key, optional = parse_field_name(key, source_file: source_file)
            properties[clean_key.to_sym] = compile_tagged_union(type_str, type_map, server_context, rctx: rctx)
            required << clean_key unless optional
            next
          end

          # Array of a tagged union — `items: Array[a @feature(x) | b @feature(y)]`.
          # The union's `|` is at bracket depth 1, so tagged_union_field? misses
          # it; gate the element union and wrap it back in an array schema.
          if (inner = tagged_array_union_inner(type_str))
            clean_key, optional = parse_field_name(key, source_file: source_file)
            properties[clean_key.to_sym] = { type: "array", items: compile_tagged_union(inner, type_map, server_context, rctx: rctx) }
            required << clean_key unless optional
            next
          end

          type_str, tags = extract_tags(type_str)

          next if predicate_excluded?(tags, server_context)

          clean_key, optional = parse_field_name(key, source_file: source_file)

          schema = rbs_type_to_json_schema(type_str, type_map, source_file: source_file, rctx: rctx)
          properties[clean_key.to_sym] = apply_tags(schema, tags, server_context: server_context)
          required << clean_key unless optional

          if tags[:depends_on] && properties.key?(tags[:depends_on].to_sym)
            dependent_required[tags[:depends_on]] ||= []
            dependent_required[tags[:depends_on]] << clean_key
          end
        end

        schema = { type: "object", properties: properties } #: Hash[Symbol, untyped]
        schema[:required] = required if required.any?
        schema[:dependentRequired] = dependent_required if dependent_required.any?
        schema
      end

      # True when a record field's type is a multi-member union that carries a
      # predicate tag — i.e. per-member gating is intended. A `|` at bracket
      # depth 0 marks a real union (not one inside a nested generic/record).
      #
      # A tag trailing only the *final* member (e.g. a plain literal union
      # with one field-level `@desc(...)`, as in `"AND" | "OR" @desc(...)`)
      # is NOT per-member gating — every genuine per-member-tagged union in
      # this codebase tags each gated member individually
      # (`a @feature(x) | b @feature(y)`), so at least one *non-final*
      # member must carry a tag before we route into compile_tagged_union.
      # Otherwise the field falls through to the normal RBS-library path,
      # which resolves inline literal unions correctly via visit_rbs_union.
      #: (String) -> bool
      def tagged_union_field?(type_str)
        return false unless type_str.include?("@")
        per_member_tagged_union?(type_str, "|")
      end

      # If a field type is +Array[<multi-member tagged union>]+, return the inner
      # union expression so its members can be gated per request; else nil. The
      # union lives inside the +[]+ (bracket depth 1), so tagged_union_field?
      # (which only sees depth 0) does not match it.
      #: (String) -> String?
      def tagged_array_union_inner(type_str)
        return nil unless type_str.include?("@")
        m = type_str.strip.match(/\AArray\[(.+)\]\z/m)
        return nil unless m

        inner = m[1].to_s
        per_member_tagged_union?(inner, "|") ? inner : nil
      end

      # True when a `|`-separated type expression has more than one member
      # AND at least one *non-final* member carries a predicate tag. See
      # tagged_union_field? for why the final member alone doesn't count.
      #: (String, String) -> bool
      def per_member_tagged_union?(type_str, delimiter)
        parts = split_at_depth_zero(type_str, delimiter)
        return false unless parts.size > 1

        parts[0..-2].any? { |part| part.include?("@") }
      end

      # Compile a union-style output type (+# @rbs type output = success | admin_detail @requires(:admin)+)
      # with variant-level predicate filtering.
      #
      # Each union variant (separated by +|+) can carry its own predicate
      # tags. Variants whose predicates evaluate to false are dropped entirely.
      # If only one variant remains, it's returned directly (no +oneOf+
      # wrapper). If zero remain, a bare +{type: "object"}+ fallback is used.
      #
      # @param raw_expr [String] The raw union expression.
      # @param type_map [Hash] Resolved type definitions.
      # @param server_context [Object] Per-request context.
      # @return [Hash] JSON Schema — either a single schema or a +oneOf+ wrapper.
      #: (String, Hash[String, Hash[Symbol, untyped]], untyped, ?rctx: Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def compile_tagged_union(raw_expr, type_map, server_context, rctx: nil)
        rctx ||= { server_context: server_context, raw_bodies: {}, source_file: nil, visiting: [] }
        parts = split_at_depth_zero(raw_expr, "|").map(&:strip).reject(&:empty?)

        filtered = parts.filter_map do |part|
          part, tags = extract_tags(part)
          next nil if predicate_excluded?(tags, server_context)
          resolve_type(part, type_map, rctx)
        end

        case filtered.size
        when 0 then { type: "object" }
        when 1 then filtered.first
        else { type: "object", oneOf: filtered }
        end
      end

      # Filter method-signature parameters by predicate tags and build
      # the input JSON Schema. This is the path used when the handler defines
      # its schema via a +#:+ annotation above +def call+ rather than an
      # explicit +# @rbs type input = { ... }+.
      #
      # @param call_params [Array<Hash>] Parsed parameter descriptors from +parse_call_params+.
      # @param type_map [Hash] Resolved type definitions.
      # @param server_context [Object] Per-request context.
      # @return [Hash] Partial JSON Schema (+properties+, +required+, etc.).
      #: (Array[Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]], untyped, ?rctx: Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def filter_call_signature(call_params, type_map, server_context, rctx: nil)
        rctx ||= { server_context: server_context, raw_bodies: {}, source_file: nil, visiting: [] }
        properties = {}
        required = []
        dependent_required = {}

        call_params.each do |param|
          next if predicate_excluded?(param[:tags], server_context)

          schema = rbs_type_to_json_schema(param[:type], type_map, rctx: rctx)
          properties[param[:name].to_sym] = apply_tags(schema, param[:tags], server_context: server_context)
          required << param[:name] if param[:required]

          if param[:tags][:depends_on] && properties.key?(param[:tags][:depends_on].to_sym)
            dependent_required[param[:tags][:depends_on]] ||= []
            dependent_required[param[:tags][:depends_on]] << param[:name]
          end
        end

        schema = { properties: properties } #: Hash[Symbol, untyped]
        schema[:required] = required if required.any?
        schema[:dependentRequired] = dependent_required if dependent_required.any?
        schema
      end

      # ---------------------------------------------------------------
      # Source parsing — cached, runs once per handler class
      # ---------------------------------------------------------------

      # Scan handler source for +# @rbs import+ lines and load the
      # referenced shared +.rbs+ files into a merged type map.
      #
      # Import paths are resolved relative to the configured
      # +shared_type_paths+ directories (default: +sig/shared/+).
      #
      # @example In a handler file:
      #   # @rbs import common_types
      #   # → loads sig/shared/common_types.rbs
      #
      # @param content [String] Full source file contents.
      # @return [Hash{String => Hash}] Type name → JSON Schema map.
      #: (String) -> Hash[String, Hash[Symbol, untyped]]
      def load_imports(content)
        return {} if content.empty?

        imports = content.scan(/# @rbs import (\S+)/).flatten
        return {} if imports.empty?

        type_map = {}
        imports.each do |import_path|
          rbs_file = resolve_import_path(import_path)
          next unless rbs_file && File.exist?(rbs_file)
          type_map.merge!(cached_parse_rbs_file(rbs_file))
        end
        type_map
      end

      # Like +load_imports+, but returns the raw record bodies (tags
      # intact) from each imported +.rbs+ file so a predicate-gated field
      # inside a shared type is filtered per request — see +build_rctx+
      # (issue #23). Without this, gates authored in +sig/shared/*.rbs+
      # would parse but never fire.
      #: (String) -> Hash[String, String]
      def load_import_raw_bodies(content)
        return {} if content.empty?

        imports = content.scan(/# @rbs import (\S+)/).flatten
        return {} if imports.empty?

        raw = {}
        imports.each do |import_path|
          rbs_file = resolve_import_path(import_path)
          next unless rbs_file && File.exist?(rbs_file)
          raw.merge!(cached_rbs_record_bodies(rbs_file))
        end
        raw
      end

      # Parse a shared +.rbs+ file with mtime-based caching. If the file
      # hasn't changed since the last parse, the cached result is returned.
      #
      # @param path [String] Absolute path to the +.rbs+ file.
      # @return [Hash{String => Hash}] Type name → JSON Schema map.
      #: (String) -> Hash[String, Hash[Symbol, untyped]]
      def cached_parse_rbs_file(path)
        cached_rbs_entry(path)[:result]
      end

      # The raw record-body subset of a shared +.rbs+ file's aliases:
      # name → raw +"{ ... }"+ body string (tags intact). Shares the
      # mtime-keyed +shared_type_cache+ entry with +cached_parse_rbs_file+
      # so a file is read and parsed at most once per mtime.
      #: (String) -> Hash[String, String]
      def cached_rbs_record_bodies(path)
        cached_rbs_entry(path)[:raw_record_bodies]
      end

      # Build (or fetch) the mtime-keyed cache entry for a shared +.rbs+
      # file, holding both the resolved type map (+:result+) and the raw
      # record bodies (+:raw_record_bodies+).
      #: (String) -> Hash[Symbol, untyped]
      def cached_rbs_entry(path)
        mtime = File.mtime(path)
        cached = shared_type_cache[path]
        return cached if cached && cached[:mtime] == mtime

        aliases = collect_rbs_file_aliases(File.read(path))
        entry = {
          mtime: mtime,
          result: resolve_collected_aliases(aliases, source_file: path),
          raw_record_bodies: aliases.select { |_, v| v.is_a?(String) },
          raw_aliases: aliases
        }
        shared_type_cache[path] = entry
      end

      # The raw (unresolved) alias map of a shared +.rbs+ file — both record
      # bodies (String) and pre-resolved string-union schemas. Used to resolve
      # imports as one merged set so cross-file references resolve.
      #: (String) -> Hash[String, untyped]
      def cached_rbs_aliases(path)
        cached_rbs_entry(path)[:raw_aliases]
      end

      # Merge the raw aliases from every +# @rbs import+ed file in +content+.
      # Returned unresolved so the caller can resolve imports + local aliases
      # together (cross-file references resolve; see build_cache).
      #: (String) -> Hash[String, untyped]
      def load_import_aliases(content)
        return {} if content.empty?

        imports = content.scan(/# @rbs import (\S+)/).flatten
        return {} if imports.empty?

        raw = {}
        imports.each do |import_path|
          rbs_file = resolve_import_path(import_path)
          next unless rbs_file && File.exist?(rbs_file)
          raw.merge!(cached_rbs_aliases(rbs_file))
        end
        raw
      end

      # Resolve a bare import name (e.g. +"common_types"+) to an absolute
      # +.rbs+ file path by searching +shared_type_paths+.
      #
      # @param import_path [String] Bare import name without extension.
      # @return [String, nil] Absolute file path, or nil if not found.
      #: (String) -> String?
      def resolve_import_path(import_path)
        McpAuthorization.config.shared_type_paths.each do |base|
          candidate =
            if base.to_s.start_with?(File::SEPARATOR) # absolute base (tests / non-Rails hosts)
              File.join(base.to_s, "#{import_path}.rbs")
            elsif defined?(Rails)
              Rails.root.join(base, "#{import_path}.rbs").to_s
            else                                       # relative base, no Rails → resolve from CWD
              File.join(Dir.pwd, base.to_s, "#{import_path}.rbs")
            end
          return candidate if File.exist?(candidate)
        end
        nil
      end

      # Parse type definitions from a standalone +.rbs+ file (shared types).
      #
      # Unlike +parse_type_aliases+, this parses bare RBS syntax (no +#+ comment
      # markers) — the format used in +sig/shared/*.rbs+ files:
      #
      #   type success = { status: String, data: String }
      #   type priority = "low"
      #                 | "medium"
      #                 | "high"
      #
      # Record types are parsed into JSON Schema objects; string literal
      # unions become +{type: "string", enum: [...]}+.
      #
      # @param path [String] Absolute path to the +.rbs+ file.
      # @return [Hash{String => Hash}] Type name → resolved JSON Schema.
      #: (String) -> Hash[String, Hash[Symbol, untyped]]
      def parse_rbs_file(path)
        resolve_collected_aliases(collect_rbs_file_aliases(File.read(path)), source_file: path)
      end

      # Collect the +type X = ...+ aliases from a bare +.rbs+ file (no +#+
      # comment markers) into a name → raw value map, mirroring
      # +collect_inline_aliases+ for the shared-types format. Record bodies
      # stay raw (tags intact); string-literal unions resolve eagerly.
      #: (String) -> Hash[String, untyped]
      def collect_rbs_file_aliases(content)
        aliases = {}
        current_name = nil #: String?
        current_base = nil #: String?
        current_body = +""

        content.each_line do |line|
          stripped = line.strip

          if stripped =~ /\Atype (\w+) = (\w+) & \{/
            # Intersection: a base alias merged with an inline record, e.g.
            #   type scheduler_stage = stage_common & { type: "SchedulerStage", ... }
            # Captured as {intersection: [base, body]} and resolved to an
            # allOf so the shared base hoists into $defs once (token dedup).
            current_name = $1.to_s
            current_base = $2.to_s
            current_body = "{"
          elsif stripped =~ /\Atype (\w+) = \{/
            current_name = $1.to_s
            current_base = nil
            current_body = "{"
          elsif stripped =~ /\Atype (\w+) = ("[^"]*"(?:\s*\|\s*"[^"]*")*)/
            aliases[$1.to_s] = parse_rbs_string_union($2.to_s, line, content)
          elsif current_name
            current_body << strip_rbs_comment(stripped)
            if brace_balanced?(current_body)
              aliases[current_name] = current_base ? { intersection: [current_base, current_body] } : current_body
              current_name = nil
              current_base = nil
              current_body = +""
            end
          end
        end

        aliases
      end

      # Parse a string literal union from an .rbs file, either written on
      # one line:
      #   type logic = "AND" | "OR"
      # or continued across multiple lines:
      #   type priority = "low"
      #                 | "medium"
      #                 | "high"
      #
      # +first_segment+ is everything captured after the +=+ on the
      # opening line, which may itself already contain the full
      # +"a" | "b" | "c"+ union — a single-line union has no continuation
      # lines, so capturing only its first quoted literal (the prior
      # behavior) silently dropped every member after the first.
      #
      # @return [Hash] +{type: "string", enum: ["low", "medium", "high"]}+
      #: (String, String, String) -> Hash[Symbol, untyped]
      def parse_rbs_string_union(first_segment, line, content)
        values = first_segment.scan(/"([^"]*)"/).flatten
        content.each_line.drop_while { |l| l != line }.drop(1).each do |next_line|
          if next_line =~ /^\s*\|\s*"([^"]+)"/
            values << $1.to_s
          else
            break
          end
        end
        { type: "string", enum: values }
      end

      # Extract the raw body of a named +# @rbs type+ definition from
      # handler source, preserving any +@tag(...)+ annotations for later
      # filtering.
      #
      # Handles both record types (+{ ... }+) and union types (+a | b | c+),
      # including multi-line continuation with +# |+.
      #
      # @param content [String] Full source file contents.
      # @param type_name [String] Type name to find (e.g. +"input"+, +"output"+).
      # @return [Hash, nil] +{kind: :record, body: "..."}+, +{kind: :union, body: "..."}+, or nil.
      #: (String, String) -> Hash[Symbol, untyped]?
      def find_raw_type_body(content, type_name)
        return nil if content.empty?

        lines = content.lines
        pattern = Regexp.escape(type_name)

        lines.each_with_index do |line, idx|
          rest = lines[(idx + 1)..] || []

          if line =~ /# @rbs type #{pattern} = \{/
            body = "{"
            rest.each do |next_line|
              stripped = strip_rbs_comment(next_line.strip.sub(/^#\s*/, ""))
              body << stripped
              return { kind: :record, body: body } if brace_balanced?(body)
            end

          elsif line =~ /# @rbs type #{pattern} = ([^{].+)/
            expr = $1.to_s.strip
            rest.each do |next_line|
              if next_line =~ /^\s*#\s*\|\s*(.+)/
                expr += " | " + $1.to_s.strip
              else
                break
              end
            end
            return { kind: :union, body: expr }
          end
        end

        nil
      end

      # Parse +# @rbs type+ definitions from handler source into resolved
      # JSON Schema. These are the handler's local type definitions (as
      # opposed to shared types loaded via +# @rbs import+).
      #
      # Handles record types and string literal unions:
      #
      #   # @rbs type success = { status: String, data: String }
      #   # @rbs type priority = "low"
      #   #                    | "medium"
      #   #                    | "high"
      #
      # @param content [String] Full source file contents.
      # @return [Hash{String => Hash}] Type name → resolved JSON Schema.
      #: (String, ?source_file: String?) -> Hash[String, Hash[Symbol, untyped]]
      def parse_type_aliases(content, source_file: nil)
        return {} if content.empty?
        resolve_collected_aliases(collect_inline_aliases(content), source_file: source_file)
      end

      # Collect the +# @rbs type+ aliases declared in handler source into a
      # map of name → raw value: record types stay as their un-resolved
      # body string (+"{ ... }"+, tags intact); string-literal unions are
      # resolved eagerly to +{type: "string", enum: [...]}+ since they
      # carry no per-request predicates. Shared between +parse_type_aliases+
      # (which resolves the bodies) and +collect_inline_record_bodies+
      # (which keeps them raw for nested per-request filtering).
      #: (String) -> Hash[String, untyped]
      def collect_inline_aliases(content)
        aliases = {}
        current_name = nil #: String?
        current_body = +""

        content.each_line do |line|
          if line =~ /#\s*@rbs type (\w+)\s*=\s*(\{.*)$/
            # Start of a record alias. Capture the body from the first `{` to
            # end of line (minus any trailing comment), so a record written on
            # one line — `# @rbs type ok = { a: String }` — is captured whole
            # rather than truncated to a bare `{` (which silently dropped the
            # alias). If the braces already balance it's a single-line record;
            # otherwise keep accumulating on the following lines. Whitespace
            # around `=` is tolerated so column-aligned aliases still parse.
            current_name = $1.to_s
            current_body = +strip_rbs_comment($2.to_s)
            if brace_balanced?(current_body)
              aliases[current_name] = current_body
              current_name = nil
              current_body = +""
            end
          elsif line =~ /#\s*@rbs type (\w+)\s*=\s*("[^"]*"(?:\s*\|\s*"[^"]*")*)/
            aliases[$1.to_s] = parse_string_union($2.to_s, line, content)
          elsif current_name
            stripped = strip_rbs_comment(line.strip.sub(/^#\s*/, ""))
            current_body << stripped
            if brace_balanced?(current_body)
              aliases[current_name] = current_body
              current_name = nil
              current_body = +""
            end
          end
        end

        aliases
      end

      # The record-body subset of +collect_inline_aliases+: name → raw
      # +"{ ... }"+ body string for each handler-local record alias.
      #: (String) -> Hash[String, String]
      def collect_inline_record_bodies(content)
        return {} if content.empty?
        collect_inline_aliases(content).select { |_, v| v.is_a?(String) }
      end

      # Resolve a collected alias map (name → raw record body | resolved
      # Hash) into a name → JSON Schema type map. Forward references resolve
      # via +aliases_to_schemas+ placeholders.
      #: (Hash[String, untyped], ?source_file: String?) -> Hash[String, Hash[Symbol, untyped]]
      def resolve_collected_aliases(aliases, source_file: nil)
        resolved = {}

        # Pass 1: plain record bodies and already-resolved values (string
        # unions). Intersection bases are plain records, so this guarantees a
        # base is fully resolved before any intersection that references it.
        aliases.each do |name, value|
          next if value.is_a?(Hash) && value[:intersection]
          resolved[name] = if value.is_a?(String)
            parse_record_type(value, resolved.merge(aliases_to_schemas(aliases, resolved)), source_file: source_file)
          else
            value
          end
        end

        # Pass 2: intersections → allOf[base, record]. The base schema is the
        # fully-resolved shared type (same object across every member), so
        # with_ref_injection sees it used many times and hoists it into $defs.
        aliases.each do |name, value|
          next unless value.is_a?(Hash) && value[:intersection]
          base_name, body = value[:intersection]
          merged = resolved.merge(aliases_to_schemas(aliases, resolved))
          base_schema = resolved[base_name] || merged[base_name] || { type: "object" }
          record_schema = parse_record_type(body, merged, source_file: source_file)
          resolved[name] = { allOf: [base_schema, record_schema] }
        end

        resolved
      end

      # Parse the +#:+ method signature annotation above +def call+ into
      # an array of parameter descriptors.
      #
      # The annotation looks like:
      #
      #   #: (name: String @min(1), ?limit: Integer @requires(:admin)) -> Hash[Symbol, untyped]
      #
      # Each parameter becomes a hash with +:name+, +:type+, +:required+,
      # and +:tags+ (parsed via +extract_tags+). The +?+ prefix marks a
      # parameter as optional.
      #
      # @param content [String] Full source file contents.
      # @return [Array<Hash>] Parameter descriptors.
      #: (String, ?source_file: String?) -> Array[Hash[Symbol, untyped]]
      def parse_call_params(content, source_file: nil)
        return [] if content.empty?

        lines = content.lines
        call_idx = lines.index { |l| l =~ /\s*def (self\.)?call\(/ }
        return [] unless call_idx

        annotation = +""
        i = call_idx - 1
        while i >= 0 && lines[i] =~ /^\s*#:/
          annotation.prepend(lines[i].sub(/^\s*#:\s*/, "").strip + " ")
          i -= 1
        end

        params = []
        if annotation =~ /\((.+)\)\s*->/m
          # Bracket-aware split — flat `.split(",")` was breaking on commas
          # inside @desc(...) and on generic types like Hash[Symbol, untyped]
          # where the comma is part of the type-arg list.
          split_at_depth_zero($1.to_s, ",").each do |param|
            param = param.strip
            next if param.empty?

            # Find the field-name/type separator at bracket depth 0 so
            # `flag: Hash[Symbol, untyped]` doesn't get split on the `:`
            # inside a nested record type.
            colon = find_at_depth_zero(param, [":"])
            next unless colon

            raw_key = param[0...colon].to_s.strip
            type = param[(colon + 1)..].to_s.strip
            next if raw_key.empty? || type.empty?

            name, optional = parse_field_name(raw_key, source_file: source_file)
            next if name == "server_context"

            type, tags = extract_tags(type)

            params << {
              name: name,
              type: type,
              required: !optional && !type.end_with?("?"),
              tags: tags
            }
          end
        end

        params
      end

      # ---------------------------------------------------------------
      # Type resolution helpers
      # ---------------------------------------------------------------

      # Convert unresolved aliases into placeholder schemas so that
      # forward references work during record parsing.
      #: (Hash[String, untyped], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
      def aliases_to_schemas(aliases, already_resolved)
        result = {}
        aliases.each do |name, value|
          next if already_resolved.key?(name)
          result[name] = value.is_a?(Hash) ? value : { type: "string" }
        end
        result
      end

      # Parse a bare record type body (e.g. +"{name: String, age: Integer}"+)
      # into a JSON Schema object. Used for both shared .rbs files and
      # inline +# @rbs type+ definitions.
      #
      # @param body [String] Record body including surrounding braces.
      # @param type_map [Hash] Resolved types for reference lookups.
      # @return [Hash] JSON Schema object with +properties+ and +required+.
      #: (String, ?Hash[String, Hash[Symbol, untyped]], ?source_file: String?) -> Hash[Symbol, untyped]
      def parse_record_type(body, type_map = {}, source_file: nil)
        properties = {}
        required = []

        each_field_in_record(body) do |key, type_str|
          type_str, tags = extract_tags(type_str)
          clean_key, optional = parse_field_name(key, source_file: source_file)

          schema = rbs_type_to_json_schema(type_str, type_map, source_file: source_file)
          properties[clean_key.to_sym] = apply_tags(schema, tags)
          required << clean_key unless optional
        end

        schema = { type: "object", properties: properties } #: Hash[Symbol, untyped]
        schema[:required] = required if required.any?
        schema
      end

      # Iterate the fields of a record body, splitting on +,+ at bracket
      # depth 0 (so commas inside +@desc(...)+ or inside nested records
      # don't fragment a field). Yields +key, type_str+ already trimmed
      # for each non-empty field. Outer braces are stripped before
      # iteration.
      #
      # Pre-bracket-aware behavior used +inner.scan(/(\??\w+\??)\s*:\s*([^,}]+)/)+,
      # which silently dropped any field whose type string contained a
      # comma — or worse, split that field at the comma.
      #
      # Strip an RBS line comment (+#+ to end-of-line) from a single line.
      #
      # RBS treats +#+ as a comment marker everywhere outside string
      # literals — the official lexer discards it before parsing. The
      # line-based readers here (+find_raw_type_body+, +parse_type_aliases+,
      # +parse_rbs_file+) concatenate record-body lines *without* a newline
      # separator, so a comment authored inside a record body
      # (+{ # note\n id: String }+) would otherwise fold into the next
      # field name and blow up +parse_field_name+ (issue #20).
      #
      # We scan character by character so a +#+ inside a string literal or
      # inside a bracketed annotation value (e.g. +@desc(a # b)+) is left
      # untouched; only a +#+ at bracket depth 0 outside any string starts
      # a comment.
      #: (String) -> String
      def strip_rbs_comment(line)
        depth = 0
        in_string = nil #: String?

        line.each_char.with_index do |ch, i|
          if in_string
            in_string = nil if ch == in_string
          elsif ch == '"' || ch == "'"
            in_string = ch
          elsif ch == "(" || ch == "[" || ch == "{"
            depth += 1
          elsif ch == ")" || ch == "]" || ch == "}"
            depth -= 1
          elsif ch == "#" && depth <= 0
            return line[0...i].to_s.rstrip
          end
        end

        line
      end

      #: (String) { (String, String) -> void } -> void
      def each_field_in_record(body)
        inner = body.strip.sub(/\A\{/, "").sub(/\}\z/, "").strip
        return if inner.empty?

        split_at_depth_zero(inner, ",").each do |field|
          field = field.strip
          next if field.empty?

          colon = find_at_depth_zero(field, [":"])
          next unless colon

          key = field[0...colon].to_s.strip
          type_str = field[(colon + 1)..].to_s.strip
          next if key.empty? || type_str.empty?

          yield key, type_str
        end
      end

      # Convert a single RBS type expression into its JSON Schema equivalent.
      #
      # Handles:
      # - Primitives: +String+ → +{type: "string"}+, +Integer+ → +{type: "integer"}+, etc.
      # - Arrays: +Array[String]+ → +{type: "array", items: {type: "string"}}+
      # - Optionals: +String?+ → +{type: "string"}+ (nullability is handled at the field level)
      # - Inline records: +{name: String}+ → nested object schema
      # - Unions: +"a" | "b"+ → string enum; +A | B+ → +oneOf+
      # - Named types: looked up in +type_map+, falling back to +{type: "string"}+
      #
      # @param rbs_type [String] RBS type expression.
      # @param type_map [Hash] Resolved type definitions for named type lookups.
      # @return [Hash] JSON Schema hash.
      #: (String, ?Hash[String, Hash[Symbol, untyped]], ?source_file: String?, ?rctx: Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def rbs_type_to_json_schema(rbs_type, type_map = {}, source_file: nil, rctx: nil)
        stripped = rbs_type.strip
        return { type: "string" } if stripped.empty?

        # Special case preserved for backward compat with the previous
        # regex parser: "TrueClass | FalseClass" was recognized as a
        # boolean shorthand. RBS would parse it as Union[ClassInstance,
        # ClassInstance], which we'd otherwise turn into a oneOf.
        return { type: "boolean" } if stripped == "TrueClass | FalseClass"

        begin
          ast = RBS::Parser.parse_type(stripped, require_eof: true)
        rescue RBS::ParsingError
          # Unparseable — fall back to type_map lookup or string.
          return type_map[stripped] || { type: "string" }
        end

        visit_rbs_type(ast, type_map, rctx)
      end

      # AST visitor: convert an +RBS::Types::*+ node into JSON Schema.
      #
      # Replaces the prior regex case-statement parser with a delegation
      # to the official rbs gem. Each node type maps onto a small JSON
      # Schema fragment. Named types (+RBS::Types::Alias+, unknown
      # +ClassInstance+) are looked up in +type_map+, preserving the
      # gem's named-type indirection for shared and inline aliases.
      #
      # @param node [RBS::Types::t] AST node from +RBS::Parser.parse_type+.
      # @param type_map [Hash] Resolved named-type definitions.
      # @return [Hash] JSON Schema fragment.
      #: (untyped, Hash[String, Hash[Symbol, untyped]], ?Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def visit_rbs_type(node, type_map, rctx = nil)
        case node
        when RBS::Types::Bases::Bool
          { type: "boolean" }
        when RBS::Types::Bases::Any, RBS::Types::Bases::Void, RBS::Types::Bases::Nil
          # untyped / void / nil → no constraint (LLM can pass anything).
          # The empty schema {} is JSON Schema's "any value"; emitting a
          # concrete type here (e.g. {type: "string"}) silently rejects
          # objects/arrays at tools/call — see issue #22. In particular
          # Hash[K, untyped] becomes {type: "object", additionalProperties: {}}
          # (any property value allowed) rather than forcing string values.
          {}
        when RBS::Types::Literal
          visit_rbs_literal(node)
        when RBS::Types::Optional
          # Optional wraps a type; nullability is handled at field
          # level (required-set), not in the JSON Schema type itself.
          visit_rbs_type(node.type, type_map, rctx)
        when RBS::Types::Union
          visit_rbs_union(node, type_map, rctx)
        when RBS::Types::Intersection
          # A & B → allOf. Lets a field reuse a shared base type plus extra
          # constraints; mirrors the alias-level intersection handled by
          # collect_rbs_file_aliases / resolve_collected_aliases.
          { allOf: node.types.map { |t| visit_rbs_type(t, type_map, rctx) } }
        when RBS::Types::Record
          visit_rbs_record(node, type_map, rctx)
        when RBS::Types::Tuple
          # RBS tuples have heterogeneous element types; JSON Schema's
          # closest analog is array with prefixItems, but for simplicity
          # we project to a plain array.
          { type: "array" }
        when RBS::Types::ClassInstance
          visit_rbs_class_instance(node, type_map, rctx)
        when RBS::Types::Alias
          name = node.name.to_s.sub(/\A::/, "")
          resolve_named_type(name, type_map, rctx, { type: "string" })
        else
          # Interface, Proc, Variable, ClassSingleton, Bases::Self/Class/Instance/Top/Bottom etc.
          { type: "string" }
        end
      end

      # Map +RBS::Types::ClassInstance+ to JSON Schema. Recognizes the
      # Ruby primitives we care about (+String+, +Integer+, +Float+),
      # generic +Array[T]+ / +Hash[K, V]+, and falls back to the
      # +type_map+ for user-defined names.
      #: (untyped, Hash[String, Hash[Symbol, untyped]], ?Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def visit_rbs_class_instance(node, type_map, rctx = nil)
        name = node.name.to_s.sub(/\A::/, "")
        case name
        when "String"
          { type: "string" }
        when "Integer"
          { type: "integer" }
        when "Float", "Numeric"
          { type: "number" }
        when "TrueClass"
          { type: "boolean", const: true }
        when "FalseClass"
          { type: "boolean", const: false }
        when "Array"
          inner = node.args.first
          inner ? { type: "array", items: visit_rbs_type(inner, type_map, rctx) } : { type: "array" }
        when "Hash"
          # Hash[K, V] — JSON Schema can express V as additionalProperties.
          val = node.args[1]
          val ? { type: "object", additionalProperties: visit_rbs_type(val, type_map, rctx) } : { type: "object" }
        when "Symbol"
          { type: "string" }
        when "NilClass"
          { type: "string" }
        else
          resolve_named_type(name, type_map, rctx, { type: "string" })
        end
      end

      # Map a +RBS::Types::Literal+ to a JSON Schema +const+ fragment.
      # In a union of literals this becomes part of an +enum+; see
      # +visit_rbs_union+ for that aggregation.
      #: (untyped) -> Hash[Symbol, untyped]
      def visit_rbs_literal(node)
        case node.literal
        when true  then { type: "boolean", const: true }
        when false then { type: "boolean", const: false }
        when String then { type: "string", const: node.literal }
        when Symbol then { type: "string", const: node.literal.to_s }
        when Integer then { type: "integer", const: node.literal }
        else { type: "string", const: node.literal.to_s }
        end
      end

      # Map +RBS::Types::Union+ to JSON Schema. A union of string
      # literals becomes a +{type: "string", enum: [...]}+; any other
      # mix becomes +{oneOf: [...]}+. This mirrors the prior regex
      # parser's behavior so existing schemas don't drift.
      #: (untyped, Hash[String, Hash[Symbol, untyped]], ?Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def visit_rbs_union(node, type_map, rctx = nil)
        types = node.types

        # All string literals → enum.
        if types.all? { |t| t.is_a?(RBS::Types::Literal) && t.literal.is_a?(String) }
          return { type: "string", enum: types.map { |t| t.literal.to_s } }
        end

        # TrueClass | FalseClass → boolean. RBS doesn't have a single
        # "boolean" base class, so this pattern is what users write.
        if types.size == 2 &&
           types.all? { |t| t.is_a?(RBS::Types::ClassInstance) } &&
           types.map { |t| t.name.to_s.sub(/\A::/, "") }.sort == %w[FalseClass TrueClass]
          return { type: "boolean" }
        end

        { oneOf: types.map { |t| visit_rbs_type(t, type_map, rctx) } }
      end

      # Map +RBS::Types::Record+ to a JSON Schema object. RBS handles
      # +?key:+ optional markers natively — they land in
      # +node.optional_fields+ rather than +node.fields+. No need for
      # us to parse the marker manually.
      #
      # NOTE: this path is used when a record appears nested inside
      # another type expression (e.g. +Array[{name: String}]+). Top-level
      # records reached via +# @rbs type input = { ... }+ go through
      # +compile_tagged_record+ instead so per-field tag extraction can
      # happen before the type is parsed.
      #: (untyped, Hash[String, Hash[Symbol, untyped]], ?Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def visit_rbs_record(node, type_map, rctx = nil)
        properties = {}
        required = []

        node.fields.each do |name, type|
          key = name.to_s
          properties[key.to_sym] = visit_rbs_type(type, type_map, rctx)
          required << key
        end
        node.optional_fields.each do |name, type|
          properties[name.to_s.to_sym] = visit_rbs_type(type, type_map, rctx)
        end

        schema = { type: "object", properties: properties } #: Hash[Symbol, untyped]
        schema[:required] = required if required.any?
        schema
      end

      # Look up a named type in the type map. Returns a bare +{type: "object"}+
      # if the name is not found (defensive fallback).
      #: (String, Hash[String, Hash[Symbol, untyped]], ?Hash[Symbol, untyped]?) -> Hash[Symbol, untyped]
      def resolve_type(name, type_map, rctx = nil)
        resolve_named_type(name, type_map, rctx, { type: "object" })
      end

      # Wrap a partial schema (with +properties+, +required+, etc.) in a
      # top-level +{type: "object", ...}+ envelope.
      #: (Hash[Symbol, untyped]) -> Hash[Symbol, untyped]
      def build_input_schema(types)
        { type: "object" }.merge(types)
      end

      # Locate the source file for a handler class by inspecting
      # +Method#source_location+ on its +#call+ method. This is how the
      # compiler finds the RBS annotations to parse.
      #
      # When host applications wrap +#call+ via +prepend+ (param coercion,
      # instrumentation, error mapping, ActiveSupport::Concern patterns,
      # observability libraries), +source_location+ on the topmost method
      # points at the wrapper, not the handler. Walk +super_method+ down
      # past prepended modules until we find the handler's own definition.
      #
      # @param handler_class [Class]
      # @return [String, nil] Absolute file path, or nil.
      #: (untyped) -> String?
      def find_source_file(handler_class)
        um = if handler_class.method_defined?(:call) || handler_class.private_method_defined?(:call)
          handler_class.instance_method(:call)
        elsif handler_class.respond_to?(:call)
          handler_class.method(:call)
        end
        return nil unless um

        while um.owner != handler_class && um.super_method
          um = um.super_method
        end

        um.source_location&.first
      end

      # Check whether a string has balanced curly braces. Used to detect
      # the end of multi-line record type definitions.
      #: (String) -> bool
      def brace_balanced?(str)
        str.count("{") == str.count("}")
      end

      # Parse a string literal union from handler source comments, either
      # written on one line:
      #   # @rbs type logic = "AND" | "OR"
      # or continued across multiple lines:
      #   # @rbs type priority = "low"
      #   #                    | "medium"
      #   #                    | "high"
      #
      # +first_segment+ is everything captured after the +=+ on the
      # opening line, which may itself already contain the full
      # +"a" | "b" | "c"+ union — a single-line union has no continuation
      # lines, so capturing only its first quoted literal (the prior
      # behavior) silently dropped every member after the first.
      #
      # @return [Hash] +{type: "string", enum: ["low", "medium", "high"]}+
      #: (String, String, String) -> Hash[Symbol, untyped]
      def parse_string_union(first_segment, line, content)
        values = first_segment.scan(/"([^"]*)"/).flatten
        content.each_line.drop_while { |l| l != line }.drop(1).each do |next_line|
          if next_line =~ /^\s*#\s*\|\s*"([^"]+)"/
            values << $1.to_s
          else
            break
          end
        end
        { type: "string", enum: values }
      end

      # ---------------------------------------------------------------
      # $ref / $defs optimization
      #
      # When a named type (e.g. "address") appears in multiple places in
      # the compiled schema, inlining it everywhere wastes tokens. This
      # pass detects multi-use types, hoists them into a top-level $defs
      # block, and replaces inline occurrences with $ref pointers:
      #
      #   { "$ref": "#/$defs/address" }
      #
      # Single-use types are left inlined — the $ref overhead isn't worth
      # it for types that only appear once.
      # ---------------------------------------------------------------

      # Wrap a compiled schema with +$defs+ for named types that appear
      # more than once. Returns the schema unchanged if no deduplication
      # is worthwhile.
      #
      # @param schema [Hash] Compiled JSON Schema.
      # @param type_map [Hash] Named type definitions.
      # @return [Hash] Schema, possibly with +$defs+ added.
      #: (Hash[Symbol, untyped], Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
      def with_ref_injection(schema, type_map)
        return schema unless schema.is_a?(Hash)

        # Build lookup of named types that are non-trivial schemas (worth deduplicating)
        type_schemas = {}
        type_map.each do |name, type_schema|
          next unless type_schema.is_a?(Hash) && type_schema.size > 1
          type_schemas[name] = type_schema
        end
        return schema if type_schemas.empty?

        usage = Hash.new(0)
        count_usages(schema, type_schemas, usage)

        multi = usage.select { |_, c| c > 1 }
        return schema if multi.empty?

        replaced = deep_replace(schema, multi, type_schemas)

        # Ref-inject *within* each hoisted def too: a def's body may itself
        # contain another multi-use type (e.g. a shared base that inlines a
        # template referenced elsewhere). Replace those with $ref — excluding
        # the def's own name so a body never self-references — so each shared
        # type is spelled out once in $defs rather than re-inlined inside
        # another def. Without this, hoisting a large base left the base's
        # nested types inlined AND duplicated as unreferenced defs.
        defs = {}
        multi.each_key do |name|
          others = multi.reject { |k, _| k == name }
          defs[name] = deep_replace(type_schemas[name], others, type_schemas)
        end

        # Drop defs that nothing references (transitively from the main
        # schema). Hoisting can orphan a type whose every occurrence ended up
        # inside another def that was itself replaced by a $ref.
        defs = prune_unreferenced_defs(replaced, defs)

        replaced[:"$defs"] = defs unless defs.empty?
        replaced
      end

      # Names of +$defs+ reachable (transitively) from +root+. Used to drop
      # hoisted-but-unreferenced defs.
      #: (Hash[Symbol, untyped], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
      def prune_unreferenced_defs(root, defs)
        reachable = [] #: Array[String]
        frontier = referenced_def_names(root)
        until frontier.empty?
          name = frontier.shift
          next if reachable.include?(name)
          reachable << name
          referenced_def_names(defs[name]).each { |n| frontier << n } if defs[name]
        end
        defs.select { |name, _| reachable.include?(name) }
      end

      # Collect every +#/$defs/<name>+ target referenced anywhere in +node+.
      #: (untyped) -> Array[String]
      def referenced_def_names(node)
        names = [] #: Array[String]
        stack = [node] #: Array[untyped]
        until stack.empty?
          n = stack.pop
          case n
          when Hash
            n.each do |k, v|
              if (k == :"$ref" || k == "$ref") && v.is_a?(String)
                names << v.split("/").last.to_s
              else
                stack << v
              end
            end
          when Array
            n.each { |e| stack << e }
          end
        end
        names
      end

      # Walk the schema tree and count how many times each named type's
      # schema appears as a value. Only types with count > 1 are worth
      # extracting into +$defs+.
      #: (Hash[Symbol, untyped], Hash[String, Hash[Symbol, untyped]], Hash[String, Integer]) -> void
      def count_usages(schema, type_schemas, usage)
        return unless schema.is_a?(Hash)

        type_schemas.each do |name, ts|
          usage[name] += 1 if schema == ts
        end

        schema[:properties]&.each_value { |v| count_usages(v, type_schemas, usage) }
        count_usages(schema[:items], type_schemas, usage) if schema[:items].is_a?(Hash)
        [:oneOf, :anyOf, :allOf].each do |k|
          schema[k]&.each { |s| count_usages(s, type_schemas, usage) }
        end
      end

      # Recursively replace occurrences of multi-use named type schemas
      # with +{"$ref": "#/$defs/<name>"}+ pointers. Walks +properties+,
      # +items+, +oneOf+, +anyOf+, and +allOf+.
      #: (Hash[Symbol, untyped], Hash[String, Integer], Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
      def deep_replace(schema, targets, type_schemas)
        return schema unless schema.is_a?(Hash)

        type_schemas.each do |name, ts|
          if targets.key?(name) && schema == ts
            return { "$ref": "#/$defs/#{name}" }
          end
        end

        result = {}
        schema.each do |key, value|
          result[key] = case key
          when :properties
            value.transform_values { |v| deep_replace(v, targets, type_schemas) }
          when :items
            deep_replace(value, targets, type_schemas)
          when :oneOf, :anyOf, :allOf
            value.map { |s| deep_replace(s, targets, type_schemas) }
          else
            value
          end
        end
        result
      end
    end
  end
end
