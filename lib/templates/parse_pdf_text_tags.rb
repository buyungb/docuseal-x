# frozen_string_literal: true

module Templates
  module ParsePdfTextTags
    # Pattern to match {{...}} tags in PDF text
    TAG_REGEX = /\{\{([^}]+)\}\}/

    # Supported field types
    FIELD_TYPES = %w[
      text signature initials date datenow image file
      payment stamp select checkbox multiple radio phone verification kba cells number
    ].freeze

    # Default field type if not specified
    DEFAULT_FIELD_TYPE = 'text'

    module_function

    # Parse PDF content and extract field definitions from text tags
    # Returns array of field definitions with areas
    def call(pdf, attachment)
      fields = []
      
      # First approach: Try position-aware extraction
      text_positions = extract_text_with_positions(pdf)

      text_positions.each do |text_item|
        text = text_item[:text]

        # Find all tags in this text segment
        text.scan(TAG_REGEX) do |match|
          tag_content = match[0]
          field_def = parse_tag(tag_content)

          next if field_def.blank?

          # Calculate field area based on text position
          area = calculate_field_area(text_item, attachment)
          next if area.blank?

          field_def[:uuid] = SecureRandom.uuid
          field_def[:areas] = [area]

          fields << field_def
        end
      end

      # Second approach: If no fields found, try extracting all text and finding tags
      # This handles cases where tags are split across text runs
      if fields.blank?
        Rails.logger.info("ParsePdfTextTags: No fields from position extraction, trying full text extraction")
        
        pdf.pages.each_with_index do |page, page_index|
          page_text = extract_page_text(page)
          # Normalize whitespace to handle line breaks within tags
          normalized = page_text.gsub(/\s+/, ' ')
          
          page_width = page.box(:media).width rescue 612
          page_height = page.box(:media).height rescue 792
          
          # Find all tags
          normalized.scan(TAG_REGEX) do |match|
            tag_content = match[0]
            field_def = parse_tag(tag_content)
            
            next if field_def.blank?
            
            # Create approximate area (center of page for signature fields)
            field_def[:uuid] = SecureRandom.uuid
            
            # Position based on field type
            y_position = case field_def[:type]
            when 'signature', 'initials' then 0.75 # Lower on page
            else 0.5 # Middle of page
            end
            
            field_def[:areas] = [{
              page: page_index,
              x: 0.1,
              y: y_position,
              w: 0.35,
              h: field_def[:type] == 'signature' ? 0.08 : 0.04,
              attachment_uuid: attachment.uuid
            }]
            
            fields << field_def
            Rails.logger.info("ParsePdfTextTags: Found tag '#{tag_content}' -> field '#{field_def[:name]}' (#{field_def[:type]})")
          end
        end
      end
      
      Rails.logger.info("ParsePdfTextTags: Extracted #{fields.size} fields total")
      fields
    end

    # Parse a single tag content into field definition
    # Example: "Sign;type=signature;role=Customer;required=true"
    def parse_tag(tag_content)
      parts = tag_content.split(';').map(&:strip)
      return {} if parts.blank?

      # First part is the field name (can be empty for some field types)
      name = parts.first
      attrs = {}

      # Parse remaining parts as key=value pairs
      parts[1..].each do |part|
        key, value = part.split('=', 2)
        attrs[key.strip.downcase] = value&.strip if key.present?
      end

      # Handle case where first part contains type specification
      if name.include?('=')
        key, value = name.split('=', 2)
        if key.strip.downcase == 'type'
          attrs['type'] = value&.strip
          name = ''
        end
      end

      field_type = normalize_field_type(attrs['type'] || DEFAULT_FIELD_TYPE)
      return {} unless FIELD_TYPES.include?(field_type)

      field = {
        name: name.presence || generate_field_name(field_type),
        type: field_type,
        required: parse_boolean(attrs['required'], true),
        readonly: parse_boolean(attrs['readonly'], false),
        preferences: {}
      }

      # Add role/submitter information
      field[:role] = attrs['role'] if attrs['role'].present?

      # Add default value
      field[:default_value] = attrs['default'] if attrs['default'].present?

      # Add description
      field[:description] = attrs['description'] if attrs['description'].present?

      # Add options for select/radio/multiple fields
      if attrs['options'].present? && field_type.in?(%w[select radio multiple])
        field[:options] = build_options(attrs['options'].split(','))
      end

      # Add option for radio fields
      if attrs['option'].present? && field_type == 'radio'
        field[:options] = build_options([attrs['option']])
      end

      # Add format preference
      field[:preferences][:format] = attrs['format'] if attrs['format'].present?

      # Add alignment preference
      field[:preferences][:align] = attrs['align'] if attrs['align'].present?
      field[:preferences][:valign] = attrs['valign'] if attrs['valign'].present?

      # Add font preferences
      field[:preferences][:font] = attrs['font'] if attrs['font'].present?
      field[:preferences][:font_size] = attrs['font_size'].to_i if attrs['font_size'].present?
      field[:preferences][:font_type] = attrs['font_type'] if attrs['font_type'].present?
      field[:preferences][:color] = attrs['color'] if attrs['color'].present?

      # Add dimension overrides
      field[:width] = attrs['width'].to_i if attrs['width'].present?
      field[:height] = attrs['height'].to_i if attrs['height'].present?

      # Add validation
      field[:preferences][:min] = attrs['min'] if attrs['min'].present?
      field[:preferences][:max] = attrs['max'] if attrs['max'].present?

      # Add hidden/mask attributes
      field[:preferences][:hidden] = true if parse_boolean(attrs['hidden'], false)
      field[:preferences][:mask] = true if parse_boolean(attrs['mask'], false)

      # Add condition
      if attrs['condition'].present?
        field[:conditions] = parse_condition(attrs['condition'])
      end

      # Clean up empty preferences
      field[:preferences] = field[:preferences].compact_blank
      field.delete(:preferences) if field[:preferences].blank?

      field.compact_blank
    end

    def extract_text_with_positions(pdf)
      text_items = []

      pdf.pages.each_with_index do |page, page_index|
        page_width = page.box(:media).width
        page_height = page.box(:media).height

        # Use HexaPDF's text extraction with positioning
        processor = TextPositionProcessor.new(page_index, page_width, page_height)

        begin
          page.process_contents(processor)
          text_items.concat(processor.text_items)
        rescue StandardError => e
          Rails.logger.warn("Error extracting text from page #{page_index}: #{e.message}")
        end
      end

      text_items
    end

    def calculate_field_area(text_item, attachment)
      # Calculate normalized coordinates (0-1 range)
      {
        page: text_item[:page],
        x: text_item[:x] / text_item[:page_width].to_f,
        y: text_item[:y] / text_item[:page_height].to_f,
        w: [text_item[:width] / text_item[:page_width].to_f, 0.2].max,
        h: [text_item[:height] / text_item[:page_height].to_f, 0.03].max,
        attachment_uuid: attachment.uuid
      }
    end

    def normalize_field_type(type)
      type = type.to_s.downcase.strip

      # Handle aliases
      case type
      when 'sig' then 'signature'
      when 'init' then 'initials'
      when 'check' then 'checkbox'
      when 'multi' then 'multiple'
      when 'sel' then 'select'
      when 'img' then 'image'
      when 'num' then 'number'
      else type
      end
    end

    def parse_boolean(value, default)
      return default if value.nil?

      value.to_s.downcase.in?(%w[true yes 1 on])
    end

    def generate_field_name(field_type)
      "#{field_type.titleize} #{SecureRandom.hex(3).upcase}"
    end

    def build_options(values)
      values.map do |value|
        {
          uuid: SecureRandom.uuid,
          value: value.strip
        }
      end
    end

    def parse_condition(condition_str)
      # Format: "FieldName:value" or just "FieldName" for non-empty check
      field_name, value = condition_str.split(':', 2)

      [
        {
          field_uuid: nil, # Will be resolved later
          field_name: field_name.strip,
          value: value&.strip,
          action: 'show'
        }
      ]
    end

    # Check if PDF contains any text tags
    def contains_tags?(pdf)
      all_text = ''
      pdf.pages.each do |page|
        page_text = extract_page_text(page)
        all_text += page_text
      end
      
      # Remove whitespace and newlines before checking for tags
      # This handles tags split across lines
      normalized_text = all_text.gsub(/\s+/, ' ')
      has_tags = normalized_text.match?(TAG_REGEX)
      
      Rails.logger.info("ParsePdfTextTags.contains_tags?: #{has_tags}, text sample: #{normalized_text[0..200]}...")
      
      has_tags
    rescue StandardError => e
      Rails.logger.warn("ParsePdfTextTags.contains_tags? error: #{e.message}")
      false
    end

    def extract_page_text(page)
      text = ''
      processor = SimpleTextProcessor.new
      page.process_contents(processor)
      processor.text
    rescue StandardError
      ''
    end

    # Simple text processor for checking tag presence
    class SimpleTextProcessor
      attr_reader :text

      def initialize
        @text = ''
      end

      def process(*args)
        # Handle different method signatures
      end

      def show_text(str)
        @text += str.to_s
      end

      def show_text_with_positioning(array)
        array.each do |item|
          @text += item.to_s if item.is_a?(String)
        end
      end

      def method_missing(_method, *_args)
        # Ignore other PDF operators
      end

      def respond_to_missing?(_method, _include_private = false)
        true
      end
    end

    # Text processor that captures positions
    class TextPositionProcessor
      attr_reader :text_items

      def initialize(page_index, page_width, page_height)
        @page_index = page_index
        @page_width = page_width
        @page_height = page_height
        @text_items = []
        @current_x = 0
        @current_y = 0
        @font_size = 12
        @accumulated_text = ''
        @text_start_x = 0
        @text_start_y = 0
        @in_tag = false # Track if we're inside an unclosed {{ tag
      end

      def process(*args)
        # Handle different method signatures
      end

      def set_font(_font, size)
        @font_size = size
      end

      def move_text(x, y)
        # Don't flush if we're in the middle of a tag (unclosed {{)
        flush_text unless @in_tag
        @current_x = x
        @current_y = y
        @text_start_x = x unless @in_tag
        @text_start_y = y unless @in_tag
      end

      def set_text_matrix(a, _b, _c, _d, e, f)
        # Don't flush if we're in the middle of a tag
        flush_text unless @in_tag
        @current_x = e
        @current_y = f
        @text_start_x = e unless @in_tag
        @text_start_y = f unless @in_tag
      end

      def show_text(str)
        str = str.to_s
        return if str.blank?

        @text_start_x = @current_x if @accumulated_text.blank?
        @text_start_y = @current_y if @accumulated_text.blank?
        @accumulated_text += str

        # Track if we're inside an unclosed tag
        open_count = @accumulated_text.scan('{{').length
        close_count = @accumulated_text.scan('}}').length
        @in_tag = open_count > close_count

        # Check if this text contains a complete tag
        flush_text if !@in_tag && @accumulated_text.include?('}}')
      end

      def show_text_with_positioning(array)
        array.each do |item|
          show_text(item) if item.is_a?(String)
        end
      end

      def end_text
        @in_tag = false # Force close any open tags at end of text block
        flush_text
      end

      def flush_text
        return if @accumulated_text.blank?

        # Check if text contains tags
        if @accumulated_text.match?(TAG_REGEX)
          # Calculate approximate width based on text length and font size
          char_width = @font_size * 0.6
          text_width = @accumulated_text.length * char_width

          @text_items << {
            text: @accumulated_text,
            page: @page_index,
            x: @text_start_x,
            y: @page_height - @text_start_y - @font_size,
            width: text_width,
            height: @font_size * 1.2,
            page_width: @page_width,
            page_height: @page_height
          }
        end

        @accumulated_text = ''
        @in_tag = false
      end

      def method_missing(_method, *_args)
        # Ignore other PDF operators
      end

      def respond_to_missing?(_method, _include_private = false)
        true
      end
    end
  end
end
