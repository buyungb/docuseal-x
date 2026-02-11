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
    # 
    # This method can accept either:
    # - HexaPDF document (for backward compatibility)
    # - PDF binary data (for Pdfium-based extraction)
    def call(pdf_or_data, attachment)
      fields = []
      
      # Try Pdfium-based extraction first (most reliable for LibreOffice PDFs)
      if pdf_or_data.is_a?(String) || pdf_or_data.respond_to?(:read)
        pdf_data = pdf_or_data.is_a?(String) ? pdf_or_data : pdf_or_data.read
        tag_positions = extract_tags_using_pdfium(pdf_data)
      else
        # Fallback to HexaPDF if we have a HexaPDF document
        tag_positions = extract_tags_using_glyphs(pdf_or_data)
      end
      
      Rails.logger.info("ParsePdfTextTags: Found #{tag_positions.size} tags with positions")
      
      tag_positions.each do |tag_info|
        field_def = parse_tag(tag_info[:tag_content])
        next if field_def.blank?
        
        field_def[:uuid] = SecureRandom.uuid
        field_def[:areas] = [{
          page: tag_info[:page],
          x: tag_info[:x],
          y: tag_info[:y],
          w: tag_info[:w],
          h: tag_info[:h],
          attachment_uuid: attachment.uuid
        }]
        
        fields << field_def
        Rails.logger.info("ParsePdfTextTags: #{field_def[:name]} (#{field_def[:type]}) -> page=#{tag_info[:page]} pos=(#{tag_info[:x].round(3)}, #{tag_info[:y].round(3)})")
      end
      
      # Fallback: If no positioned tags found, try simple text extraction
      if fields.blank?
        Rails.logger.info("ParsePdfTextTags: No positioned tags found, trying fallback extraction")
        fields = extract_tags_fallback_from_data(pdf_or_data, attachment)
      end
      
      Rails.logger.info("ParsePdfTextTags: Extracted #{fields.size} fields total")
      fields
    end
    
    # Extract tags using Pdfium - this is DocuSeal's standard approach
    # Pdfium properly handles font decoding which is essential for LibreOffice PDFs
    def extract_tags_using_pdfium(pdf_data)
      all_tags = []
      
      begin
        doc = Pdfium::Document.open_bytes(pdf_data)
        
        (0...doc.page_count).each do |page_index|
          page = doc.get_page(page_index)
          
          Rails.logger.info("ParsePdfTextTags: Processing page #{page_index} with Pdfium")
          
          # Get text nodes - Pdfium properly decodes text
          text_nodes = page.text_nodes
          
          Rails.logger.info("ParsePdfTextTags: Page #{page_index} has #{text_nodes.size} text nodes")
          
          # Build full text with character positions
          chars_with_positions = []
          text_nodes.each do |node|
            content = node.content.to_s
            next if content.empty?
            
            # Each node represents a character or word with its position
            # Positions are already normalized (0-1)
            chars_with_positions << {
              char: content,
              x: node.x,
              y: node.y,
              w: node.w,
              h: node.h,
              endx: node.endx,
              endy: node.endy
            }
          end
          
          # Join text and find tags
          full_text = chars_with_positions.map { |c| c[:char] }.join
          
          # Create dehyphenated text for finding tags split across lines
          # LibreOffice PDFs often break words like "re-\nquired" -> should be "required"
          # Handle various hyphen characters: regular hyphen, soft hyphen (U+00AD), non-breaking hyphen (U+2011), hyphen-minus
          dehyphenated_text = full_text.gsub(/[-\u00AD\u2010\u2011\u2012]\s*[\r\n]+\s*/, '')  # Remove hyphen + newline
          dehyphenated_text = dehyphenated_text.gsub(/[\r\n]+/, ' ')  # Replace remaining newlines with space
          
          Rails.logger.info("ParsePdfTextTags: Full text (#{full_text.length} chars): #{full_text[0..500]}...")
          Rails.logger.info("ParsePdfTextTags: Dehyphenated text sample: #{dehyphenated_text[0..500]}...")
          
          # Debug: Look for SellerSign specifically
          if full_text.include?('SellerSign')
            seller_idx = full_text.index('SellerSign')
            context_start = [seller_idx - 10, 0].max
            context_end = [seller_idx + 80, full_text.length].min
            context = full_text[context_start...context_end]
            Rails.logger.info("ParsePdfTextTags: SellerSign found in full_text at #{seller_idx}, context: #{context.inspect}")
          elsif full_text.include?('Seller')
            # Check if Seller exists but SellerSign doesn't (might be split)
            Rails.logger.warn("ParsePdfTextTags: 'Seller' found but 'SellerSign' not found directly - checking for split tags")
            full_text.scan(/\{\{Seller[^}]*\}\}/m) do |match|
              Rails.logger.info("ParsePdfTextTags: Found Seller tag pattern: #{match.inspect}")
            end
          else
            Rails.logger.warn("ParsePdfTextTags: Neither 'SellerSign' nor 'Seller' found in page text!")
          end
          
          # Log if we find any {{ patterns
          braces_count = full_text.scan(/\{\{/).count
          dehyph_braces = dehyphenated_text.scan(/\{\{/).count
          Rails.logger.info("ParsePdfTextTags: Found #{braces_count} '{{' in original, #{dehyph_braces} in dehyphenated text")
          
          # Find tags in the text (pass both original and dehyphenated)
          tags = find_tags_in_pdfium_text(chars_with_positions, full_text, page_index, dehyphenated_text)
          
          Rails.logger.info("ParsePdfTextTags: Extracted #{tags.size} tags from page #{page_index}")
          tags.each do |t|
            Rails.logger.info("  - #{t[:tag_content]} at (#{t[:x].round(3)}, #{t[:y].round(3)})")
          end
          
          all_tags.concat(tags)
          
          page.close
        end
        
        doc.close
        
        Rails.logger.info("ParsePdfTextTags: Total tags found across all pages: #{all_tags.size}")
      rescue StandardError => e
        Rails.logger.warn("ParsePdfTextTags: Pdfium extraction failed: #{e.message}")
        Rails.logger.warn(e.backtrace.first(5).join("\n"))
      end
      
      all_tags
    end
    
    # Find {{...}} tags in Pdfium text nodes.
    # 
    # SIMPLE APPROACH: The position of each form field = the position of the
    # first "{{" character in the tagged PDF. The width/height come from the
    # tag text extent. NO label adjustments, NO cell heuristics on position.
    # The tagged PDF and clean PDF have the same layout (tags replaced with
    # equal-length whitespace), so positions map 1:1.
    def find_tags_in_pdfium_text(chars_with_positions, full_text, page_index, dehyphenated_text = nil)
      tags = []
      
      dehyphenated_text ||= full_text.gsub(/[-\u00AD\u2010\u2011\u2012]\s*[\r\n]+\s*/, '').gsub(/[\r\n]+/, ' ')
      
      Rails.logger.info("ParsePdfTextTags: Searching for tags in page #{page_index}")
      Rails.logger.info("ParsePdfTextTags: dehyphenated_text has #{dehyphenated_text.scan(TAG_REGEX).count} tags")
      
      # Build a simple full-text string from chars and map char offsets to indices
      char_texts = chars_with_positions.map { |c| c[:char].to_s }
      simple_text = char_texts.join
      
      # Find all {{...}} tags in dehyphenated text
      dehyphenated_text.scan(TAG_REGEX) do |match|
        tag_content = match[0]
        
        field_def = parse_tag(tag_content)
        next if field_def.blank?
        
        field_name = field_def[:name]
        next if tags.any? { |t| parse_tag(t[:tag_content])&.dig(:name) == field_name }
        
        Rails.logger.info("ParsePdfTextTags: Looking for tag '#{field_name}' (#{field_def[:type]})")
        
        # PRIMARY STRATEGY: Character-by-character matching against Pdfium chars.
        # This is the most reliable method because each matched character carries
        # its own (x, y) coordinates from Pdfium. Unlike simple_text.index(),
        # this correctly handles tables where Pdfium interleaves text from
        # different columns at the same Y position.
        start_ci, end_ci = find_tag_positions_in_chars(chars_with_positions, tag_content)
        
        unless start_ci && end_ci
          Rails.logger.warn("ParsePdfTextTags: Tag '#{field_name}' not found in Pdfium chars, skipping")
          next
        end
        
        s_pos = chars_with_positions[start_ci]
        e_pos = chars_with_positions[end_ci]
        
        # Position = exactly where {{ appears in the tagged PDF
        tag_x = s_pos[:x]
        tag_y = s_pos[:y]
        tag_h = s_pos[:h] || 0.015
        
        Rails.logger.info("ParsePdfTextTags: '#{field_name}' found at char[#{start_ci}..#{end_ci}] raw_pos=(#{tag_x.round(4)}, #{tag_y.round(4)})")
        
        # Width = from {{ to }} if on same line, otherwise line width
        raw_w = (e_pos[:endx] || e_pos[:x] + (e_pos[:w] || 0.01)) - tag_x
        tag_wrapped = (e_pos[:y] - s_pos[:y]).abs > (tag_h * 0.5)
        
        if tag_wrapped || raw_w < 0 || raw_w > 0.6
          # Tag wraps to multiple lines.
          # Find the right edge of text on the SAME line AND in the SAME column
          # (within x range of ±0.3 from tag_x to avoid picking up other column text)
          same_line_same_col = chars_with_positions.select do |n|
            (n[:y] - tag_y).abs < tag_h * 0.5 &&
            (n[:x] - tag_x).abs < 0.3
          end
          line_right = same_line_same_col.map { |n| (n[:endx] || n[:x] + (n[:w] || 0.01)) }.max || (tag_x + 0.15)
          tag_w = line_right - tag_x
          tag_w = 0.15 if tag_w <= 0.02 || tag_w > 0.5
        else
          tag_w = raw_w
        end
        
        # Adjust height based on field type (signature needs more vertical space)
        case field_def[:type]
        when 'signature', 'initials'
          if tag_wrapped
            wrapped_h = (e_pos[:y] + (e_pos[:h] || tag_h)) - s_pos[:y]
            tag_h = [wrapped_h, tag_h * 3, 0.035].max
          else
            tag_h = [tag_h * 3, 0.035].max
          end
        when 'image', 'stamp'
          tag_h = [tag_h * 3, 0.035].max
        end
        
        # Clamp to page
        tag_x = [[tag_x, 0.0].max, 0.95].min
        tag_y = [[tag_y, 0.0].max, 0.95].min
        tag_w = [[tag_w, 0.03].max, 0.48].min
        tag_h = [[tag_h, 0.012].max, 0.06].min
        
        tags << { tag_content: tag_content, page: page_index, x: tag_x, y: tag_y, w: tag_w, h: tag_h }
        
        Rails.logger.info("ParsePdfTextTags: '#{field_name}' (#{field_def[:type]}) at (#{tag_x.round(3)}, #{tag_y.round(3)}) size=(#{tag_w.round(3)}x#{tag_h.round(3)})")
      end
      
      tags
    end
    
    # Detect table cell boundaries by analyzing text node positions
    # Returns { x:, y:, w:, h: } of the cell containing the tag, or nil if not in a table
    #
    # Detection strategy:
    # 1. Find text nodes at a similar Y position (same row)
    # 2. Group them by distinct X ranges (columns)
    # 3. If there are multiple columns, this suggests a table structure
    # 4. Find the column boundaries for the cell containing the tag
    def detect_table_cell_bounds(chars_with_positions, tag_x, tag_y, tag_h)
      return nil if chars_with_positions.empty?
      
      # Y tolerance: text nodes on the "same row" should be within this range
      y_tolerance = [tag_h * 2.5, 0.025].max
      
      # Find all text nodes at a similar Y position (same visual row)
      same_row_nodes = chars_with_positions.select do |node|
        (node[:y] - tag_y).abs < y_tolerance
      end
      
      return nil if same_row_nodes.size < 2
      
      # Collect distinct X positions to detect column boundaries
      # Group nodes by their X position into "columns" using gap detection
      x_positions = same_row_nodes.map { |n| n[:x] }.sort.uniq
      
      return nil if x_positions.size < 2
      
      # Find significant gaps in X positions that indicate column boundaries
      # A gap larger than the threshold suggests a cell boundary
      gap_threshold = 0.03  # 3% of page width minimum gap between columns
      
      # Use actual content boundaries (not page edges 0.0/1.0)
      # to avoid treating page margins as cell boundaries
      content_left = x_positions.first
      content_right = same_row_nodes.map { |n| (n[:endx] || n[:x] + (n[:w] || 0.01)) }.max || 1.0
      
      # Start with the leftmost content position (with small margin)
      column_boundaries = [[content_left - 0.02, 0.0].max]
      
      prev_x = x_positions.first
      x_positions.each do |x|
        if x - prev_x > gap_threshold
          # Found a gap - this is a column boundary
          # The boundary is midway between the end of previous content and start of next
          column_boundaries << (prev_x + x) / 2.0
        end
        prev_x = x
      end
      
      # End with the rightmost content position (with small margin)
      column_boundaries << [content_right + 0.02, 1.0].min
      
      # Need at least 3 boundaries (2 columns) to be considered a table
      return nil if column_boundaries.size < 3
      
      # Find which column contains our tag
      cell_left = 0.0
      cell_right = 1.0
      
      column_boundaries.each_cons(2) do |left, right|
        if tag_x >= left && tag_x < right
          cell_left = left
          cell_right = right
          break
        end
      end
      
      cell_w = cell_right - cell_left
      
      # Sanity check: cell should be reasonable size (not the whole page)
      return nil if cell_w > 0.8 || cell_w < 0.05
      
      # Also check for multiple rows at similar X to further confirm table structure
      # Look for text nodes above and below with similar column structure
      nearby_rows = chars_with_positions.select do |node|
        (node[:y] - tag_y).abs < y_tolerance * 4 && (node[:y] - tag_y).abs > y_tolerance * 0.5
      end
      
      # If there are nearby rows with content in the same column range, it's likely a table
      has_adjacent_rows = nearby_rows.any? do |node|
        node[:x] >= cell_left && node[:x] < cell_right
      end
      
      # Require adjacent rows to confirm table structure
      return nil unless has_adjacent_rows
      
      # Calculate cell height from row spacing
      all_y_positions = chars_with_positions
        .select { |n| n[:x] >= cell_left && n[:x] < cell_right }
        .map { |n| n[:y] }
        .sort
        .uniq
      
      # Find the Y boundaries for this row
      cell_top = tag_y
      cell_bottom = tag_y + tag_h
      
      all_y_positions.each_cons(2) do |y1, y2|
        if y1 <= tag_y && y2 > tag_y
          cell_top = y1
          cell_bottom = y2
          break
        end
      end
      
      cell_h = [cell_bottom - cell_top, tag_h * 1.5].max
      
      {
        x: cell_left,
        y: cell_top,
        w: cell_w,
        h: cell_h
      }
    end

    # Find start/end indices of a tag sequence in Pdfium characters.
    # This matches the full tag content (including braces) while skipping
    # whitespace, hyphenation artifacts, and characters from OTHER table columns.
    #
    # IMPORTANT: Pdfium text nodes can be single characters OR multi-character
    # words/chunks. We first expand all nodes into individual characters, each
    # carrying the parent node's (x, y) position, then do character-by-character
    # matching. For multi-line tags in tables, we skip chars whose X is too far
    # from the match start (they belong to a different column).
    #
    # Returns [start_node_idx, end_node_idx] in the original chars_with_positions.
    def find_tag_positions_in_chars(chars_with_positions, tag_content)
      return [nil, nil] if tag_content.blank? || chars_with_positions.blank?

      target = "{{#{tag_content}}}"
      target_compact = target.gsub(/\s+/, '')
      target_len = target_compact.length

      # Expand multi-character nodes into individual characters,
      # each mapped back to its parent node index and carrying x position
      expanded = []  # Array of { char: 'x', node_idx: N, x: Float }
      chars_with_positions.each_with_index do |entry, node_idx|
        entry[:char].to_s.each_char do |c|
          expanded << { char: c, node_idx: node_idx, x: entry[:x].to_f }
        end
      end

      (0...expanded.length).each do |start_idx|
        j = 0
        k = start_idx
        first_k = nil
        match_x = nil  # X position of match start (to filter same column)

        while k < expanded.length && j < target_len
          ch = expanded[k][:char]
          ch_x = expanded[k][:x]

          # Once we've started matching, skip characters from OTHER columns.
          # Characters in the same column should have X within ±0.25 of start.
          if match_x && (ch_x - match_x).abs > 0.25
            k += 1
            next
          end

          # Skip whitespace in source
          if ch.match?(/\A\s\z/)
            k += 1
            next
          end

          # Skip hyphenation artifacts if target doesn't expect them
          if ch.match?(/\A[-\u00AD\u2010\u2011\u2012]\z/) && target_compact[j] != ch
            k += 1
            next
          end

          if ch == target_compact[j]
            if first_k.nil?
              first_k = k
              match_x = ch_x
            end
            j += 1
            k += 1
            next
          end

          # Mismatch
          break
        end

        if j == target_len && first_k
          start_node = expanded[first_k][:node_idx]
          end_node = expanded[k - 1][:node_idx]
          return [start_node, end_node]
        end
      end

      [nil, nil]
    end
    
    # Fallback extraction from PDF data
    def extract_tags_fallback_from_data(pdf_or_data, attachment)
      fields = []
      
      # Try to extract text and group by role
      begin
        if pdf_or_data.is_a?(String)
          doc = Pdfium::Document.open_bytes(pdf_or_data)
        elsif pdf_or_data.respond_to?(:read)
          doc = Pdfium::Document.open_bytes(pdf_or_data.read)
        else
          # HexaPDF document - use existing fallback
          return extract_tags_fallback(pdf_or_data, attachment)
        end
        
        last_page = doc.page_count - 1
        
        # Extract all text to find tags
        all_text = ''
        (0...doc.page_count).each do |page_index|
          page = doc.get_page(page_index)
          page.text_nodes.each { |n| all_text += n.content.to_s }
          page.close
        end
        
        doc.close
        
        # Find all tags
        tags_by_role = {}
        all_text.scan(TAG_REGEX).each do |match|
          tag_content = match[0]
          field_def = parse_tag(tag_content)
          next if field_def.blank?
          
          role = (field_def[:role] || 'default').to_s.downcase
          tags_by_role[role] ||= []
          tags_by_role[role] << field_def
        end
        
        # Position fields by role
        num_roles = [tags_by_role.keys.size, 2].max
        tags_by_role.each_with_index do |(role, role_fields), role_idx|
          column = determine_column_for_role(role, role_idx, num_roles)
          base_x = column == :left ? 0.08 : 0.52
          
          role_fields.each_with_index do |field_def, idx|
            y_position = 0.75 + (idx * 0.06)
            
            case field_def[:type]
            when 'signature', 'initials'
              w, h = 0.35, 0.05
            when 'date', 'datenow'
              w, h = 0.15, 0.025
            else
              w, h = 0.25, 0.025
            end
            
            field_def[:uuid] = SecureRandom.uuid
            field_def[:areas] = [{
              page: last_page,
              x: base_x,
              y: [y_position, 0.92].min,
              w: w,
              h: h,
              attachment_uuid: attachment.uuid
            }]
            
            fields << field_def
            Rails.logger.info("ParsePdfTextTags: Fallback - #{field_def[:name]} -> role=#{role} col=#{column}")
          end
        end
      rescue StandardError => e
        Rails.logger.warn("ParsePdfTextTags: Fallback extraction failed: #{e.message}")
      end
      
      fields
    end
    
    # Extract tags using HexaPDF (legacy, kept for backward compatibility)
    def extract_tags_using_glyphs(pdf)
      all_tags = []
      
      pdf.pages.each_with_index do |page, page_index|
        page_width = page.box(:media).width rescue 612
        page_height = page.box(:media).height rescue 792
        
        Rails.logger.info("ParsePdfTextTags: Processing page #{page_index} with HexaPDF, size #{page_width}x#{page_height}")
        
        # Use GlyphCollector with page reference for font decoding
        collector = GlyphCollector.new(page_index, page_width, page_height, page)
        
        begin
          page.process_contents(collector)
          glyphs = collector.glyphs
          
          Rails.logger.info("ParsePdfTextTags: Collected #{glyphs.size} glyphs from page #{page_index}")
          
          if glyphs.any?
            sample_text = glyphs.take(50).map { |g| g[:char] }.join
            Rails.logger.info("ParsePdfTextTags: Sample text: #{sample_text}")
          end
          
          tags = find_tags_in_glyphs(glyphs, page_index, page_width, page_height)
          all_tags.concat(tags)
        rescue StandardError => e
          Rails.logger.warn("ParsePdfTextTags: Error processing page #{page_index}: #{e.message}")
          Rails.logger.warn(e.backtrace.first(3).join("\n"))
        end
      end
      
      all_tags
    end
    
    # Find {{...}} tags in the glyph stream
    def find_tags_in_glyphs(glyphs, page_index, page_width, page_height)
      tags = []
      return tags if glyphs.empty?
      
      # Build full text and track character positions
      full_text = ''
      char_positions = []  # Array of {char:, x:, y:, width:, height:}
      
      glyphs.each do |g|
        full_text += g[:char]
        char_positions << g
      end
      
      # Analyze Y coordinates to detect coordinate system
      # LibreOffice PDFs often use top-left origin (Y increases downward)
      # Standard PDF uses bottom-left origin (Y increases upward)
      y_values = char_positions.map { |g| g[:y] }.compact
      if y_values.any?
        min_y = y_values.min
        max_y = y_values.max
        avg_y = y_values.sum / y_values.size
        
        # If most Y values are small (< page_height/2), it's likely top-left origin
        # If most Y values are large (> page_height/2), it's likely bottom-left origin
        y_is_top_origin = avg_y < (page_height / 2)
        
        Rails.logger.info("ParsePdfTextTags: Y range: #{min_y.round(1)}-#{max_y.round(1)}, avg: #{avg_y.round(1)}, page_height: #{page_height}")
        Rails.logger.info("ParsePdfTextTags: Detected coordinate system: #{y_is_top_origin ? 'top-left (LibreOffice)' : 'bottom-left (standard)'}")
      else
        y_is_top_origin = false
      end
      
      Rails.logger.info("ParsePdfTextTags: Full text length: #{full_text.length}, sample: #{full_text[0..100]}...")
      
      # Find all {{...}} tags
      full_text.scan(TAG_REGEX) do |match|
        tag_content = match[0]
        full_tag = "{{#{tag_content}}}"
        
        # Find all occurrences of this tag
        start_idx = 0
        while (idx = full_text.index(full_tag, start_idx))
          # Get the position of the first character of the tag
          tag_start_pos = char_positions[idx]
          
          # Get the position of the last character of the tag
          tag_end_idx = idx + full_tag.length - 1
          tag_end_pos = char_positions[tag_end_idx] if tag_end_idx < char_positions.length
          
          if tag_start_pos
            # Calculate tag bounds
            tag_x = tag_start_pos[:x]
            tag_y = tag_start_pos[:y]
            tag_height = tag_start_pos[:height]
            
            Rails.logger.info("ParsePdfTextTags: Raw tag position - x:#{tag_x.round(1)}, y:#{tag_y.round(1)}, h:#{tag_height.round(1)}")
            
            # Calculate width from start to end position
            if tag_end_pos
              tag_width = (tag_end_pos[:x] + tag_end_pos[:width]) - tag_x
            else
              # Estimate width based on character count
              avg_width = tag_start_pos[:width]
              tag_width = full_tag.length * avg_width
            end
            
            # Ensure minimum size
            tag_width = [tag_width, 50].max
            tag_height = [tag_height, 10].max
            
            # Convert to normalized coordinates (0-1, top-left origin)
            norm_x = tag_x / page_width
            
            if y_is_top_origin
              # Y is already in top-left coordinate system (Y increases downward from top)
              # Just normalize it directly
              norm_y = tag_y / page_height
            else
              # Standard PDF: Y increases upward from bottom
              # Convert to top-left: norm_y = 1 - (y + height) / page_height
              norm_y = 1.0 - (tag_y + tag_height) / page_height
            end
            
            norm_w = tag_width / page_width
            norm_h = tag_height / page_height
            
            Rails.logger.info("ParsePdfTextTags: Normalized position - x:#{norm_x.round(3)}, y:#{norm_y.round(3)}")
            
            # Clamp and adjust
            norm_x = [[norm_x, 0.0].max, 0.9].min
            norm_y = [[norm_y, 0.0].max, 0.9].min
            norm_w = [[norm_w, 0.08].max, 0.4].min
            norm_h = [[norm_h, 0.02].max, 0.08].min
            
            # Adjust size based on field type
            field_def = parse_tag(tag_content)
            if field_def.present?
              case field_def[:type]
              when 'signature', 'initials'
                norm_w = [norm_w, 0.18].max
                norm_h = [norm_h, 0.05].max
              when 'text'
                norm_w = [norm_w, 0.15].max
                norm_h = [norm_h, 0.028].max
              when 'date', 'datenow'
                norm_w = [norm_w, 0.12].max
                norm_h = [norm_h, 0.028].max
              end
            end
            
            tags << {
              tag_content: tag_content,
              page: page_index,
              x: norm_x,
              y: norm_y,
              w: norm_w,
              h: norm_h,
              pdf_x: tag_x,
              pdf_y: tag_y
            }
            
            Rails.logger.info("ParsePdfTextTags: Tag '#{tag_content[0..20]}...' at PDF(#{tag_x.round(1)}, #{tag_y.round(1)}) -> norm(#{norm_x.round(3)}, #{norm_y.round(3)})")
          end
          
          start_idx = idx + 1
        end
      end
      
      tags
    end
    
    # Fallback extraction when precise positioning fails
    def extract_tags_fallback(pdf, attachment)
      fields = []
      
      pdf.pages.each_with_index do |page, page_index|
        page_text = extract_page_text(page)
        normalized = page_text.gsub(/\s+/, ' ')
        
        # Find all tags
        tag_matches = normalized.scan(TAG_REGEX).flatten
        
        # Group tags by role to distribute them in columns
        tags_by_role = {}
        tag_matches.each do |tag_content|
          field_def = parse_tag(tag_content)
          next if field_def.blank?
          
          role = (field_def[:role] || 'default').to_s.downcase
          tags_by_role[role] ||= []
          tags_by_role[role] << { tag_content: tag_content, field_def: field_def }
        end
        
        # Position each role's tags in columns
        num_roles = [tags_by_role.keys.size, 2].max
        tags_by_role.each_with_index do |(role, role_tags), role_idx|
          # Determine column (left vs right based on role)
          column = determine_column_for_role(role, role_idx, num_roles)
          base_x = column == :left ? 0.08 : 0.52
          
          role_tags.each_with_index do |tag_info, idx|
            field_def = tag_info[:field_def].dup
            field_def[:uuid] = SecureRandom.uuid
            
            # Stack fields vertically within each column
            y_position = 0.75 + (idx * 0.06)
            
            # Size based on field type
            case field_def[:type]
            when 'signature', 'initials'
              w = 0.35
              h = 0.05
            when 'date', 'datenow'
              w = 0.15
              h = 0.025
            else
              w = 0.25
              h = 0.025
            end
            
            field_def[:areas] = [{
              page: page_index,
              x: base_x,
              y: [y_position, 0.92].min,
              w: w,
              h: h,
              attachment_uuid: attachment.uuid
            }]
            
            fields << field_def
            Rails.logger.info("ParsePdfTextTags: Fallback - #{field_def[:name]} (#{field_def[:type]}) -> role=#{role} col=#{column}")
          end
        end
      end
      
      fields
    end
    
    # Determine column placement based on role name
    def determine_column_for_role(role, role_idx, num_roles)
      role_lower = role.to_s.downcase
      
      # Common left-side roles (first party)
      left_roles = %w[buyer first customer client tenant employee applicant borrower patient]
      # Common right-side roles (second party)
      right_roles = %w[seller second vendor supplier landlord employer company lender doctor provider]
      
      return :left if left_roles.any? { |r| role_lower.include?(r) }
      return :right if right_roles.any? { |r| role_lower.include?(r) }
      
      # Default: alternate based on index
      role_idx.even? ? :left : :right
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

    # Legacy method - kept for compatibility
    def extract_text_with_positions(pdf)
      text_items = []

      pdf.pages.each_with_index do |page, page_index|
        page_width = page.box(:media).width rescue 612
        page_height = page.box(:media).height rescue 792

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

    # Legacy method - kept for compatibility
    def calculate_field_area(text_item, attachment)
      page_height = text_item[:page_height].to_f
      page_width = text_item[:page_width].to_f
      
      # Convert PDF coordinates (bottom-left origin) to normalized (top-left, 0-1)
      norm_y = 1.0 - (text_item[:y] + text_item[:height]) / page_height
      
      {
        page: text_item[:page],
        x: text_item[:x] / page_width,
        y: [[norm_y, 0.0].max, 0.95].min,
        w: [text_item[:width] / page_width, 0.15].max,
        h: [text_item[:height] / page_height, 0.03].max,
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
    # Accepts either raw PDF data (String/IO) or HexaPDF document
    def contains_tags?(pdf_or_data)
      all_text = ''
      
      # Try Pdfium first (most reliable for LibreOffice PDFs)
      if pdf_or_data.is_a?(String)
        all_text = extract_text_with_pdfium(pdf_or_data)
      elsif pdf_or_data.respond_to?(:read)
        all_text = extract_text_with_pdfium(pdf_or_data.read)
      else
        # HexaPDF document - use existing method
        pdf_or_data.pages.each do |page|
          page_text = extract_page_text_with_decoding(page)
          all_text += page_text
        end
      end
      
      # Remove whitespace and newlines before checking for tags
      # This handles tags split across lines
      normalized_text = all_text.gsub(/\s+/, ' ')
      has_tags = normalized_text.match?(TAG_REGEX)
      
      Rails.logger.info("ParsePdfTextTags.contains_tags?: #{has_tags}, text length: #{normalized_text.length}")
      Rails.logger.info("ParsePdfTextTags: Text sample: #{normalized_text[0..300]}...") if normalized_text.length > 0
      
      has_tags
    rescue StandardError => e
      Rails.logger.warn("ParsePdfTextTags.contains_tags? error: #{e.message}")
      Rails.logger.warn(e.backtrace.first(3).join("\n"))
      false
    end
    
    # Extract all text from PDF using Pdfium
    # This properly handles font decoding which is essential for LibreOffice PDFs
    def extract_text_with_pdfium(pdf_data)
      all_text = ''
      
      begin
        doc = Pdfium::Document.open_bytes(pdf_data)
        
        (0...doc.page_count).each do |page_index|
          page = doc.get_page(page_index)
          page.text_nodes.each { |node| all_text += node.content.to_s }
          page.close
        end
        
        doc.close
        Rails.logger.info("ParsePdfTextTags: Pdfium extracted #{all_text.length} chars")
      rescue StandardError => e
        Rails.logger.warn("ParsePdfTextTags: Pdfium text extraction failed: #{e.message}")
      end
      
      all_text
    end

    # Extract text from page with proper font decoding
    # LibreOffice PDFs encode text using font-specific encodings
    def extract_page_text_with_decoding(page)
      text = ''
      
      # Method 1: Try HexaPDF's show_text_processor which decodes text
      processor = DecodingTextProcessor.new(page)
      begin
        page.process_contents(processor)
        text = processor.text
        Rails.logger.info("ParsePdfTextTags: Extracted #{text.length} chars using DecodingTextProcessor")
      rescue StandardError => e
        Rails.logger.warn("ParsePdfTextTags: DecodingTextProcessor failed: #{e.message}")
      end
      
      # Method 2: If that didn't work, try extracting via content stream parsing
      if text.blank?
        begin
          # Try to get text from page's content stream directly
          processor2 = SimpleTextProcessor.new
          page.process_contents(processor2)
          raw_text = processor2.text
          Rails.logger.info("ParsePdfTextTags: Got #{raw_text.length} chars raw, checking for tags pattern")
          
          # Even raw text might contain the tag pattern
          text = raw_text if raw_text.match?(TAG_REGEX)
        rescue StandardError => e
          Rails.logger.warn("ParsePdfTextTags: SimpleTextProcessor failed: #{e.message}")
        end
      end
      
      text
    rescue StandardError => e
      Rails.logger.warn("ParsePdfTextTags: extract_page_text_with_decoding error: #{e.message}")
      ''
    end

    def extract_page_text(page)
      extract_page_text_with_decoding(page)
    end

    # Text processor that decodes text using the current font
    # This is essential for PDFs from LibreOffice/Gotenberg which use font encodings
    class DecodingTextProcessor
      attr_reader :text
      
      def initialize(page)
        @page = page
        @text = ''
        @font = nil
        @font_size = 12
        @resources = page[:Resources] rescue nil
      end
      
      def set_font(font_name, size)
        @font_size = size.to_f.abs
        @font_size = 12 if @font_size < 1
        
        # Get the font object from resources
        begin
          if @resources && @resources[:Font]
            font_dict = @resources[:Font]
            @font = font_dict[font_name] if font_dict
          end
        rescue StandardError => e
          Rails.logger.debug("DecodingTextProcessor: Could not get font #{font_name}: #{e.message}")
        end
      end
      
      def show_text(str)
        decoded = decode_string(str)
        @text += decoded
      end
      
      def show_text_with_positioning(array)
        return if array.nil?
        
        array.each do |item|
          if item.is_a?(String)
            decoded = decode_string(item)
            @text += decoded
          end
          # Ignore numeric positioning values
        end
      end
      
      def show_text_with_new_line(str)
        decoded = decode_string(str)
        @text += decoded + "\n"
      end
      
      def show_text_with_new_line_and_spacing(word_spacing, char_spacing, str)
        decoded = decode_string(str)
        @text += decoded + "\n"
      end
      
      def begin_text; end
      def end_text; end
      def move_text(tx, ty); end
      def move_text_and_set_leading(tx, ty); end
      def move_to_next_line; @text += "\n"; end
      def set_text_matrix(a, b, c, d, e, f); end
      def set_character_spacing(spacing); end
      def set_word_spacing(spacing); end
      def set_horizontal_scaling(scaling); end
      def set_text_rise(rise); end
      def save_graphics_state; end
      def restore_graphics_state; end
      def concatenate_matrix(a, b, c, d, e, f); end
      
      def process(*args)
        # Generic handler
      end
      
      def method_missing(_method, *_args)
        # Ignore unhandled PDF operators
      end
      
      def respond_to_missing?(_method, _include_private = false)
        true
      end
      
      private
      
      def decode_string(str)
        return '' if str.nil?
        
        str = str.to_s
        return str if str.empty?
        
        # Try to decode using the font if available
        if @font
          begin
            # HexaPDF font objects have a decode method
            if @font.respond_to?(:decode)
              return @font.decode(str).map { |code, _| code }.join
            elsif @font.respond_to?(:decode_utf8)
              return @font.decode_utf8(str)
            end
          rescue StandardError => e
            Rails.logger.debug("DecodingTextProcessor: Font decode failed: #{e.message}")
          end
        end
        
        # Fallback: Try common encodings
        begin
          # First, try to interpret as UTF-16BE (common in PDFs)
          if str.bytesize >= 2 && str.bytes[0..1] == [254, 255]
            # UTF-16BE with BOM
            return str[2..].force_encoding('UTF-16BE').encode('UTF-8')
          end
          
          # Try as PDFDocEncoding / WinAnsiEncoding
          # Map common character codes to their actual characters
          decoded = str.bytes.map do |byte|
            case byte
            when 0x00..0x1F then '' # Control characters
            when 0x20..0x7E then byte.chr # ASCII printable
            when 0x80..0xFF
              # Try to map extended characters
              WIN_ANSI_MAP[byte] || byte.chr(Encoding::ISO_8859_1)
            else
              byte.chr rescue ''
            end
          end.join
          
          return decoded unless decoded.empty?
        rescue StandardError => e
          Rails.logger.debug("DecodingTextProcessor: Encoding conversion failed: #{e.message}")
        end
        
        # Last resort: return as-is but force to UTF-8
        str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      end
    end
    
    # WinAnsiEncoding map for bytes 0x80-0xFF
    WIN_ANSI_MAP = {
      0x80 => '€', 0x82 => '‚', 0x83 => 'ƒ', 0x84 => '„', 0x85 => '…',
      0x86 => '†', 0x87 => '‡', 0x88 => 'ˆ', 0x89 => '‰', 0x8A => 'Š',
      0x8B => '‹', 0x8C => 'Œ', 0x8E => 'Ž', 0x91 => ''', 0x92 => ''',
      0x93 => '"', 0x94 => '"', 0x95 => '•', 0x96 => '–', 0x97 => '—',
      0x98 => '˜', 0x99 => '™', 0x9A => 'š', 0x9B => '›', 0x9C => 'œ',
      0x9E => 'ž', 0x9F => 'Ÿ'
    }.freeze

    # Simple text processor - collects raw text without decoding
    class SimpleTextProcessor
      attr_reader :text

      def initialize
        @text = ''
      end

      def process(*args)
        # Handle different method signatures
      end

      def show_text(str)
        # Convert bytes to string, handling various encodings
        if str.respond_to?(:bytes)
          # Try to extract readable characters
          readable = str.bytes.select { |b| b >= 0x20 && b <= 0x7E }.pack('C*')
          @text += readable
        else
          @text += str.to_s
        end
      end

      def show_text_with_positioning(array)
        return if array.nil?
        
        array.each do |item|
          if item.is_a?(String)
            show_text(item)
          end
        end
      end

      def set_font(font, size); end
      def begin_text; end
      def end_text; end
      def move_text(tx, ty); end
      def set_text_matrix(a, b, c, d, e, f); end
      
      def method_missing(_method, *_args)
        # Ignore other PDF operators
      end

      def respond_to_missing?(_method, _include_private = false)
        true
      end
    end
    
    # GlyphCollector - Collects text with positions using simple matrix math
    # Works with both standard PDFs (bottom-left origin) and LibreOffice PDFs (top-left origin)
    # Now includes font decoding for LibreOffice PDFs
    class GlyphCollector
      attr_reader :glyphs
      
      def initialize(page_index, page_width, page_height, page = nil)
        @page_index = page_index
        @page_width = page_width
        @page_height = page_height
        @page = page
        @glyphs = []
        @logged_sample = false
        
        # Track graphics and text state using simple arrays [a, b, c, d, e, f]
        @gs_stack = []
        @ctm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]  # Identity matrix
        @font = nil
        @font_name = nil
        @font_size = 12
        @text_matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        @text_line_matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        
        # Get page resources for font lookup
        @resources = page[:Resources] rescue nil if page
      end
      
      # Called by HexaPDF when glyphs are rendered with positions
      def show_glyphs(glyphs)
        return if glyphs.nil? || glyphs.empty?
        
        glyphs.each do |glyph|
          next unless glyph
          
          char = extract_char(glyph)
          next if char.blank?
          
          x, y = extract_position(glyph)
          width = extract_width(glyph)
          
          @glyphs << {
            char: char,
            x: x,
            y: y,
            width: width,
            height: @font_size,
            page: @page_index
          }
        end
      end
      
      # Graphics state
      def save_graphics_state
        @gs_stack.push({
          ctm: @ctm.dup,
          font: @font,
          font_name: @font_name,
          font_size: @font_size
        })
      end
      
      def restore_graphics_state
        if @gs_stack.any?
          gs = @gs_stack.pop
          @ctm = gs[:ctm]
          @font = gs[:font]
          @font_name = gs[:font_name]
          @font_size = gs[:font_size]
        end
      end
      
      # Transformation - cm operator
      def concatenate_matrix(a, b, c, d, e, f)
        # Premultiply: new_ctm = [a,b,c,d,e,f] × current_ctm
        @ctm = multiply_matrices([a.to_f, b.to_f, c.to_f, d.to_f, e.to_f, f.to_f], @ctm)
        
        # Log first CTM for debugging
        unless @logged_sample
          Rails.logger.info("ParsePdfTextTags: CTM set to [#{@ctm.map { |v| v.round(2) }.join(', ')}]")
          @logged_sample = true
        end
      end
      
      # Text state - Tf operator
      def set_font(font_name, size)
        @font_name = font_name
        @font_size = size.to_f.abs
        @font_size = 12 if @font_size < 1
        
        # Try to get the font object from page resources for decoding
        begin
          if @resources && @resources[:Font]
            font_dict = @resources[:Font]
            @font = font_dict[font_name] if font_dict && font_name
          end
        rescue StandardError => e
          Rails.logger.debug("GlyphCollector: Could not get font: #{e.message}")
        end
      end
      
      def begin_text
        @text_matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
        @text_line_matrix = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0]
      end
      
      def end_text
        # Nothing specific to do
      end
      
      # Tm operator - set text matrix
      def set_text_matrix(a, b, c, d, e, f)
        @text_matrix = [a.to_f, b.to_f, c.to_f, d.to_f, e.to_f, f.to_f]
        @text_line_matrix = @text_matrix.dup
      end
      
      # Td operator - move text position
      def move_text(tx, ty)
        # text_line_matrix = translate(tx, ty) × text_line_matrix
        translation = [1.0, 0.0, 0.0, 1.0, tx.to_f, ty.to_f]
        @text_line_matrix = multiply_matrices(translation, @text_line_matrix)
        @text_matrix = @text_line_matrix.dup
      end
      
      def move_text_and_set_leading(tx, ty)
        move_text(tx, ty)
      end
      
      def move_to_next_line
        move_text(0, -@font_size * 1.2)
      end
      
      # Tj operator - show text
      def show_text(str)
        return if str.blank?
        
        # Decode the string using font encoding
        decoded_str = decode_text(str)
        return if decoded_str.blank?
        
        # Get text position from text matrix
        tx = @text_matrix[4]  # e component
        ty = @text_matrix[5]  # f component
        
        # Transform through CTM: [x', y'] = [x, y] × CTM
        # For a point (x, y) and matrix [a, b, c, d, e, f]:
        # x' = a*x + c*y + e
        # y' = b*x + d*y + f
        final_x = @ctm[0] * tx + @ctm[2] * ty + @ctm[4]
        final_y = @ctm[1] * tx + @ctm[3] * ty + @ctm[5]
        
        # Calculate character width
        char_width = @font_size * 0.5
        
        # Add each character
        decoded_str.each_char.with_index do |char, idx|
          @glyphs << {
            char: char,
            x: final_x + (idx * char_width),
            y: final_y,
            width: char_width,
            height: @font_size,
            page: @page_index
          }
        end
        
        # Advance text position
        advance = str.length * char_width
        @text_matrix[4] += advance
      end
      
      # TJ operator - show text with positioning
      def show_text_with_positioning(array)
        return if array.nil?
        
        array.each do |item|
          if item.is_a?(String)
            show_text(item)
          elsif item.is_a?(Numeric)
            # Kerning adjustment in thousandths of em
            # Negative values move right (add to position)
            adjustment = -item.to_f / 1000.0 * @font_size
            @text_matrix[4] += adjustment
          end
        end
      end
      
      def show_text_with_new_line(str)
        move_to_next_line
        show_text(str)
      end
      
      def show_text_with_new_line_and_spacing(word_spacing, char_spacing, str)
        move_to_next_line
        show_text(str)
      end
      
      def set_character_spacing(spacing); end
      def set_word_spacing(spacing); end
      def set_horizontal_scaling(scaling); end
      def set_text_rise(rise); end
      
      def process(*args)
        # Generic handler
      end
      
      def method_missing(_method, *_args)
        # Ignore unhandled PDF operators
      end
      
      def respond_to_missing?(_method, _include_private = false)
        true
      end
      
      private
      
      def extract_char(glyph)
        if glyph.respond_to?(:str)
          glyph.str.to_s
        elsif glyph.respond_to?(:char)
          glyph.char.to_s
        elsif glyph.respond_to?(:[])
          (glyph[:str] || glyph[:char] || '').to_s
        else
          glyph.to_s
        end
      end
      
      def extract_position(glyph)
        x = 0
        y = 0
        
        if glyph.respond_to?(:x) && glyph.respond_to?(:y)
          x = glyph.x.to_f
          y = glyph.y.to_f
        elsif glyph.respond_to?(:[])
          x = (glyph[:x] || 0).to_f
          y = (glyph[:y] || 0).to_f
        end
        
        [x, y]
      end
      
      def extract_width(glyph)
        if glyph.respond_to?(:width)
          glyph.width.to_f
        elsif glyph.respond_to?(:[])
          (glyph[:width] || @font_size * 0.5).to_f
        else
          @font_size * 0.5
        end
      end
      
      # Multiply two 2D affine transformation matrices
      # Matrix format: [a, b, c, d, e, f] represents:
      # | a  b  0 |
      # | c  d  0 |
      # | e  f  1 |
      def multiply_matrices(m1, m2)
        [
          m1[0] * m2[0] + m1[1] * m2[2],           # a
          m1[0] * m2[1] + m1[1] * m2[3],           # b
          m1[2] * m2[0] + m1[3] * m2[2],           # c
          m1[2] * m2[1] + m1[3] * m2[3],           # d
          m1[4] * m2[0] + m1[5] * m2[2] + m2[4],   # e
          m1[4] * m2[1] + m1[5] * m2[3] + m2[5]    # f
        ]
      end
      
      # Decode text string using font encoding
      # LibreOffice PDFs use font-specific encodings that need to be decoded
      def decode_text(str)
        return '' if str.nil?
        
        str = str.to_s
        return str if str.empty?
        
        # Try to decode using the font if available
        if @font
          begin
            if @font.respond_to?(:decode)
              # HexaPDF font decode returns array of [unicode_char, width] pairs
              decoded = @font.decode(str)
              if decoded.is_a?(Array)
                result = decoded.map do |code, _width|
                  if code.is_a?(Integer)
                    begin
                      code.chr(Encoding::UTF_8)
                    rescue StandardError
                      ''
                    end
                  else
                    code.to_s
                  end
                end.join
                return result
              end
              return decoded.to_s
            elsif @font.respond_to?(:decode_utf8)
              return @font.decode_utf8(str)
            end
          rescue StandardError => e
            # Font decode failed, try other methods
          end
        end
        
        # Try to interpret the bytes directly
        begin
          bytes = str.bytes
          
          # Check for UTF-16BE BOM
          if bytes.length >= 2 && bytes[0] == 254 && bytes[1] == 255
            return str[2..].force_encoding('UTF-16BE').encode('UTF-8')
          end
          
          # Try to extract readable ASCII characters and common bracket chars
          decoded = bytes.map do |byte|
            case byte
            when 0x7B then '{' # Opening brace
            when 0x7D then '}' # Closing brace
            when 0x3B then ';' # Semicolon
            when 0x3D then '=' # Equals
            when 0x20..0x7E then byte.chr # ASCII printable
            when 0x80..0xFF
              # WinAnsiEncoding
              WIN_ANSI_MAP[byte] || byte.chr(Encoding::ISO_8859_1) rescue ''
            else
              '' # Skip control characters
            end
          end.join
          
          return decoded unless decoded.empty?
        rescue StandardError
          # Ignore encoding errors
        end
        
        # Last resort: force to UTF-8, keeping only valid characters
        str.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      end
    end
    
    # Fragment collector - collects individual text fragments with their exact positions
    # This is more reliable than the old TextPositionProcessor because it:
    # 1. Tracks the current transformation matrix (CTM) properly
    # 2. Handles text positioning operators correctly
    # 3. Works with tables and complex layouts
    class FragmentCollector
      attr_reader :fragments
      
      def initialize(page_index, page_width, page_height)
        @page_index = page_index
        @page_width = page_width
        @page_height = page_height
        @fragments = []
        
        # Graphics state stack
        @gs_stack = []
        @ctm = [1, 0, 0, 1, 0, 0]  # Current transformation matrix (identity)
        
        # Text state
        @text_matrix = [1, 0, 0, 1, 0, 0]
        @text_line_matrix = [1, 0, 0, 1, 0, 0]
        @font_size = 12
        @char_spacing = 0
        @word_spacing = 0
        @horizontal_scaling = 100
        @text_rise = 0
      end
      
      # Graphics state operators
      def save_graphics_state
        @gs_stack.push({
          ctm: @ctm.dup,
          font_size: @font_size,
          char_spacing: @char_spacing,
          word_spacing: @word_spacing,
          horizontal_scaling: @horizontal_scaling,
          text_rise: @text_rise
        })
      end
      
      def restore_graphics_state
        if @gs_stack.any?
          gs = @gs_stack.pop
          @ctm = gs[:ctm]
          @font_size = gs[:font_size]
          @char_spacing = gs[:char_spacing]
          @word_spacing = gs[:word_spacing]
          @horizontal_scaling = gs[:horizontal_scaling]
          @text_rise = gs[:text_rise]
        end
      end
      
      # Transformation matrix operators
      def concatenate_matrix(a, b, c, d, e, f)
        # Multiply CTM by the new matrix
        @ctm = multiply_matrix(@ctm, [a, b, c, d, e, f])
      end
      
      # Text state operators
      def set_font(font, size)
        @font_size = size.to_f.abs
        @font_size = 12 if @font_size < 1
      end
      
      def set_character_spacing(spacing)
        @char_spacing = spacing.to_f
      end
      
      def set_word_spacing(spacing)
        @word_spacing = spacing.to_f
      end
      
      def set_horizontal_scaling(scaling)
        @horizontal_scaling = scaling.to_f
      end
      
      def set_text_rise(rise)
        @text_rise = rise.to_f
      end
      
      # Text positioning operators
      def begin_text
        @text_matrix = [1, 0, 0, 1, 0, 0]
        @text_line_matrix = [1, 0, 0, 1, 0, 0]
      end
      
      def end_text
        # Nothing to do
      end
      
      def set_text_matrix(a, b, c, d, e, f)
        @text_matrix = [a.to_f, b.to_f, c.to_f, d.to_f, e.to_f, f.to_f]
        @text_line_matrix = @text_matrix.dup
      end
      
      def move_text(tx, ty)
        # Td operator: move to next line
        @text_line_matrix = multiply_matrix([1, 0, 0, 1, tx.to_f, ty.to_f], @text_line_matrix)
        @text_matrix = @text_line_matrix.dup
      end
      
      def move_text_and_set_leading(tx, ty)
        # TD operator: same as Td but also sets leading
        move_text(tx, ty)
      end
      
      def move_to_next_line
        # T* operator: move to start of next line
        move_text(0, -@font_size * 1.2)  # Approximate leading
      end
      
      # Text showing operators
      def show_text(str)
        str = str.to_s
        return if str.empty?
        
        add_text_fragment(str)
      end
      
      def show_text_with_positioning(array)
        # TJ operator: array of strings and positioning adjustments
        text_parts = []
        
        array.each do |item|
          if item.is_a?(String) || item.is_a?(HexaPDF::PDFArray)
            text_parts << item.to_s
          elsif item.is_a?(Numeric)
            # Negative numbers move right, positive move left
            # These are typically kerning adjustments in thousandths of em
            # We'll ignore them for fragment collection
          end
        end
        
        combined_text = text_parts.join
        add_text_fragment(combined_text) unless combined_text.empty?
      end
      
      def show_text_with_new_line(str)
        move_to_next_line
        show_text(str)
      end
      
      def show_text_with_new_line_and_spacing(word_spacing, char_spacing, str)
        @word_spacing = word_spacing.to_f
        @char_spacing = char_spacing.to_f
        move_to_next_line
        show_text(str)
      end
      
      def process(*args)
        # Generic handler for process calls
      end
      
      def method_missing(_method, *_args)
        # Ignore other PDF operators
      end
      
      def respond_to_missing?(_method, _include_private = false)
        true
      end
      
      private
      
      def add_text_fragment(text)
        return if text.blank?
        
        # Get the current position by combining text matrix with CTM
        combined = multiply_matrix(@text_matrix, @ctm)
        
        pdf_x = combined[4]  # e component (x translation)
        pdf_y = combined[5]  # f component (y translation)
        
        # Calculate text dimensions
        # Scale factor from combined matrix
        scale_x = Math.sqrt(combined[0]**2 + combined[1]**2)
        scale_y = Math.sqrt(combined[2]**2 + combined[3]**2)
        
        effective_font_size = @font_size * scale_y
        effective_font_size = 10 if effective_font_size < 1
        
        # Estimate text width (average character width ~0.5 of font size for proportional fonts)
        avg_char_width = effective_font_size * 0.5 * (@horizontal_scaling / 100.0)
        text_width = text.length * avg_char_width
        text_height = effective_font_size
        
        @fragments << {
          text: text,
          page: @page_index,
          pdf_x: pdf_x,
          pdf_y: pdf_y,
          width: text_width,
          height: text_height,
          font_size: effective_font_size,
          page_width: @page_width,
          page_height: @page_height
        }
        
        # Advance the text position for the next fragment
        # Move the text matrix by the text width
        @text_matrix[4] += text_width
      end
      
      def multiply_matrix(m1, m2)
        # Matrix multiplication for 2D affine transformation matrices
        # [a b 0]   [a' b' 0]   [a*a'+c*b'  b*a'+d*b'  0]
        # [c d 0] x [c' d' 0] = [a*c'+c*d'  b*c'+d*d'  0]
        # [e f 1]   [e' f' 1]   [a*e'+c*f'+e  b*e'+d*f'+f  1]
        [
          m1[0] * m2[0] + m1[2] * m2[1],           # a
          m1[1] * m2[0] + m1[3] * m2[1],           # b
          m1[0] * m2[2] + m1[2] * m2[3],           # c
          m1[1] * m2[2] + m1[3] * m2[3],           # d
          m1[0] * m2[4] + m1[2] * m2[5] + m1[4],   # e
          m1[1] * m2[4] + m1[3] * m2[5] + m1[5]    # f
        ]
      end
    end

    # Legacy text processor - kept for compatibility
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
        @in_tag = false
      end

      def process(*args)
        # Handle different method signatures
      end

      def set_font(_font, size)
        @font_size = size.to_f.abs
        @font_size = 12 if @font_size < 1
      end

      def move_text(x, y)
        flush_text unless @in_tag
        @current_x += x.to_f
        @current_y += y.to_f
        unless @in_tag
          @text_start_x = @current_x
          @text_start_y = @current_y
        end
      end

      def set_text_matrix(a, _b, _c, _d, e, f)
        flush_text unless @in_tag
        @current_x = e.to_f
        @current_y = f.to_f
        unless @in_tag
          @text_start_x = @current_x
          @text_start_y = @current_y
        end
      end
      
      def begin_text
        @current_x = 0
        @current_y = 0
      end

      def show_text(str)
        str = str.to_s
        return if str.blank?

        @text_start_x = @current_x if @accumulated_text.blank?
        @text_start_y = @current_y if @accumulated_text.blank?
        @accumulated_text += str

        open_count = @accumulated_text.scan('{{').length
        close_count = @accumulated_text.scan('}}').length
        @in_tag = open_count > close_count

        flush_text if !@in_tag && @accumulated_text.include?('}}')
      end

      def show_text_with_positioning(array)
        array.each do |item|
          show_text(item) if item.is_a?(String)
        end
      end

      def end_text
        @in_tag = false
        flush_text
      end

      def flush_text
        return if @accumulated_text.blank?

        if @accumulated_text.match?(TAG_REGEX)
          char_width = @font_size * 0.5
          text_width = @accumulated_text.length * char_width

          @text_items << {
            text: @accumulated_text,
            page: @page_index,
            x: @text_start_x,
            y: @text_start_y,  # Keep raw PDF Y coordinate
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
