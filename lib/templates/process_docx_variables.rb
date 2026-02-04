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

      xml_content = entry.get_input_stream.read
      doc = Nokogiri::XML(xml_content)
      
      # Define namespace
      namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
      
      modified = false
      
      # First pass: Find all item accessor patterns and collect loop variable names
      loop_vars = {}
      doc.xpath('//w:t', namespaces).each do |text_node|
        text = text_node.content
        # Find item accessors like [[item.name]] or [[items.name]]
        text.scan(/\[\[(\w+)\.(\w+)\]\]/).each do |match|
          var_base = match[0] # e.g., "item" or "items"
          # Try both singular and plural forms
          [var_base, var_base.pluralize, var_base.singularize].each do |potential_var|
            if variables[potential_var].is_a?(Array)
              loop_vars[var_base] = potential_var
              break
            end
          end
        end
      end
      
      Rails.logger.info("ProcessDocxVariables: Found loop variables: #{loop_vars.inspect}")
      
      # Handle table rows with item accessors
      doc.xpath('//w:tr', namespaces).each do |row|
        row_text = row.xpath('.//w:t', namespaces).map(&:content).join
        
        # Check if this row contains item accessors
        loop_vars.each do |accessor_name, var_name|
          pattern = /\[\[#{accessor_name}\.(\w+)\]\]/
          next unless row_text.match?(pattern)
          
          items = variables[var_name]
          next unless items.is_a?(Array)
          
          if items.any?
            # Clone and process row for each item
            items.each_with_index do |item, idx|
              if idx == 0
                # Update original row with first item data
                row.xpath('.//w:t', namespaces).each do |text_node|
                  text = text_node.content
                  # Remove any loop markers
                  text = text.gsub(/\[\[for:\w+\]\]/, '').gsub(/\[\[end(:\w+)?\]\]/, '')
                  # Replace item accessors
                  text = text.gsub(/\[\[#{accessor_name}\.(\w+)\]\]/) do |_|
                    prop = ::Regexp.last_match(1)
                    item.is_a?(Hash) ? (item[prop] || item[prop.to_sym]).to_s : ''
                  end
                  text_node.content = text
                end
              else
                # Clone row for subsequent items
                new_row = row.dup
                new_row.xpath('.//w:t', namespaces).each do |text_node|
                  text = text_node.content
                  text = text.gsub(/\[\[for:\w+\]\]/, '').gsub(/\[\[end(:\w+)?\]\]/, '')
                  text = text.gsub(/\[\[#{accessor_name}\.(\w+)\]\]/) do |_|
                    prop = ::Regexp.last_match(1)
                    item.is_a?(Hash) ? (item[prop] || item[prop.to_sym]).to_s : ''
                  end
                  text_node.content = text
                end
                row.add_next_sibling(new_row)
              end
            end
            modified = true
            Rails.logger.info("ProcessDocxVariables: Expanded table row for #{var_name} with #{items.size} items")
          else
            # No items - remove the row
            row.remove
            modified = true
            Rails.logger.info("ProcessDocxVariables: Removed empty item row for #{var_name}")
          end
          
          break # Only process one loop variable per row
        end
      end
      
      # Remove standalone loop markers [[for:xxx]] and [[end]]
      doc.xpath('//w:t', namespaces).each do |text_node|
        text = text_node.content
        if text.match?(/\[\[for:\w+\]\]/) || text.match?(/\[\[end(:\w+)?\]\]/)
          text_node.content = text.gsub(/\[\[for:\w+\]\]/, '').gsub(/\[\[end(:\w+)?\]\]/, '')
          modified = true
        end
      end
      
      # Remove placeholder text like "(duplicate row for each item)"
      doc.xpath('//w:t', namespaces).each do |text_node|
        text = text_node.content
        if text.match?(/\(duplicate.*item\)/i)
          text_node.content = text.gsub(/\(duplicate.*item\)/i, '')
          modified = true
        end
      end
      
      # Final cleanup: Remove any remaining conditional markers
      doc.xpath('//w:t', namespaces).each do |text_node|
        text = text_node.content
        next if text.blank?
        
        new_text = text
        # Remove orphan [[if:xxx]] markers
        new_text = new_text.gsub(/\[\[if:\w+\]\]/, '')
        # Remove orphan [[else]] markers
        new_text = new_text.gsub(/\[\[else\]\]/, '')
        # Remove orphan [[end]] markers
        new_text = new_text.gsub(/\[\[end(:\w+)?\]\]/, '')
        
        if text != new_text
          text_node.content = new_text
          modified = true
        end
      end
      
      # Consolidate {{field tags}} that might be split across multiple w:t nodes
      # This ensures the PDF extractor can find complete tags
      # Tags like {{BuyerSign;type=signature}} might be split across multiple w:t nodes
      doc.xpath('//w:p', namespaces).each do |para|
        text_nodes = para.xpath('.//w:t', namespaces)
        next if text_nodes.empty?
        
        # Combine all text from paragraph
        combined_text = text_nodes.map(&:content).join
        next unless combined_text.include?('{{') && combined_text.include?('}}')
        
        # Check if tags are split (partial {{ in one node, partial }} in another)
        has_split_tag = text_nodes.any? { |n| n.content.include?('{{') && !n.content.include?('}}') } ||
                        text_nodes.any? { |n| n.content.include?('}}') && !n.content.include?('{{') }
        
        if has_split_tag
          # Consolidate into first node so PDF extractor can find complete tags
          text_nodes.first.content = combined_text
          text_nodes[1..-1].each { |n| n.content = '' }
          modified = true
          Rails.logger.info("ProcessDocxVariables: Consolidated split field tags in paragraph")
        end
      end
      
      # Also consolidate tags in table cells (w:tc) which may contain split tags
      doc.xpath('//w:tc', namespaces).each do |cell|
        text_nodes = cell.xpath('.//w:t', namespaces)
        next if text_nodes.empty?
        
        combined_text = text_nodes.map(&:content).join
        next unless combined_text.include?('{{') && combined_text.include?('}}')
        
        # Check if tags are split
        has_split_tag = text_nodes.any? { |n| n.content.include?('{{') && !n.content.include?('}}') } ||
                        text_nodes.any? { |n| n.content.include?('}}') && !n.content.include?('{{') }
        
        if has_split_tag
          text_nodes.first.content = combined_text
          text_nodes[1..-1].each { |n| n.content = '' }
          modified = true
          Rails.logger.info("ProcessDocxVariables: Consolidated split field tags in table cell")
        end
      end
      
      # Second pass: Process all paragraphs (including table cells)
      doc.xpath('//w:p', namespaces).each do |para|
        text_nodes = para.xpath('.//w:t', namespaces)
        next if text_nodes.empty?
        
        # Get combined text from all runs in paragraph
        combined_text = text_nodes.map(&:content).join
        next if combined_text.blank?
        
        # Check if needs processing
        needs_processing = combined_text.match?(SIMPLE_VAR_REGEX) || 
                          combined_text.match?(CONDITIONAL_START_REGEX) ||
                          combined_text.match?(FIELD_TAG_REGEX)
        next unless needs_processing
        
        # Process the combined text
        new_text = process_text(combined_text, variables)
        
        if combined_text != new_text
          # Put all text in the first node, clear the rest
          text_nodes.first.content = new_text
          text_nodes[1..-1].each { |n| n.content = '' }
          modified = true
          Rails.logger.info("ProcessDocxVariables: Replaced paragraph text")
        end
      end
      
      # Third pass: Process any remaining individual text nodes
      doc.xpath('//w:t', namespaces).each do |text_node|
        original_text = text_node.content
        next if original_text.blank?
        next unless original_text.match?(SIMPLE_VAR_REGEX) || 
                   original_text.match?(CONDITIONAL_START_REGEX) ||
                   original_text.match?(FIELD_TAG_REGEX)
        
        new_text = process_text(original_text, variables)
        
        if original_text != new_text
          text_node.content = new_text
          modified = true
        end
      end
      
      if modified
        # Write back to zip
        zip_file.get_output_stream(entry_name) { |os| os.write(doc.to_xml) }
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
      
      # Process simple variables
      result = substitute_simple_variables(result, variables)
      
      # Note: {{field tags}} are kept as-is so ParsePdfTextTags can find them
      # and create form fields at those positions
      
      result
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
    
    # Extract field tags from DOCX ({{field;type=signature;role=Buyer}})
    # This is more reliable than extracting from PDF
    def extract_field_tags(docx_data)
      return [] if docx_data.blank?
      return [] unless docx_data[0..3] == "PK\x03\x04"

      fields = []
      field_tag_regex = /\{\{([^}]+)\}\}/

      tempfile = Tempfile.new(['docx_fields', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.close

      begin
        Zip::File.open(tempfile.path) do |zip_file|
          entry = zip_file.find_entry('word/document.xml')
          return [] unless entry

          xml_content = entry.get_input_stream.read
          
          # Extract all text content and normalize whitespace
          doc = Nokogiri::XML(xml_content)
          namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
          
          all_text = doc.xpath('//w:t', namespaces).map(&:content).join(' ')
          normalized_text = all_text.gsub(/\s+/, ' ')
          
          Rails.logger.info("ProcessDocxVariables: Extracting field tags from DOCX, text length=#{normalized_text.length}")
          
          # Find all field tags
          normalized_text.scan(field_tag_regex) do |match|
            tag_content = match[0]
            field_def = parse_field_tag(tag_content)
            
            if field_def.present?
              fields << field_def
              Rails.logger.info("ProcessDocxVariables: Found field tag '#{tag_content}' -> #{field_def[:name]} (#{field_def[:type]})")
            end
          end
        end

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
