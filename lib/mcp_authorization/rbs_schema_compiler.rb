module McpAuthorization
  class RbsSchemaCompiler
    class << self
      # Compile input params — tries @rbs type input first, then legacy rbs_signature
      def compile_input(handler_class, server_context:)
        type_map = parse_type_aliases(handler_class)

        raw = find_raw_type_body(handler_class, "input")
        if raw && raw[:kind] == :record
          return compile_tagged_record(raw[:body], type_map, server_context)
        end

        if handler_class.respond_to?(:rbs_signature)
          sig_name = handler_class.rbs_signature(server_context: server_context)
          input_types = type_map[sig_name] || parse_call_signature(handler_class, type_map)
          return build_input_schema(input_types)
        end

        build_input_schema(parse_call_signature(handler_class, type_map))
      end

      # Compile output schema — tries @rbs type output first, then legacy rbs_output_signature
      def compile_output(handler_class, server_context:)
        type_map = parse_type_aliases(handler_class)

        raw = find_raw_type_body(handler_class, "output")
        if raw && raw[:kind] == :union
          return compile_tagged_union(raw[:body], type_map, server_context)
        end

        if handler_class.respond_to?(:rbs_output_signature)
          sig_expr = handler_class.rbs_output_signature(server_context: server_context)
          parts = sig_expr.split("|").map(&:strip)
          if parts.size > 1
            schemas = parts.map { |part| resolve_type(part, type_map) }
            return { type: "object", oneOf: schemas }
          else
            return resolve_type(parts.first, type_map)
          end
        end
      end

      private

      # --- Tagged type support (@requires) ---

      # Extract the raw body of a named @rbs type from source, preserving @requires tags
      def find_raw_type_body(handler_class, type_name)
        source_file = find_source_file(handler_class)
        return nil unless source_file && File.exist?(source_file)

        lines = File.read(source_file).lines
        pattern = Regexp.escape(type_name)

        lines.each_with_index do |line, idx|
          # Record type: # @rbs type name = {
          if line =~ /# @rbs type #{pattern} = \{/
            body = "{"
            lines[(idx + 1)..].each do |next_line|
              stripped = next_line.strip.sub(/^#\s*/, "")
              body << stripped
              return { kind: :record, body: body } if brace_balanced?(body)
            end

          # Union or reference: # @rbs type name = something (not a brace)
          elsif line =~ /# @rbs type #{pattern} = ([^{].+)/
            expr = $1.strip
            lines[(idx + 1)..].each do |next_line|
              if next_line =~ /^\s*#\s*\|\s*(.+)/
                expr += " | " + $1.strip
              else
                break
              end
            end
            return { kind: :union, body: expr }
          end
        end

        nil
      end

      # Parse a record type with field-level @requires filtering
      def compile_tagged_record(raw_body, type_map, server_context)
        properties = {}
        required = []

        inner = raw_body.strip.sub(/\A\{/, "").sub(/\}\z/, "").strip

        inner.scan(/(\w+\??)\s*:\s*([^,}]+)/) do |key, type_str|
          type_str = type_str.strip

          perm = nil
          if type_str =~ /\A(.+?)\s+@requires\(:(\w+)\)\s*\z/
            type_str = $1.strip
            perm = $2.to_sym
          end

          next if perm && !server_context.current_user.can?(perm)

          optional = key.end_with?("?")
          clean_key = key.delete_suffix("?")

          properties[clean_key.to_sym] = rbs_type_to_json_schema(type_str, type_map)
          required << clean_key unless optional
        end

        schema = { type: "object", properties: properties }
        schema[:required] = required if required.any?
        schema
      end

      # Parse a union expression with variant-level @requires filtering
      def compile_tagged_union(raw_expr, type_map, server_context)
        parts = raw_expr.split("|").map(&:strip).reject(&:empty?)

        filtered = parts.filter_map do |part|
          perm = nil
          if part =~ /\A(.+?)\s+@requires\(:(\w+)\)\s*\z/
            part = $1.strip
            perm = $2.to_sym
          end

          next nil if perm && !server_context.current_user.can?(perm)
          resolve_type(part, type_map)
        end

        case filtered.size
        when 0 then { type: "object" }
        when 1 then filtered.first
        else { type: "object", oneOf: filtered }
        end
      end

      # --- Existing type alias parsing ---

      # Parse @rbs type aliases from the handler's source file
      def parse_type_aliases(handler_class)
        source_file = find_source_file(handler_class)
        return {} unless source_file && File.exist?(source_file)

        content = File.read(source_file)
        aliases = {}
        current_name = nil
        current_body = +""

        content.each_line do |line|
          if line =~ /# @rbs type (\w+) = \{/
            current_name = $1
            current_body = "{"
          elsif line =~ /# @rbs type (\w+) = "([^"]+)"/
            aliases[$1] = parse_string_union($2, line, content)
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

        # Second pass: resolve all record types with access to the full alias map
        resolved = {}
        aliases.each do |name, value|
          resolved[name] = if value.is_a?(String)
            parse_record_type(value, resolved.merge(aliases_to_schemas(aliases, resolved)))
          else
            value # already a schema (e.g., string enum)
          end
        end
        resolved
      end

      # Convert raw alias values to schemas for resolution
      def aliases_to_schemas(aliases, already_resolved)
        result = {}
        aliases.each do |name, value|
          next if already_resolved.key?(name)
          result[name] = value.is_a?(Hash) ? value : { type: "string" }
        end
        result
      end

      # Parse a record type like { key: Type, key2: Type2 } into JSON Schema
      def parse_record_type(body, type_map = {})
        properties = {}
        required = []

        inner = body.strip.sub(/\A\{/, "").sub(/\}\z/, "").strip

        inner.scan(/(\w+):\s*([^,}]+)/) do |key, type_str|
          type_str = type_str.strip.gsub(/\s*@requires\(:[^)]+\)/, "")
          optional = key.end_with?("?")
          clean_key = key.delete_suffix("?")

          properties[clean_key.to_sym] = rbs_type_to_json_schema(type_str, type_map)
          required << clean_key unless optional
        end

        schema = { type: "object", properties: properties }
        schema[:required] = required if required.any?
        schema
      end

      # Convert an RBS type expression to JSON Schema, resolving alias references
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
          { type: "array", items: rbs_type_to_json_schema($1, type_map) }
        when /\A(\w+)\?\z/
          rbs_type_to_json_schema($1, type_map)
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
          # Check if it's a type alias reference
          type_map[stripped] || { type: "string" }
        end
      end

      def resolve_type(name, type_map)
        type_map[name] || { type: "object" }
      end

      def build_input_schema(types)
        { type: "object" }.merge(types)
      end

      def find_source_file(handler_class)
        method = handler_class.method(:call) rescue nil
        method&.source_location&.first
      end

      def brace_balanced?(str)
        str.count("{") == str.count("}")
      end

      def parse_string_union(first_value, line, content)
        values = [first_value]
        content.each_line.drop_while { |l| l != line }.drop(1).each do |next_line|
          if next_line =~ /^\s*#\s*\|\s*"([^"]+)"/
            values << $1
          else
            break
          end
        end
        { type: "string", enum: values }
      end

      def parse_call_signature(handler_class, type_map = {})
        source_file = find_source_file(handler_class)
        return {} unless source_file

        content = File.read(source_file)
        properties = {}
        required = []

        # Match multiline #: annotations above def self.call
        lines = content.lines
        call_idx = lines.index { |l| l =~ /\s*def self\.call\(/ }
        if call_idx
          annotation = +""
          i = call_idx - 1
          while i >= 0 && lines[i] =~ /^\s*#:/
            annotation.prepend(lines[i].sub(/^\s*#:\s*/, "").strip + " ")
            i -= 1
          end

          if annotation =~ /\((.+)\)\s*->/m
            params_str = $1
            params_str.scan(/(\?)?([\w]+):\s*([^,)]+)/) do |opt, name, type|
              next if name == "server_context"
              type = type.strip
              properties[name.to_sym] = rbs_type_to_json_schema(type, type_map)
              required << name if opt.nil? && !type.end_with?("?")
            end
          end
        end

        schema = { properties: properties }
        schema[:required] = required if required.any?
        schema
      end
    end
  end
end
