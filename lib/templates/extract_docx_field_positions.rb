# frozen_string_literal: true

require 'tempfile'

begin
  require 'docx'
rescue LoadError
  # docx gem not installed; ExtractDocxFieldPositions.call will return []
end

module Templates
  module ExtractDocxFieldPositions
    TAG_REGEX = /\{\{([^}]+)\}\}/

    module_function

    # Extract form field tags from DOCX with structural context,
    # then find their positions in the tagged PDF using label-based matching.
    #
    # Returns array of field definitions with areas [{page:, x:, y:, w:, h:}]
    #
    # Strategy:
    # 1. Parse DOCX with docx gem to find each {{tag}} and its context
    #    (label text on the same line or in the same cell)
    # 2. Scan the tagged PDF with Pdfium to find label text positions
    # 3. Place form fields relative to their label positions
    def call(docx_data, tagged_pdf_data, attachment)
      unless defined?(Docx::Document)
        Rails.logger.warn('ExtractDocxFieldPositions: docx gem not available, skipping')
        return []
      end

      # Step 1: Extract tags with context from DOCX
      tag_infos = extract_tags_with_context(docx_data)

      Rails.logger.info("ExtractDocxFieldPositions: Found #{tag_infos.size} tags in DOCX")
      tag_infos.each do |ti|
        Rails.logger.info("  - #{ti[:name]} (#{ti[:type]}): label=#{ti[:label].inspect}, in_table=#{ti[:in_table]}")
      end

      return [] if tag_infos.empty?

      # Step 2: Build a text position map from the tagged PDF
      pdf_text_map = build_pdf_text_map(tagged_pdf_data)

      Rails.logger.info("ExtractDocxFieldPositions: PDF text map has #{pdf_text_map.size} entries")

      # Step 3: Match each tag to a position in the PDF
      fields = []
      tag_infos.each do |tag_info|
        field_def = build_field_def(tag_info)
        next if field_def.blank?

        area = find_position_for_tag(tag_info, pdf_text_map)

        # Fallback: if column-filtered search failed, retry without column filter
        if area.nil? && tag_info[:in_table]
          Rails.logger.info("ExtractDocxFieldPositions: #{tag_info[:name]} not found in column #{tag_info[:col_idx]}, retrying without column filter")
          unfiltered_info = tag_info.merge(in_table: false)  # disable column filter
          area = find_position_for_tag(unfiltered_info, pdf_text_map)
        end

        if area
          area[:attachment_uuid] = attachment.uuid
          field_def[:uuid] = SecureRandom.uuid
          field_def[:areas] = [area]
          fields << field_def

          Rails.logger.info("ExtractDocxFieldPositions: #{field_def[:name]} (col=#{tag_info[:col_idx]}) -> page=#{area[:page]} pos=(#{area[:x].round(3)}, #{area[:y].round(3)}) size=(#{area[:w].round(3)}x#{area[:h].round(3)})")
        else
          Rails.logger.warn("ExtractDocxFieldPositions: #{field_def[:name]} (col=#{tag_info[:col_idx]}, label=#{tag_info[:label].inspect}) -> NO POSITION FOUND")
        end
      end

      fields
    end

    # Parse DOCX and extract each {{tag}} with its structural context:
    # - label: the text on the same line before or after the tag (e.g., "Buyer Signature:")
    # - in_table: whether the tag is inside a table cell
    # - full_tag: the complete tag content
    def extract_tags_with_context(docx_data)
      tags = []

      tempfile = Tempfile.new(['docx_parse', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.close

      begin
        doc = Docx::Document.open(tempfile.path)

        detect_document_defaults(tempfile.path)
        Rails.logger.info("ExtractDocxFieldPositions: document defaults font=#{@doc_default_font.inspect} font_size=#{@doc_default_font_size.inspect}pt")

        # Process tables FIRST - these have column context for accurate positioning
        doc.tables.each do |table|
          num_cols = table.column_count rescue 2
          
          # Read actual column widths from DOCX XML (<w:tblGrid>/<w:gridCol>)
          col_widths = extract_table_column_widths(table, num_cols)
          
          Rails.logger.info("ExtractDocxFieldPositions: Processing table with #{num_cols} columns")
          
          table.rows.each_with_index do |row, row_idx|
            row.cells.each_with_index do |cell, col_idx|
              cell_text = cell.text.to_s
              Rails.logger.info("ExtractDocxFieldPositions: Table row=#{row_idx} col=#{col_idx}: #{cell_text[0..60].inspect}")

              cell_alignment = nil
              cell_font = nil
              cell_font_size = nil
              if cell_text.include?('{{')
                cell.paragraphs.each do |para|
                  next unless para.to_s.include?('{{')

                  cell_alignment ||= extract_paragraph_alignment(para)
                  cell_font ||= extract_paragraph_font(para)
                  cell_font_size ||= extract_paragraph_font_size(para)
                end
              end

              extract_tags_from_text(cell_text, tags, in_table: true, col_idx: col_idx, num_cols: num_cols, col_widths: col_widths, alignment: cell_alignment, font_name: cell_font, font_size: cell_font_size)
            end
          end
        end
        
        # Track names already found in tables
        table_tag_names = tags.map { |t| t[:name] }.to_set

        # Process paragraphs (non-table content only)
        # Skip tags already found in tables to avoid duplicates without column context
        doc.paragraphs.each do |paragraph|
          para_text = paragraph.to_s
          next if para_text.blank?

          alignment = extract_paragraph_alignment(paragraph)
          font_name = extract_paragraph_font(paragraph)
          font_size = extract_paragraph_font_size(paragraph)

          if para_text.include?('{{')
            Rails.logger.info("ExtractDocxFieldPositions: Paragraph with tag: #{para_text[0..60].inspect} alignment=#{alignment.inspect} font=#{font_name.inspect} font_size=#{font_size.inspect}pt")
          end

          # Only process if this paragraph has tags NOT already found in tables
          para_tags_before = tags.size
          extract_tags_from_text(para_text, tags, in_table: false, alignment: alignment, font_name: font_name, font_size: font_size)
          
          # Remove any duplicates that were already found in tables
          if tags.size > para_tags_before
            tags.reject! { |t| !t[:in_table] && table_tag_names.include?(t[:name]) }
          end
        end
      rescue StandardError => e
        Rails.logger.error("ExtractDocxFieldPositions: DOCX parsing failed: #{e.message}")
        Rails.logger.error(e.backtrace.first(3).join("\n"))
      ensure
        tempfile.unlink
      end

      tags
    end

    # Extract actual column widths from a DOCX table's XML.
    # Returns array of normalized widths (0-1) like [0.5, 0.5] or [0.3, 0.4, 0.3]
    # Falls back to equal widths if XML parsing fails.
    def extract_table_column_widths(table, num_cols)
      begin
        # Access the underlying Nokogiri node via the docx gem
        table_node = table.node if table.respond_to?(:node)
        table_node ||= table.instance_variable_get(:@node) if table.instance_variable_defined?(:@node)
        
        if table_node
          ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
          grid_cols = table_node.xpath('.//w:tblGrid/w:gridCol', ns)
          
          if grid_cols.any?
            # Extract widths in twips (1 inch = 1440 twips)
            raw_widths = grid_cols.map { |gc| (gc['w:w'] || '0').to_f }
            total = raw_widths.sum
            
            if total > 0
              normalized = raw_widths.map { |w| w / total }
              Rails.logger.info("ExtractDocxFieldPositions: Table column widths: #{normalized.map { |w| w.round(3) }.inspect}")
              return normalized
            end
          end
        end
      rescue StandardError => e
        Rails.logger.debug("ExtractDocxFieldPositions: Could not read column widths: #{e.message}")
      end
      
      # Fallback: equal widths
      equal = Array.new(num_cols) { 1.0 / num_cols }
      Rails.logger.info("ExtractDocxFieldPositions: Using equal column widths: #{equal.map { |w| w.round(3) }.inspect}")
      equal
    end

    # Read the <w:jc> alignment from a DOCX paragraph's XML node.
    # Returns "center", "right", "both", "left", or nil.
    def extract_paragraph_alignment(paragraph)
      node = paragraph.respond_to?(:node) ? paragraph.node : nil
      return nil unless node

      ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
      jc = node.at_xpath('.//w:pPr/w:jc', ns)
      jc['w:val'] if jc
    rescue StandardError
      nil
    end

    # Read the font family from the first <w:rFonts w:ascii="..."> in a DOCX paragraph.
    # Returns a normalized font name suitable for HexaPDF ("Times", "Helvetica", "Courier")
    # or nil when no recognizable font is found.
    DOCX_FONT_MAP = {
      'times new roman' => 'Times',
      'times' => 'Times',
      'arial' => 'Helvetica',
      'helvetica' => 'Helvetica',
      'courier new' => 'Courier',
      'courier' => 'Courier'
    }.freeze

    def extract_paragraph_font(paragraph)
      node = paragraph.respond_to?(:node) ? paragraph.node : nil
      return nil unless node

      ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
      r_fonts = node.at_xpath('.//w:r/w:rPr/w:rFonts', ns) ||
                node.at_xpath('.//w:pPr/w:rPr/w:rFonts', ns)
      raw = (r_fonts['w:ascii'] if r_fonts) rescue nil

      if raw.present?
        DOCX_FONT_MAP[raw.downcase] || nil
      else
        @doc_default_font
      end
    rescue StandardError
      nil
    end

    # Extract font size (in points) from a DOCX paragraph's run or paragraph defaults.
    # DOCX stores font size in half-points (w:sz val="24" = 12pt).
    def extract_paragraph_font_size(paragraph)
      node = paragraph.respond_to?(:node) ? paragraph.node : nil
      return nil unless node

      ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
      sz = node.at_xpath('.//w:r/w:rPr/w:sz', ns) ||
           node.at_xpath('.//w:pPr/w:rPr/w:sz', ns)
      half_points = (sz['w:val'].to_i if sz) rescue nil

      if half_points && half_points > 0
        half_points / 2
      else
        @doc_default_font_size
      end
    rescue StandardError
      nil
    end

    # Detect document-wide default font and font size from styles.xml.
    # Sets @doc_default_font (String or nil) and @doc_default_font_size (Integer pt or nil).
    def detect_document_defaults(docx_path)
      require 'zip'
      require 'nokogiri'

      @doc_default_font = nil
      @doc_default_font_size = nil

      Zip::File.open(docx_path) do |zip_file|
        entry = zip_file.find_entry('word/styles.xml')
        return unless entry

        xml = Nokogiri::XML(entry.get_input_stream.read)
        ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }

        # docDefaults → rPrDefault → rPr
        default_rpr = xml.at_xpath('//w:docDefaults/w:rPrDefault/w:rPr', ns)
        if default_rpr
          r_fonts = default_rpr.at_xpath('w:rFonts', ns)
          if r_fonts
            raw = (r_fonts['w:ascii']) rescue nil
            @doc_default_font = DOCX_FONT_MAP[raw.to_s.downcase] if raw.present?
          end

          sz = default_rpr.at_xpath('w:sz', ns)
          if sz
            half_points = (sz['w:val'].to_i) rescue 0
            @doc_default_font_size = half_points / 2 if half_points > 0
          end
        end

        # Normal style fallback for font
        unless @doc_default_font
          normal_rfonts = xml.at_xpath('//w:style[@w:styleId="Normal"]/w:rPr/w:rFonts', ns)
          if normal_rfonts
            raw = (normal_rfonts['w:ascii']) rescue nil
            @doc_default_font = DOCX_FONT_MAP[raw.to_s.downcase] if raw.present?
          end
        end

        unless @doc_default_font_size
          normal_sz = xml.at_xpath('//w:style[@w:styleId="Normal"]/w:rPr/w:sz', ns)
          if normal_sz
            half_points = (normal_sz['w:val'].to_i) rescue 0
            @doc_default_font_size = half_points / 2 if half_points > 0
          end
        end
      end
    rescue StandardError
      nil
    end

    # Extract tags from a text block and determine the label context
    def extract_tags_from_text(text, tags, in_table: false, col_idx: nil, num_cols: nil, col_widths: nil, alignment: nil, font_name: nil, font_size: nil)
      return if text.blank?

      text.scan(TAG_REGEX) do |match|
        tag_content = match[0]
        full_tag = "{{#{tag_content}}}"

        # Parse tag attributes
        parts = tag_content.split(';').map(&:strip)
        name = parts.first
        attrs = {}
        parts[1..].each do |part|
          key, value = part.split('=', 2)
          attrs[key.strip.downcase] = value&.strip if key.present?
        end

        # Skip tags without type (they're variable placeholders, not form fields)
        next unless attrs['type'].present?

        # Determine label: text on the same line, excluding the tag itself
        # Split by newlines and find the line containing the tag
        lines = text.split(/\r?\n/)
        label = nil
        tag_line = nil

        lines.each do |line|
          if line.include?(full_tag)
            tag_line = line
            # Label = everything on this line except the tag
            label = line.gsub(full_tag, '').strip
            label = nil if label.empty?
            break
          end
        end

        # If no label on the same line, check the line above
        if label.nil? && tag_line
          line_idx = lines.index(tag_line)
          if line_idx && line_idx > 0
            prev_line = lines[line_idx - 1].strip
            label = prev_line unless prev_line.empty? || prev_line.match?(TAG_REGEX)
          end
        end

        tags << {
          name: name,
          type: attrs['type']&.downcase || 'text',
          role: attrs['role'],
          required: attrs['required'] != 'false',
          position: attrs['position'],  # background/foreground for stamp layer control
          full_tag: full_tag,
          tag_content: tag_content,
          label: label,
          in_table: in_table,
          col_idx: col_idx,      # 0-based column index in table (nil for non-table)
          num_cols: num_cols,     # total columns in the table (nil for non-table)
          col_widths: col_widths, # normalized column widths array (nil for non-table)
          alignment: alignment,  # DOCX paragraph alignment: "center", "right", etc.
          font_name: font_name,  # DOCX font family mapped to HexaPDF name, e.g. "Times"
          font_size: font_size   # DOCX font size in points, e.g. 12
        }
      end
    end

    # Build a position map from the tagged PDF using Pdfium.
    # Returns array of { text:, page:, x:, y:, w:, h:, endx: }
    # Each entry is a text node from Pdfium with its coordinates.
    def build_pdf_text_map(pdf_data)
      entries = []

      begin
        doc = Pdfium::Document.open_bytes(pdf_data)

        (0...doc.page_count).each do |page_index|
          page = doc.get_page(page_index)
          text_nodes = page.text_nodes

          text_nodes.each do |node|
            content = node.content.to_s
            next if content.empty?

            entries << {
              text: content,
              page: page_index,
              x: node.x,
              y: node.y,
              w: node.w,
              h: node.h,
              endx: node.endx,
              endy: node.endy
            }
          end

          page.close
        end

        doc.close
      rescue StandardError => e
        Rails.logger.error("ExtractDocxFieldPositions: Pdfium failed: #{e.message}")
      end

      entries
    end

    # Find the position for a tag in the PDF using its label or tag text.
    #
    # For table tags: filters PDF text nodes to the correct column first,
    # preventing cross-column matching (the root cause of buyer/seller swaps).
    #
    # Strategy:
    # 1. Search for the tag text itself (e.g., "{{BuyerSign;type=...}}")
    # 2. If not found directly, search for the label text and position relative to it
    def find_position_for_tag(tag_info, pdf_text_map)
      return nil if pdf_text_map.empty?

      # Build full text stream per page
      pages = {}
      pdf_text_map.each do |entry|
        pages[entry[:page]] ||= []
        pages[entry[:page]] << entry
      end

      field_name = tag_info[:name]
      full_tag_start = "{{#{field_name}"

      pages.each do |page_idx, all_entries|
        # KEY FIX: For table tags, filter entries to the correct column
        # This prevents finding BuyerSign at Seller column position
        entries = if tag_info[:in_table] && tag_info[:col_idx] && tag_info[:num_cols] && tag_info[:num_cols] > 1
                    filter_entries_by_column(all_entries, tag_info[:col_idx], tag_info[:num_cols], tag_info[:col_widths])
                  else
                    all_entries
                  end

        next if entries.empty?

        # Build expanded chars from column-filtered entries
        expanded = []
        entries.each_with_index do |entry, node_idx|
          entry[:text].each_char do |c|
            expanded << { char: c, node_idx: node_idx }
          end
        end

        # Strategy 1: Find "{{FieldName" directly
        target = full_tag_start.chars
        match_start = find_sequence_in_expanded(expanded, target)

        if match_start
          return build_area_from_match(tag_info, entries, expanded, match_start, target.length, page_idx)
        end

        # Strategy 2: Find label text and position relative to it
        if tag_info[:label].present?
          label_compact = tag_info[:label].gsub(/\s+/, '').downcase
          if label_compact.length >= 3
            label_target = label_compact.chars
            label_match = find_sequence_in_expanded(expanded, label_target)

            if label_match
              label_node_idx = expanded[label_match][:node_idx]
              label_entry = entries[label_node_idx]
              line_h = label_entry[:h] || 0.015

              # Find end of label
              label_end_k = label_match + label_target.length - 1
              label_end_k = [label_end_k, expanded.length - 1].min
              label_end_node = entries[expanded[label_end_k][:node_idx]]
              label_end_x = label_end_node[:endx] || label_end_node[:x] + (label_end_node[:w] || 0.01)

              # Determine if tag was inline with label or on separate line
              tag_was_inline = tag_info[:label]&.strip&.end_with?(':')

              if tag_was_inline
                # Check if tag text appears after label on same line
                tag_match_after = find_sequence_in_expanded(expanded, '{{'.chars, from: label_match + label_target.length)
                if tag_match_after
                  tag_entry = entries[expanded[tag_match_after][:node_idx]]
                  if (tag_entry[:y] - label_entry[:y]).abs < line_h * 0.8
                    # Tag is on same line as label → place after label
                    return build_area_from_match(tag_info, entries, expanded, tag_match_after, 2, page_idx)
                  end
                end

                # Inline fallback: place right after label end
                field_x = label_end_x + 0.005
                field_y = label_entry[:y]
                # Width: approximate from label end to column edge
                col_entries = entries.select { |e| (e[:y] - field_y).abs < line_h * 0.5 && e[:x] > field_x }
                line_right = col_entries.map { |e| (e[:endx] || e[:x] + (e[:w] || 0.01)) }.max
                field_w = line_right ? [line_right - field_x, 0.03].max : 0.15
              else
                # Separate line: place field below label
                field_x = label_entry[:x]
                field_y = label_entry[:y] + line_h * 1.3
                field_w = 0.2
              end

              tag_h = line_h
              case tag_info[:type]
              when 'signature', 'initials'
                tag_h = [tag_h * 3, 0.035].max
                field_w = [field_w, 0.15].max
              when 'image', 'stamp'
                tag_h = [tag_h * 3, 0.035].max
              end

              return {
                page: page_idx,
                x: [[field_x, 0.0].max, 0.95].min,
                y: [[field_y, 0.0].max, 0.95].min,
                w: [[field_w, 0.03].max, 0.48].min,
                h: [[tag_h, 0.012].max, 0.06].min
              }
            end
          end
        end
      end

      nil
    end

    # Filter PDF text entries to a specific table column.
    # Uses actual column widths from DOCX XML when available, falls back to equal splits.
    #
    # DOCX column widths are proportional to the TABLE width, but PDF x-coordinates
    # are normalized to the PAGE width (0.0 to 1.0). Page margins mean the table
    # content area is smaller than the full page. We detect the actual content bounds
    # from the PDF entries and map column widths within that range.
    def filter_entries_by_column(entries, col_idx, num_cols, col_widths = nil)
      return entries if num_cols <= 1

      # Detect actual content bounds from PDF entries (accounts for page margins)
      all_x = entries.map { |e| e[:x] }
      content_left = all_x.min || 0.0
      content_right = entries.map { |e| e[:endx] || (e[:x] + (e[:w] || 0.01)) }.max || 1.0
      content_width = content_right - content_left

      if content_width < 0.3
        content_left = 0.0
        content_width = 1.0
      end

      # Calculate column boundaries as percentages of table width
      if col_widths && col_widths.length == num_cols
        col_left_pct = col_widths[0...col_idx].sum
        col_right_pct = col_left_pct + col_widths[col_idx]
      else
        col_width_pct = 1.0 / num_cols
        col_left_pct = col_idx * col_width_pct
        col_right_pct = (col_idx + 1) * col_width_pct
      end

      # Map from table-relative percentages to page-relative coordinates
      col_left = content_left + (col_left_pct * content_width)
      col_right = content_left + (col_right_pct * content_width)

      margin = 0.04
      col_left = [col_left - margin, 0.0].max
      col_right = [col_right + margin, 1.0].min

      filtered = entries.select { |e| e[:x] >= col_left && e[:x] < col_right }

      Rails.logger.info("ExtractDocxFieldPositions: Column #{col_idx}/#{num_cols} filter: content=[#{content_left.round(3)}, #{content_right.round(3)}] col_x=#{col_left.round(3)}..#{col_right.round(3)} -> #{filtered.size}/#{entries.size} entries")

      filtered.size >= 2 ? filtered : entries
    end

    # Build an area hash from a match in expanded chars
    def build_area_from_match(tag_info, entries, expanded, match_start, target_len, page_idx)
      node_idx = expanded[match_start][:node_idx]
      entry = entries[node_idx]
      line_h = entry[:h] || 0.015

      tag_x = entry[:x]
      tag_y = entry[:y]

      # POSITION VALIDATION for non-table, left-aligned tags: Pdfium can misreport
      # positions for invisible (white) text or when fonts are substituted on Linux.
      # Skip correction for centered/right-aligned tags — their x IS offset from left.
      para_align = tag_info[:alignment].to_s.downcase
      is_left_aligned = !para_align.in?(%w[center right])

      unless tag_info[:in_table] || !is_left_aligned
        content_left = entries.map { |e| e[:x] }.min || 0.0
        content_right = entries.map { |e| e[:endx] || (e[:x] + (e[:w] || 0.01)) }.max || 1.0
        content_width = content_right - content_left

        if tag_x > content_left + (content_width * 0.12)
          Rails.logger.warn("ExtractDocxFieldPositions: #{tag_info[:name]} x=#{tag_x.round(3)} seems wrong for left-aligned non-table tag (content starts at #{content_left.round(3)})")

          match_chars = (match_start...[match_start + target_len + 30, expanded.length].min).map { |i| entries[expanded[i][:node_idx]] }
          if match_chars.size > 3
            y_groups = match_chars.group_by { |c| (c[:y] * 100).round }
            best_group = y_groups.max_by { |_, chars| chars.size }
            if best_group
              group_chars = best_group[1]
              corrected_x = group_chars.map { |c| c[:x] }.min
              corrected_y = group_chars.map { |c| c[:y] }.min
              if corrected_x < content_left + (content_width * 0.12)
                tag_x = corrected_x
                tag_y = corrected_y
                Rails.logger.info("ExtractDocxFieldPositions: Corrected to (#{tag_x.round(3)}, #{tag_y.round(3)})")
              else
                tag_x = content_left
                Rails.logger.info("ExtractDocxFieldPositions: Using content left margin #{content_left.round(3)}")
              end
            end
          else
            tag_x = content_left
          end
        end
      end

      if !is_left_aligned
        Rails.logger.info("ExtractDocxFieldPositions: #{tag_info[:name]} alignment=#{para_align}, Pdfium x=#{tag_x.round(3)}")
      end

      # Find tag end "}}"
      tag_end_target = '}}'.chars
      match_end = find_sequence_in_expanded(expanded, tag_end_target, from: match_start + target_len)

      # Calculate width
      if match_end
        end_node_idx = expanded[[match_end + 1, expanded.length - 1].min][:node_idx]
        end_entry = entries[end_node_idx]
        raw_w = (end_entry[:endx] || end_entry[:x] + (end_entry[:w] || 0.01)) - tag_x
      else
        raw_w = 0.15
      end

      if raw_w < 0 || raw_w > 0.5
        same_line = entries.select { |e| (e[:y] - tag_y).abs < line_h * 0.5 && (e[:x] - tag_x).abs < 0.3 }
        line_right = same_line.map { |e| (e[:endx] || e[:x] + (e[:w] || 0.01)) }.max || (tag_x + 0.15)
        raw_w = [line_right - tag_x, 0.05].max
      end

      tag_w = [[raw_w, 0.03].max, 0.48].min
      tag_h = line_h

      case tag_info[:type]
      when 'signature', 'initials'
        tag_h = [tag_h * 3, 0.035].max
        tag_w = [tag_w, 0.20].max
      when 'image', 'stamp'
        tag_h = [tag_h * 3, 0.035].max
      end

      tag_h = [[tag_h, 0.012].max, 0.06].min

      # For centered/right-aligned paragraphs, re-compute x so the FIELD (not the
      # invisible tag text) is properly aligned within the page content area.
      if !is_left_aligned
        content_left = entries.map { |e| e[:x] }.min || 0.0
        content_right = entries.map { |e| e[:endx] || (e[:x] + (e[:w] || 0.01)) }.max || 1.0
        content_width = content_right - content_left

        if para_align == 'center'
          tag_x = content_left + (content_width - tag_w) / 2.0
        elsif para_align == 'right'
          tag_x = content_right - tag_w
        end
        tag_x = [tag_x, content_left].max

        Rails.logger.info("ExtractDocxFieldPositions: #{tag_info[:name]} #{para_align}-aligned -> x=#{tag_x.round(3)} w=#{tag_w.round(3)}")
      end

      {
        page: page_idx,
        x: [[tag_x, 0.0].max, 0.95].min,
        y: [[tag_y, 0.0].max, 0.95].min,
        w: [[tag_w, 0.03].max, 0.48].min,
        h: tag_h
      }
    end

    # Find a character sequence in expanded chars array
    # Returns the index of the first matching character, or nil
    def find_sequence_in_expanded(expanded, target_chars, from: 0)
      return nil if target_chars.empty? || expanded.empty?

      (from...(expanded.length - target_chars.length + 1)).each do |start|
        j = 0
        k = start

        while k < expanded.length && j < target_chars.length
          ch = expanded[k][:char]

          # Skip whitespace in source
          if ch.match?(/\s/)
            k += 1
            next
          end

          # Skip hyphens (PDF hyphenation artifacts)
          if ch.match?(/[-\u00AD\u2010\u2011\u2012]/) && target_chars[j] != ch
            k += 1
            next
          end

          if ch == target_chars[j]
            j += 1
            k += 1
          else
            break
          end
        end

        return start if j == target_chars.length
      end

      nil
    end

    # Find label text in PDF pages
    # Returns { page:, entry:, end_x: } or nil
    def find_label_in_pdf(label_compact, pages)
      pages.each do |page_idx, entries|
        # Build expanded chars for this page
        expanded = []
        entries.each_with_index do |entry, node_idx|
          entry[:text].each_char do |c|
            expanded << { char: c, node_idx: node_idx }
          end
        end

        # Search for compact label (no spaces)
        target = label_compact.chars
        match_idx = find_sequence_in_expanded(expanded, target)

        if match_idx
          start_node = entries[expanded[match_idx][:node_idx]]
          # Find end position
          end_k = match_idx + target.length - 1
          end_k = [end_k, expanded.length - 1].min
          end_node = entries[expanded[end_k][:node_idx]]
          end_x = end_node[:endx] || end_node[:x] + (end_node[:w] || 0.01)

          return {
            page: page_idx,
            entry: start_node,
            end_x: end_x
          }
        end
      end

      nil
    end

    # Build a field definition hash from tag info
    def build_field_def(tag_info)
      field_type = normalize_type(tag_info[:type])
      return nil unless field_type

      # Convert datenow to date with auto-fill (matches template builder behavior)
      is_datenow = field_type == 'datenow'
      if is_datenow
        field_type = 'date'
      end

      field = {
        name: tag_info[:name],
        type: field_type,
        role: tag_info[:role],
        required: tag_info[:required],
        readonly: is_datenow ? true : nil,
        default_value: is_datenow ? '{{date}}' : nil,
        tag_content: tag_info[:tag_content]
      }

      preferences = {}
      preferences['position'] = tag_info[:position] if tag_info[:position].present?

      # Carry DOCX paragraph alignment so the rendered value matches the DOCX layout.
      if tag_info[:alignment].present? && !tag_info[:alignment].to_s.downcase.in?(%w[left both])
        preferences['align'] = tag_info[:alignment].to_s.downcase
      end

      # Carry DOCX font family so the rendered value matches the document's typeface.
      preferences['font'] = tag_info[:font_name] if tag_info[:font_name].present?

      # Carry DOCX font size so the rendered value matches the document's text size.
      preferences['font_size'] = tag_info[:font_size] if tag_info[:font_size].present?

      field[:preferences] = preferences if preferences.any?

      Rails.logger.info("ExtractDocxFieldPositions: build_field_def #{field[:name]} -> type=#{field[:type]} preferences=#{field[:preferences].inspect}")

      field.compact
    end

    def normalize_type(type)
      type = type.to_s.downcase.strip
      aliases = {
        'sig' => 'signature', 'sign' => 'signature',
        'init' => 'initials', 'check' => 'checkbox',
        'multi' => 'multiple', 'sel' => 'select',
        'img' => 'image', 'num' => 'number',
        'string' => 'text', 'str' => 'text'
      }
      normalized = aliases[type] || type
      valid = %w[text signature initials date datenow image file payment stamp select checkbox multiple radio phone verification kba number]
      valid.include?(normalized) ? normalized : nil
    end
  end
end
