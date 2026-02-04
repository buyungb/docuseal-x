# frozen_string_literal: true

require 'docx'
require 'tempfile'
require 'nokogiri'
require 'zip'

module Templates
  module ProcessDocxVariables
    # Simple variable pattern: [[variable_name]]
    SIMPLE_VAR_REGEX = /\[\[(\w+)\]\]/

    # Conditional patterns: [[if:var]]...[[else]]...[[end]] or [[if:var]]...[[end]]
    CONDITIONAL_START_REGEX = /\[\[if:(\w+)\]\]/
    CONDITIONAL_ELSE_REGEX = /\[\[else\]\]/
    CONDITIONAL_END_REGEX = /\[\[end(?::\w+)?\]\]/

    # Loop pattern: [[for:items]]...[[end]]
    LOOP_START_REGEX = /\[\[for:(\w+)\]\]/
    LOOP_END_REGEX = /\[\[end(?::\w+)?\]\]/

    # Item accessor pattern: [[item.property]]
    ITEM_ACCESSOR_REGEX = /\[\[(\w+)\.(\w+)\]\]/

    module_function

    # Process a DOCX file with variables and return the modified DOCX as binary data
    def call(docx_data, variables = {})
      variables = normalize_variables(variables)
      
      Rails.logger.info("ProcessDocxVariables: Starting with #{variables.keys.size} variables")

      # Create temp file for input
      input_tempfile = Tempfile.new(['docx_input', '.docx'])
      input_tempfile.binmode
      input_tempfile.write(docx_data)
      input_tempfile.close

      # Create temp file for output
      output_tempfile = Tempfile.new(['docx_output', '.docx'])
      output_tempfile.close

      begin
        # Copy the original file to output
        FileUtils.cp(input_tempfile.path, output_tempfile.path)

        # Process the DOCX by modifying XML directly
        process_docx_xml(output_tempfile.path, variables)

        # Read and return the modified file
        File.binread(output_tempfile.path)
      ensure
        input_tempfile.unlink
        output_tempfile.unlink
      end
    end

    # Field tag pattern for signature/form fields: {{...}}
    FIELD_TAG_REGEX = /\{\{[^}]+\}\}/

    def process_docx_xml(docx_path, variables)
      Zip::File.open(docx_path) do |zip_file|
        # Process document.xml (main content)
        process_xml_part(zip_file, 'word/document.xml', variables)
        
        # Process headers
        zip_file.entries.each do |entry|
          if entry.name.match?(/word\/header\d+\.xml/)
            process_xml_part(zip_file, entry.name, variables)
          end
        end
        
        # Process footers
        zip_file.entries.each do |entry|
          if entry.name.match?(/word\/footer\d+\.xml/)
            process_xml_part(zip_file, entry.name, variables)
          end
        end
      end
    end

    def process_xml_part(zip_file, entry_name, variables)
      entry = zip_file.find_entry(entry_name)
      return unless entry

      xml_content = entry.get_input_stream.read.force_encoding('UTF-8')
      original_content = xml_content.dup
      
      # Use simple string-based replacement to preserve DOCX XML structure
      # This is safer than full XML parsing which can corrupt the document
      
      modified = false
      
      # Find loop variables by scanning for item accessors
      loop_vars = {}
      xml_content.scan(/\[\[(\w+)\.(\w+)\]\]/).each do |match|
        var_base = match[0]
        [var_base, var_base.pluralize, var_base.singularize].each do |potential_var|
          if variables[potential_var].is_a?(Array)
            loop_vars[var_base] = potential_var
            break
          end
        end
      end
      
      Rails.logger.info("ProcessDocxVariables: Found loop variables: #{loop_vars.inspect}") if loop_vars.any?
      
      # Process table row loops using regex to find and duplicate <w:tr> elements
      loop_vars.each do |accessor_name, var_name|
        items = variables[var_name]
        next unless items.is_a?(Array)
        
        # Find table rows containing item accessors
        row_pattern = /<w:tr[^>]*>.*?\[\[#{accessor_name}\.\w+\]\].*?<\/w:tr>/m
        
        xml_content.gsub!(row_pattern) do |row_xml|
          if items.any?
            # Generate a row for each item
            items.map do |item|
              row_copy = row_xml.dup
              # Remove loop markers
              row_copy.gsub!(/\[\[for:\w+\]\]/, '')
              row_copy.gsub!(/\[\[end(:\w+)?\]\]/, '')
              # Replace item accessors
              row_copy.gsub!(/\[\[#{accessor_name}\.(\w+)\]\]/) do
                prop = ::Regexp.last_match(1)
                item.is_a?(Hash) ? (item[prop] || item[prop.to_sym]).to_s : ''
              end
              row_copy
            end.join
          else
            '' # Remove row if no items
          end
        end
        modified = true if xml_content != original_content
      end
      
      # Remove standalone loop markers
      if xml_content.gsub!(/\[\[for:\w+\]\]/, '')
        modified = true
      end
      if xml_content.gsub!(/\[\[end(:\w+)?\]\]/, '')
        modified = true
      end
      
      # Remove placeholder text
      if xml_content.gsub!(/\(duplicate.*?item\)/i, '')
        modified = true
      end
      
      # Process simple variables [[var]]
      xml_content.gsub!(SIMPLE_VAR_REGEX) do
        var_name = ::Regexp.last_match(1)
        value = variables[var_name]
        modified = true
        case value
        when nil then ''
        when Array then value.map { |v| v.is_a?(Hash) ? v.values.join(', ') : v.to_s }.join('; ')
        when Hash then value.values.join(', ')
        else value.to_s
        end
      end
      
      # Process conditionals [[if:var]]...[[end]]
      while xml_content.match?(/\[\[if:(\w+)\]\]/)
        xml_content.gsub!(/\[\[if:(\w+)\]\](.*?)(?:\[\[else\]\](.*?))?\[\[end(?::\w+)?\]\]/m) do
          var_name = ::Regexp.last_match(1)
          true_content = ::Regexp.last_match(2) || ''
          false_content = ::Regexp.last_match(3) || ''
          var_value = variables[var_name]
          is_truthy = var_value.present? && var_value != false && var_value != 'false'
          modified = true
          is_truthy ? true_content : false_content
        end
        # Safety break to prevent infinite loop
        break unless xml_content.match?(/\[\[if:(\w+)\]\].*?\[\[end/)
      end
      
      # Remove orphan conditional markers
      xml_content.gsub!(/\[\[if:\w+\]\]/, '')
      xml_content.gsub!(/\[\[else\]\]/, '')
      xml_content.gsub!(/\[\[end(:\w+)?\]\]/, '')
      
      # Process {{field}} tags without type - replace with content
      xml_content.gsub!(/\{\{(\w+)\}\}/) do
        field_name = ::Regexp.last_match(1)
        # Only replace if no type= in the tag (simple content replacement)
        value = variables[field_name] || variables[field_name.downcase] || variables[field_name.underscore]
        modified = true if value.present?
        value.present? ? value.to_s : "{{#{field_name}}}"
      end
      
      # Note: {{field;type=X}} tags are kept as-is for form field detection
      
      if modified || xml_content != original_content
        zip_file.get_output_stream(entry_name) { |os| os.write(xml_content) }
        Rails.logger.info("ProcessDocxVariables: Updated #{entry_name}")
      end
    end

    def process_text(text, variables)
      return text if text.blank?
      
      result = text.dup
      
      # Process conditionals first
      result = process_conditionals(result, variables)
      
      # Process loops (simple text-based) - for non-table content
      result = process_loops(result, variables)
      
      # Process simple variables [[var]]
      result = substitute_simple_variables(result, variables)
      
      # Process {{field}} tags:
      # - Tags WITHOUT type: {{name}} → Replace with content from variables
      # - Tags WITH type: {{name;type=X}} → Keep as-is for form field detection
      result = process_field_tags(result, variables)
      
      result
    end
    
    # Process {{field}} tags
    # - {{name}} (no type) → replaced with content from variables
    # - {{name;type=X}} → kept as-is for form field detection
    def process_field_tags(text, variables)
      return text if text.blank?
      
      text.gsub(/\{\{([^}]+)\}\}/) do |match|
        tag_content = ::Regexp.last_match(1)
        parts = tag_content.split(';').map(&:strip)
        field_name = parts.first
        
        # Check if tag has a type attribute
        has_type = parts.any? { |p| p.downcase.start_with?('type=') }
        
        if has_type
          # Keep tags with type for form field detection
          match
        else
          # Replace tags without type with variable content
          value = variables[field_name] || variables[field_name.downcase] || variables[field_name.underscore]
          value.present? ? value.to_s : match
        end
      end
    end

    def normalize_variables(variables)
      return {} if variables.blank?

      variables.deep_stringify_keys.transform_values do |value|
        case value
        when Array
          value.map { |v| v.is_a?(Hash) ? v.deep_stringify_keys : v }
        when Hash
          value.deep_stringify_keys
        else
          value
        end
      end
    end

    def process_conditionals(text, variables)
      result = text.dup

      # Find all conditional blocks - handle with or without [[end]] closing
      while result.match?(CONDITIONAL_START_REGEX)
        # Try matching complete conditional with [[end]]
        match = result.match(/\[\[if:(\w+)\]\](.*?)(?:\[\[else\]\](.*?))?\[\[end(?::\w+)?\]\]/m)
        
        if match
          var_name = match[1]
          true_content = match[2] || ''
          false_content = match[3] || ''

          var_value = variables[var_name]
          is_truthy = var_value.present? && var_value != false && var_value != 'false'

          replacement = is_truthy ? true_content : false_content
          result = result.sub(match[0], replacement)
        else
          # If no complete match, just remove the [[if:xxx]] marker
          # This handles split conditionals - they'll be processed in subsequent passes
          result = result.gsub(/\[\[if:\w+\]\]/, '')
          break
        end
      end
      
      # Remove any orphan [[end]] markers
      result = result.gsub(/\[\[end(:\w+)?\]\]/, '')

      result
    end

    def process_loops(text, variables)
      result = text.dup
      
      while result.match?(LOOP_START_REGEX)
        match = result.match(/\[\[for:(\w+)\]\](.*?)\[\[end(?::\w+)?\]\]/m)
        break unless match
        
        var_name = match[1]
        loop_content = match[2]
        items = variables[var_name]
        
        if items.is_a?(Array) && items.any?
          singular_name = var_name.singularize
          expanded = items.map do |item|
            item_content = loop_content.dup
            # Replace item accessors like [[item.name]]
            item_content = item_content.gsub(/\[\[#{singular_name}\.(\w+)\]\]/) do |_|
              prop = ::Regexp.last_match(1)
              item.is_a?(Hash) ? (item[prop] || item[prop.to_sym]).to_s : ''
            end
            # Also handle [[items.name]] format
            item_content = item_content.gsub(/\[\[#{var_name}\.(\w+)\]\]/) do |_|
              prop = ::Regexp.last_match(1)
              item.is_a?(Hash) ? (item[prop] || item[prop.to_sym]).to_s : ''
            end
            item_content
          end.join
          
          result = result.sub(match[0], expanded)
        else
          # No items, remove the loop block
          result = result.sub(match[0], '')
        end
      end
      
      result
    end

    def substitute_simple_variables(text, variables)
      text.gsub(SIMPLE_VAR_REGEX) do |_match|
        var_name = ::Regexp.last_match(1)
        value = variables[var_name]

        case value
        when nil
          '' # Remove undefined variables
        when Array
          value.map { |v| v.is_a?(Hash) ? v.values.join(', ') : v.to_s }.join('; ')
        when Hash
          value.values.join(', ')
        else
          value.to_s
        end
      end
    end

    # Check if DOCX contains any variables that need processing
    def contains_variables?(docx_data)
      return false if docx_data.blank?
      return false unless docx_data[0..3] == "PK\x03\x04"

      tempfile = Tempfile.new(['docx_check', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.close

      begin
        Zip::File.open(tempfile.path) do |zip_file|
          entry = zip_file.find_entry('word/document.xml')
          return false unless entry

          xml_content = entry.get_input_stream.read
          
          return true if xml_content.match?(SIMPLE_VAR_REGEX)
          return true if xml_content.match?(CONDITIONAL_START_REGEX)
          return true if xml_content.match?(LOOP_START_REGEX)
        end

        false
      rescue StandardError => e
        Rails.logger.warn("ProcessDocxVariables.contains_variables? error: #{e.message}")
        false
      ensure
        tempfile.unlink if tempfile
      end
    end
    
    # Extract FORM FIELD tags from DOCX - only tags WITH type attribute
    # {{field;type=signature;role=Buyer}} → form field
    # {{field}} (no type) → NOT extracted, replaced with content by process_field_tags
    def extract_field_tags(docx_data)
      return [] if docx_data.blank?
      return [] unless docx_data[0..3] == "PK\x03\x04"

      fields = []
      # Match {{...}} tags that contain "type="
      field_tag_regex = /\{\{([^}]*type=[^}]+)\}\}/i

      tempfile = Tempfile.new(['docx_fields', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.close

      begin
        Zip::File.open(tempfile.path) do |zip_file|
          entry = zip_file.find_entry('word/document.xml')
          return [] unless entry

          xml_content = entry.get_input_stream.read
          
          doc = Nokogiri::XML(xml_content)
          namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
          
          all_text = doc.xpath('//w:t', namespaces).map(&:content).join(' ')
          normalized_text = all_text.gsub(/\s+/, ' ')
          
          Rails.logger.info("ProcessDocxVariables: Scanning for form field tags (with type=)")
          
          # Find all form field tags (those with type attribute)
          normalized_text.scan(field_tag_regex) do |match|
            tag_content = match[0]
            field_def = parse_field_tag(tag_content)
            
            if field_def.present?
              fields << field_def
              Rails.logger.info("ProcessDocxVariables: Form field '#{tag_content}' -> #{field_def[:name]} (#{field_def[:type]}) role=#{field_def[:role]}")
            end
          end
        end

        Rails.logger.info("ProcessDocxVariables: Found #{fields.size} form field tags")
        fields
      rescue StandardError => e
        Rails.logger.error("ProcessDocxVariables.extract_field_tags error: #{e.message}")
        []
      ensure
        tempfile.unlink if tempfile
      end
    end
    
    # Parse a field tag like "BuyerSign;type=signature;role=Buyer;required=true"
    # Official DocuSeal attributes:
    # - name: Name of the field
    # - type: text, signature, initials, date, datenow, image, file, payment, stamp, 
    #         select, checkbox, multiple, radio, phone, verification, kba
    # - role: Signer role name
    # - default: Default field value
    # - required: true/false (default: true)
    # - readonly: true/false (default: false)
    # - options: Comma-separated list for select/radio
    # - condition: FieldName:value for conditional display
    # - width/height: Absolute dimensions in pixels
    # - format: Date format or signature format
    def parse_field_tag(tag_content)
      parts = tag_content.split(';').map(&:strip)
      return nil if parts.blank?

      # First part is the field name
      name = parts.first
      attrs = {}

      # Parse remaining parts as key=value pairs
      parts[1..].each do |part|
        key, value = part.split('=', 2)
        attrs[key.strip.downcase] = value&.strip if key.present?
      end

      # Handle case where first part contains type specification (e.g., {{type=checkbox}})
      if name.include?('=')
        key, value = name.split('=', 2)
        if key.strip.downcase == 'type'
          attrs['type'] = value&.strip
          name = nil
        end
      end

      field_type = normalize_field_type(attrs['type'] || 'text')
      field_name = name.presence || attrs['name'].presence || "#{field_type.titleize} #{SecureRandom.hex(3).upcase}"
      
      result = {
        uuid: SecureRandom.uuid,
        name: field_name,
        type: field_type,
        role: attrs['role'],
        required: parse_boolean(attrs['required'], true),
        readonly: parse_boolean(attrs['readonly'], false)
      }
      
      # Add optional attributes if present
      result[:default_value] = attrs['default'] if attrs['default'].present?
      result[:options] = attrs['options']&.split(',')&.map(&:strip) if attrs['options'].present?
      result[:condition] = attrs['condition'] if attrs['condition'].present?
      result[:format] = attrs['format'] if attrs['format'].present?
      result[:width] = attrs['width'].to_i if attrs['width'].present?
      result[:height] = attrs['height'].to_i if attrs['height'].present?
      
      result.compact
    end
    
    # Normalize field type aliases to official DocuSeal types
    # Official types: text, signature, initials, date, datenow, image, file, 
    # payment, stamp, select, checkbox, multiple, radio, phone, verification, kba, number
    def normalize_field_type(type)
      type = type.to_s.downcase.strip
      
      # Map aliases to official types
      aliases = {
        'sig' => 'signature',
        'sign' => 'signature',
        'init' => 'initials',
        'check' => 'checkbox',
        'multi' => 'multiple',
        'sel' => 'select',
        'img' => 'image',
        'num' => 'number',
        'string' => 'text',
        'str' => 'text'
      }
      
      normalized = aliases[type] || type
      
      # Validate against official types
      official_types = %w[
        text signature initials date datenow image file payment stamp 
        select checkbox multiple radio phone verification kba number
      ]
      
      official_types.include?(normalized) ? normalized : 'text'
    end
    
    def parse_boolean(value, default)
      return default if value.nil?
      value.to_s.downcase.in?(%w[true yes 1 on])
    end
  end
end
