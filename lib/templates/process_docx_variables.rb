# frozen_string_literal: true

require 'docx'
require 'tempfile'
require 'nokogiri'

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

      tempfile = Tempfile.new(['docx_input', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.flush  # Ensure data is written to disk
      tempfile.close  # Close the file so docx gem can open it

      output_tempfile = Tempfile.new(['docx_output', '.docx'])
      output_tempfile.binmode
      output_tempfile.close

      begin
        doc = Docx::Document.open(tempfile.path)

        # Process document body paragraphs
        process_paragraphs(doc, variables)

        # Process tables
        process_tables(doc, variables)

        doc.save(output_tempfile.path)
        File.binread(output_tempfile.path)
      ensure
        tempfile.unlink if tempfile
        output_tempfile.unlink if output_tempfile
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

    def process_paragraphs(doc, variables)
      doc.paragraphs.each do |paragraph|
        process_text_content(paragraph, variables)
      end
    end

    def process_tables(doc, variables)
      doc.tables.each do |table|
        # Check if this table contains loop patterns for dynamic rows
        loop_row_index = find_loop_row(table, variables)

        if loop_row_index
          process_table_with_loop(table, loop_row_index, variables)
        else
          # Process each cell normally
          table.rows.each do |row|
            row.cells.each do |cell|
              cell.paragraphs.each do |paragraph|
                process_text_content(paragraph, variables)
              end
            end
          end
        end
      end
    end

    def find_loop_row(table, variables)
      table.rows.each_with_index do |row, index|
        row.cells.each do |cell|
          cell.paragraphs.each do |paragraph|
            text = paragraph.text
            return index if text.match?(LOOP_START_REGEX)
          end
        end
      end
      nil
    end

    def process_table_with_loop(table, loop_row_index, variables)
      loop_row = table.rows[loop_row_index]

      # Find the loop variable name
      loop_var_name = nil
      loop_row.cells.each do |cell|
        cell.paragraphs.each do |paragraph|
          match = paragraph.text.match(LOOP_START_REGEX)
          loop_var_name = match[1] if match
        end
      end

      return unless loop_var_name

      items = variables[loop_var_name]
      return unless items.is_a?(Array)

      # Get the singular form for item accessor (e.g., 'items' -> 'item')
      singular_name = loop_var_name.singularize

      # Process rows before the loop
      (0...loop_row_index).each do |i|
        table.rows[i].cells.each do |cell|
          cell.paragraphs.each do |paragraph|
            process_text_content(paragraph, variables)
          end
        end
      end

      # For each item, create row content
      items.each_with_index do |item, item_index|
        item_vars = variables.merge(singular_name => item)

        if item_index.zero?
          # Use the original loop row for the first item
          loop_row.cells.each do |cell|
            cell.paragraphs.each do |paragraph|
              text = paragraph.text
              # Remove loop markers
              text = text.gsub(LOOP_START_REGEX, '').gsub(LOOP_END_REGEX, '')
              # Process item accessors
              text = process_item_accessors(text, singular_name, item)
              # Process regular variables
              text = substitute_simple_variables(text, item_vars)
              paragraph.substitute(paragraph.text, text) if paragraph.text != text
            end
          end
        end
        # Note: Adding new rows dynamically is complex with the docx gem
        # For simplicity, this handles the first item; advanced row duplication
        # would require direct XML manipulation
      end

      # Process rows after the loop (simplified)
      ((loop_row_index + 1)...table.rows.size).each do |i|
        table.rows[i].cells.each do |cell|
          cell.paragraphs.each do |paragraph|
            process_text_content(paragraph, variables)
          end
        end
      end
    end

    def process_text_content(paragraph, variables)
      text = paragraph.text
      return if text.blank?

      # Process conditionals first
      text = process_conditionals(text, variables)

      # Process simple variables
      text = substitute_simple_variables(text, variables)

      # Update paragraph if text changed
      paragraph.substitute(paragraph.text, text) if paragraph.text != text
    rescue StandardError => e
      Rails.logger.warn("Error processing paragraph: #{e.message}")
    end

    def process_conditionals(text, variables)
      # Simple conditional processing: [[if:var]]content[[end]] or [[if:var]]content[[else]]alt[[end]]
      result = text.dup

      # Find all conditional blocks
      while result.match?(CONDITIONAL_START_REGEX)
        match = result.match(/\[\[if:(\w+)\]\](.*?)(?:\[\[else\]\](.*?))?\[\[end(?::\w+)?\]\]/m)
        break unless match

        var_name = match[1]
        true_content = match[2] || ''
        false_content = match[3] || ''

        var_value = variables[var_name]
        is_truthy = var_value.present? && var_value != false && var_value != 'false'

        replacement = is_truthy ? true_content : false_content
        result = result.sub(match[0], replacement)
      end

      result
    end

    def substitute_simple_variables(text, variables)
      text.gsub(SIMPLE_VAR_REGEX) do |match|
        var_name = ::Regexp.last_match(1)
        value = variables[var_name]

        case value
        when nil
          '' # Remove undefined variables
        when Array
          value.join(', ')
        when Hash
          value.to_json
        else
          value.to_s
        end
      end
    end

    def process_item_accessors(text, item_name, item)
      return text unless item.is_a?(Hash)

      text.gsub(/\[\[#{item_name}\.(\w+)\]\]/) do |_match|
        property = ::Regexp.last_match(1)
        item[property].to_s
      end
    end

    # Check if DOCX contains any variables that need processing
    def contains_variables?(docx_data)
      return false if docx_data.blank?
      return false unless docx_data[0..3] == "PK\x03\x04" # Validate ZIP header

      tempfile = Tempfile.new(['docx_check', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.flush
      tempfile.close

      begin
        doc = Docx::Document.open(tempfile.path)

        doc.paragraphs.each do |paragraph|
          return true if paragraph.text.match?(SIMPLE_VAR_REGEX)
          return true if paragraph.text.match?(CONDITIONAL_START_REGEX)
          return true if paragraph.text.match?(LOOP_START_REGEX)
        end

        doc.tables.each do |table|
          table.rows.each do |row|
            row.cells.each do |cell|
              cell.paragraphs.each do |paragraph|
                return true if paragraph.text.match?(SIMPLE_VAR_REGEX)
                return true if paragraph.text.match?(CONDITIONAL_START_REGEX)
                return true if paragraph.text.match?(LOOP_START_REGEX)
              end
            end
          end
        end

        false
      rescue StandardError => e
        Rails.logger.warn("ProcessDocxVariables.contains_variables? error: #{e.message}")
        false # Return false if we can't open the file, so we skip processing
      ensure
        tempfile.unlink if tempfile
      end
    end
  end
end
