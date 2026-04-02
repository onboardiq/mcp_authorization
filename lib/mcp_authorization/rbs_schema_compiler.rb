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

        schema = if cached[:raw_input]&.dig(:kind) == :record
          compile_tagged_record(cached[:raw_input][:body], cached[:type_map], server_context)
        else
          build_input_schema(
            filter_call_signature(cached[:call_params], cached[:type_map], server_context)
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
          schema = compile_tagged_union(cached[:raw_output][:body], cached[:type_map], server_context)
          schema = with_ref_injection(schema, cached[:type_map])
          return McpAuthorization.config.strict_schema ? strict_sanitize(schema) : schema
        end
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
      #   @requires(:symbol)      -> { requires: :symbol }
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
      #: (String) -> [String, Hash[Symbol, untyped]]
      def extract_tags(type_str)
        tags = {}

        # Extract all @tag(...) annotations from right to left
        while type_str =~ /\A(.+?)\s+@(\w+)\(([^)]*)\)\s*\z/
          type_str, tag_name, tag_value = $1.to_s.strip, $2.to_s, $3.to_s

          case tag_name
          when "requires"
            tags[:requires] = tag_value.delete_prefix(":").to_sym
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
          end
        end

        [type_str, tags]
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

        # Build type map: shared imports first, then handler's own types override
        imported = load_imports(content)
        local = parse_type_aliases(content)
        type_map = imported.merge(local)

        {
          type_map: type_map,
          raw_input: find_raw_type_body(content, "input"),
          raw_output: find_raw_type_body(content, "output"),
          call_params: parse_call_params(content),
          source_file: source_file
        }
      end

      # ---------------------------------------------------------------
      # @requires filtering — the per-request compile phase
      # ---------------------------------------------------------------

      # Compile a record-style input type (+# @rbs type input = { ... }+)
      # with field-level +@requires+ filtering.
      #
      # Fields whose +@requires+ flag the current user lacks are silently
      # omitted from the resulting JSON Schema, so the LLM never sees them.
      #
      # @param raw_body [String] The raw record body, e.g. +"{name: String, force: bool @requires(:admin)}"+.
      # @param type_map [Hash] Resolved type definitions for +$ref+ lookups.
      # @param server_context [Object] Per-request context with +current_user+.
      # @return [Hash] JSON Schema object with +properties+, +required+, etc.
      #: (String, Hash[String, Hash[Symbol, untyped]], untyped) -> Hash[Symbol, untyped]
      def compile_tagged_record(raw_body, type_map, server_context)
        properties = {}
        required = []
        dependent_required = {}

        inner = raw_body.strip.sub(/\A\{/, "").sub(/\}\z/, "").strip

        inner.scan(/(\w+\??)\s*:\s*([^,}]+)/) do |match|
          key, type_str = match[0].to_s, match[1].to_s
          type_str, tags = extract_tags(type_str.strip)

          next if tags[:requires] && !server_context.current_user.can?(tags[:requires])

          optional = key.end_with?("?")
          clean_key = key.delete_suffix("?")

          schema = rbs_type_to_json_schema(type_str, type_map)
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

      # Compile a union-style output type (+# @rbs type output = success | admin_detail @requires(:admin)+)
      # with variant-level +@requires+ filtering.
      #
      # Each union variant (separated by +|+) can carry its own +@requires+
      # tag. Variants the user lacks permission for are dropped entirely.
      # If only one variant remains, it's returned directly (no +oneOf+
      # wrapper). If zero remain, a bare +{type: "object"}+ fallback is used.
      #
      # @param raw_expr [String] The raw union expression.
      # @param type_map [Hash] Resolved type definitions.
      # @param server_context [Object] Per-request context.
      # @return [Hash] JSON Schema — either a single schema or a +oneOf+ wrapper.
      #: (String, Hash[String, Hash[Symbol, untyped]], untyped) -> Hash[Symbol, untyped]
      def compile_tagged_union(raw_expr, type_map, server_context)
        parts = raw_expr.split("|").map(&:strip).reject(&:empty?)

        filtered = parts.filter_map do |part|
          part, tags = extract_tags(part)
          next nil if tags[:requires] && !server_context.current_user.can?(tags[:requires])
          resolve_type(part, type_map)
        end

        case filtered.size
        when 0 then { type: "object" }
        when 1 then filtered.first
        else { type: "object", oneOf: filtered }
        end
      end

      # Filter method-signature parameters by +@requires+ tags and build
      # the input JSON Schema. This is the path used when the handler defines
      # its schema via a +#:+ annotation above +def call+ rather than an
      # explicit +# @rbs type input = { ... }+.
      #
      # @param call_params [Array<Hash>] Parsed parameter descriptors from +parse_call_params+.
      # @param type_map [Hash] Resolved type definitions.
      # @param server_context [Object] Per-request context.
      # @return [Hash] Partial JSON Schema (+properties+, +required+, etc.).
      #: (Array[Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]], untyped) -> Hash[Symbol, untyped]
      def filter_call_signature(call_params, type_map, server_context)
        properties = {}
        required = []
        dependent_required = {}

        call_params.each do |param|
          if param[:tags][:requires] && server_context
            next unless server_context.current_user.can?(param[:tags][:requires])
          end

          schema = rbs_type_to_json_schema(param[:type], type_map)
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

      # Parse a shared +.rbs+ file with mtime-based caching. If the file
      # hasn't changed since the last parse, the cached result is returned.
      #
      # @param path [String] Absolute path to the +.rbs+ file.
      # @return [Hash{String => Hash}] Type name → JSON Schema map.
      #: (String) -> Hash[String, Hash[Symbol, untyped]]
      def cached_parse_rbs_file(path)
        mtime = File.mtime(path)
        cached = shared_type_cache[path]

        if cached && cached[:mtime] == mtime
          return cached[:result]
        end

        result = parse_rbs_file(path)
        shared_type_cache[path] = { mtime: mtime, result: result }
        result
      end

      # Resolve a bare import name (e.g. +"common_types"+) to an absolute
      # +.rbs+ file path by searching +shared_type_paths+.
      #
      # @param import_path [String] Bare import name without extension.
      # @return [String, nil] Absolute file path, or nil if not found.
      #: (String) -> String?
      def resolve_import_path(import_path)
        return nil unless defined?(Rails)

        McpAuthorization.config.shared_type_paths.each do |base|
          candidate = Rails.root.join(base, "#{import_path}.rbs")
          return candidate.to_s if File.exist?(candidate)
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
        content = File.read(path)
        aliases = {}
        current_name = nil #: String?
        current_body = +""

        content.each_line do |line|
          stripped = line.strip

          if stripped =~ /\Atype (\w+) = \{/
            current_name = $1.to_s
            current_body = "{"
          elsif stripped =~ /\Atype (\w+) = "([^"]+)"/
            aliases[$1.to_s] = parse_rbs_string_union($2.to_s, line, content)
          elsif current_name
            current_body << stripped
            if brace_balanced?(current_body)
              aliases[current_name] = current_body
              current_name = nil
              current_body = +""
            end
          end
        end

        resolved = {}
        aliases.each do |name, value|
          resolved[name] = if value.is_a?(String)
            parse_record_type(value, resolved.merge(aliases_to_schemas(aliases, resolved)))
          else
            value
          end
        end
        resolved
      end

      # Parse a multi-line string literal union from an .rbs file:
      #   type priority = "low"
      #                 | "medium"
      #                 | "high"
      #
      # @return [Hash] +{type: "string", enum: ["low", "medium", "high"]}+
      #: (String, String, String) -> Hash[Symbol, untyped]
      def parse_rbs_string_union(first_value, line, content)
        values = [first_value]
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
              stripped = next_line.strip.sub(/^#\s*/, "")
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
      #: (String) -> Hash[String, Hash[Symbol, untyped]]
      def parse_type_aliases(content)
        return {} if content.empty?

        aliases = {}
        current_name = nil #: String?
        current_body = +""

        content.each_line do |line|
          if line =~ /# @rbs type (\w+) = \{/
            current_name = $1.to_s
            current_body = "{"
          elsif line =~ /# @rbs type (\w+) = "([^"]+)"/
            aliases[$1.to_s] = parse_string_union($2.to_s, line, content)
          elsif current_name
            stripped = line.strip.sub(/^#\s*/, "")
            current_body << stripped
            if brace_balanced?(current_body)
              aliases[current_name] = current_body
              current_name = nil
              current_body = +""
            end
          end
        end

        resolved = {}
        aliases.each do |name, value|
          resolved[name] = if value.is_a?(String)
            parse_record_type(value, resolved.merge(aliases_to_schemas(aliases, resolved)))
          else
            value
          end
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
      #: (String) -> Array[Hash[Symbol, untyped]]
      def parse_call_params(content)
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
          $1.to_s.split(",").each do |param|
            param = param.strip
            next unless param =~ /\A(\?)?([\w]+):\s*(.+)\z/
            opt, name, type = $1, $2.to_s, $3.to_s.strip
            next if name == "server_context"

            type, tags = extract_tags(type)

            params << {
              name: name,
              type: type,
              required: opt.nil? && !type.end_with?("?"),
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
      #: (String, ?Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
      def parse_record_type(body, type_map = {})
        properties = {}
        required = []

        inner = body.strip.sub(/\A\{/, "").sub(/\}\z/, "").strip

        inner.scan(/(\w+):\s*([^,}]+)/) do |match|
          key, type_str = match[0].to_s, match[1].to_s
          type_str, tags = extract_tags(type_str.strip)
          optional = key.end_with?("?")
          clean_key = key.delete_suffix("?")

          schema = rbs_type_to_json_schema(type_str, type_map)
          properties[clean_key.to_sym] = apply_tags(schema, tags)
          required << clean_key unless optional
        end

        schema = { type: "object", properties: properties } #: Hash[Symbol, untyped]
        schema[:required] = required if required.any?
        schema
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
      #: (String, ?Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
      def rbs_type_to_json_schema(rbs_type, type_map = {})
        stripped = rbs_type.strip
        case stripped
        when "String"
          { type: "string" }
        when "Integer"
          { type: "integer" }
        when "Float"
          { type: "number" }
        when "bool", "TrueClass | FalseClass"
          { type: "boolean" }
        when "true"
          { type: "boolean", const: true }
        when "false"
          { type: "boolean", const: false }
        when /\AArray\[(.+)\]\z/
          { type: "array", items: rbs_type_to_json_schema($1.to_s, type_map) }
        when /\A(\w+)\?\z/
          rbs_type_to_json_schema($1.to_s, type_map)
        when /\A\{/
          parse_record_type(stripped, type_map)
        when /\|/
          parts = stripped.split("|").map(&:strip)
          if parts.all? { |p| p.start_with?('"') && p.end_with?('"') }
            { type: "string", enum: parts.map { |p| p.delete('"') } }
          else
            { oneOf: parts.map { |p| rbs_type_to_json_schema(p, type_map) } }
          end
        else
          type_map[stripped] || { type: "string" }
        end
      end

      # Look up a named type in the type map. Returns a bare +{type: "object"}+
      # if the name is not found (defensive fallback).
      #: (String, Hash[String, Hash[Symbol, untyped]]) -> Hash[Symbol, untyped]
      def resolve_type(name, type_map)
        type_map[name] || { type: "object" }
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
      # @param handler_class [Class]
      # @return [String, nil] Absolute file path, or nil.
      #: (untyped) -> String?
      def find_source_file(handler_class)
        if handler_class.method_defined?(:call)
          handler_class.instance_method(:call).source_location&.first
        elsif handler_class.respond_to?(:call)
          handler_class.method(:call).source_location&.first
        end
      end

      # Check whether a string has balanced curly braces. Used to detect
      # the end of multi-line record type definitions.
      #: (String) -> bool
      def brace_balanced?(str)
        str.count("{") == str.count("}")
      end

      # Parse a multi-line string literal union from handler source comments:
      #   # @rbs type priority = "low"
      #   #                    | "medium"
      #   #                    | "high"
      #
      # @return [Hash] +{type: "string", enum: ["low", "medium", "high"]}+
      #: (String, String, String) -> Hash[Symbol, untyped]
      def parse_string_union(first_value, line, content)
        values = [first_value]
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

        defs = {}
        multi.each_key { |name| defs[name] = type_schemas[name] }

        replaced = deep_replace(schema, multi, type_schemas)
        replaced[:"$defs"] = defs
        replaced
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
