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

    # Inset (in normalized page coords, 0-1) applied to tags inside table cells
    # so the rendered field doesn't sit on top of the cell border line. ~4pt on
    # letter-size paper, matching Word's default cell margin of 108 twips.
    TABLE_CELL_PADDING = 0.007

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
      positioned = []
      tag_infos.each do |tag_info|
        field_def = build_field_def(tag_info)
        next if field_def.blank?

        area = find_position_for_tag(tag_info, pdf_text_map)

        # Fallback 1: if column-filtered search failed, retry without column filter.
        if area.nil? && tag_info[:in_table]
          Rails.logger.info("ExtractDocxFieldPositions: #{tag_info[:name]} not found in column #{tag_info[:col_idx]}, retrying without column filter")
          unfiltered_info = tag_info.merge(in_table: false)
          area = find_position_for_tag(unfiltered_info, pdf_text_map)
        end

        # Fallback 2: some tags (isolated checkbox/date paragraphs with no
        # label text) don't find a match via Strategy 1/2 because Pdfium can
        # emit the invisible tag text with extra separators or re-order chars
        # across lines. Relax to a name-only search as a last resort so we
        # never land on the hardcoded end-of-page fallback for tags whose
        # text actually is in the PDF.
        if area.nil?
          Rails.logger.info("ExtractDocxFieldPositions: #{tag_info[:name]} not found via full tag match, trying name-only fallback")
          area = find_position_by_name_only(tag_info, pdf_text_map)
        end

        if area
          positioned << { tag_info: tag_info, field_def: field_def, area: area }
        else
          Rails.logger.warn("ExtractDocxFieldPositions: #{field_def[:name]} (col=#{tag_info[:col_idx]}, label=#{tag_info[:label].inspect}) -> NO POSITION FOUND")
        end
      end

      # Step 4: Correct table tags whose position was mislaid by the renderer
      # onto the preceding paragraph's line. LibreOffice sometimes places a
      # white tag paragraph's first line at the tail of the prior paragraph,
      # making the first row of a table checkbox/date column land far from
      # its column's left edge. Snap outliers back to the column and row
      # established by their sibling tags (or, when only one sibling exists,
      # by searching the PDF for the row's neighboring cell label text).
      correct_misplaced_table_tag_positions(positioned, pdf_text_map)

      # Step 5: Finalize fields with attachment uuid, uuid, font defaults.
      fields = []
      positioned.each do |entry|
        tag_info = entry[:tag_info]
        field_def = entry[:field_def]
        area = entry[:area]

        measured_font_size_pt = area.delete(:_measured_font_size_pt)
        apply_font_defaults_to_field(field_def, measured_font_size_pt)

        area[:attachment_uuid] = attachment.uuid
        field_def[:uuid] = SecureRandom.uuid
        field_def[:areas] = [area]
        fields << field_def

        Rails.logger.info("ExtractDocxFieldPositions: #{field_def[:name]} (col=#{tag_info[:col_idx]}) -> page=#{area[:page]} pos=(#{area[:x].round(3)}, #{area[:y].round(3)}) size=(#{area[:w].round(3)}x#{area[:h].round(3)}) font=#{field_def.dig(:preferences, 'font').inspect} font_size=#{field_def.dig(:preferences, 'font_size').inspect}pt")
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
        doc.tables.each_with_index do |table, table_idx|
          num_cols = table.column_count rescue 2
          
          # Read actual column widths from DOCX XML (<w:tblGrid>/<w:gridCol>)
          col_widths = extract_table_column_widths(table, num_cols)
          
          Rails.logger.info("ExtractDocxFieldPositions: Processing table #{table_idx} with #{num_cols} columns")
          
          table.rows.each_with_index do |row, row_idx|
            # Pre-compute each cell's plain text so we can hand each tag the
            # text of its SIBLING cells on the same row. When the renderer
            # mislays a lonely tag paragraph we can still find the row's y
            # by searching the PDF for its neighboring label text.
            all_cell_texts = row.cells.map { |c| c.text.to_s }

            row.cells.each_with_index do |cell, col_idx|
              cell_text = all_cell_texts[col_idx]
              Rails.logger.info("ExtractDocxFieldPositions: Table #{table_idx} row=#{row_idx} col=#{col_idx}: #{cell_text[0..60].inspect}")

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

              row_labels = all_cell_texts.each_with_index.reject { |_, i| i == col_idx }.map(&:first)

              extract_tags_from_text(cell_text, tags, in_table: true, table_idx: table_idx, row_idx: row_idx, col_idx: col_idx, num_cols: num_cols, col_widths: col_widths, alignment: cell_alignment, font_name: cell_font, font_size: cell_font_size, row_labels: row_labels)
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

    # Normalize DOCX <w:jc w:val="..."> values to a set compatible with HexaPDF
    # (:left, :center, :right, :justify). Office Open XML also allows "start",
    # "end", "distribute", etc., which would otherwise crash HexaPDF's
    # TextLayouter with "ArgumentError: :start is not a valid text_align value".
    DOCX_ALIGNMENT_MAP = {
      'left' => 'left',
      'start' => 'left',
      'center' => 'center',
      'centre' => 'center',
      'right' => 'right',
      'end' => 'right',
      'both' => 'justify',
      'justify' => 'justify'
    }.freeze

    # Read the <w:jc> alignment from a DOCX paragraph's XML node.
    # Returns "left", "center", "right", "justify", or nil.
    def extract_paragraph_alignment(paragraph)
      node = paragraph.respond_to?(:node) ? paragraph.node : nil
      return nil unless node

      ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
      jc = node.at_xpath('.//w:pPr/w:jc', ns)
      return nil unless jc

      DOCX_ALIGNMENT_MAP[jc['w:val'].to_s.downcase]
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
    def extract_tags_from_text(text, tags, in_table: false, table_idx: nil, row_idx: nil, col_idx: nil, num_cols: nil, col_widths: nil, alignment: nil, font_name: nil, font_size: nil, row_labels: nil)
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
          table_idx: table_idx,  # 0-based index of the containing table (nil for non-table)
          row_idx: row_idx,      # 0-based row index in table (nil for non-table)
          col_idx: col_idx,      # 0-based column index in table (nil for non-table)
          num_cols: num_cols,     # total columns in the table (nil for non-table)
          col_widths: col_widths, # normalized column widths array (nil for non-table)
          alignment: alignment,  # DOCX paragraph alignment: "center", "right", etc.
          font_name: font_name,  # DOCX font family mapped to HexaPDF name, e.g. "Times"
          font_size: font_size,  # DOCX font size in points, e.g. 12
          row_labels: row_labels # Array of neighboring cell texts on the same row (nil outside tables)
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
              endy: node.endy,
              font_size: node.font_size
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

              # Use the label's rendered font size as a proxy for the tag's —
              # they're on the same paragraph/line so the sizes match in
              # practice, and this gives us a usable number for the field.
              label_font_size_pt = label_entry[:font_size]
              label_font_size_pt = label_font_size_pt.to_f.round if label_font_size_pt&.positive?

              return {
                page: page_idx,
                x: [[field_x, 0.0].max, 0.95].min,
                y: [[field_y, 0.0].max, 0.95].min,
                w: [[field_w, 0.03].max, 0.48].min,
                h: [[tag_h, 0.012].max, 0.06].min,
                _measured_font_size_pt: label_font_size_pt
              }
            end
          end
        end
      end

      nil
    end

    # Last-resort positioning: search just for the field name (without the
    # `{{...}}` wrapper) across every page, ignoring column filters. Useful
    # for isolated checkbox/date paragraphs where Pdfium didn't emit the
    # braces as contiguous characters next to the name. To avoid matching a
    # plain-text label that happens to share the field name, the match must
    # be followed by a `;` (tag attribute separator) or `}}` within a short
    # window — both clear signatures of the invisible tag text. Returns an
    # area hash (with `:_measured_font_size_pt`) or nil.
    def find_position_by_name_only(tag_info, pdf_text_map)
      return nil if pdf_text_map.blank? || tag_info[:name].blank?

      name_target = tag_info[:name].chars

      pages = {}
      pdf_text_map.each do |entry|
        pages[entry[:page]] ||= []
        pages[entry[:page]] << entry
      end

      pages.each do |page_idx, entries|
        expanded = []
        entries.each_with_index do |entry, node_idx|
          entry[:text].each_char do |c|
            expanded << { char: c, node_idx: node_idx }
          end
        end

        search_from = 0
        loop do
          match_start = find_sequence_in_expanded(expanded, name_target, from: search_from)
          break unless match_start

          after_idx = match_start + name_target.length
          if looks_like_tag_context?(expanded, after_idx)
            Rails.logger.info("ExtractDocxFieldPositions: name-only match for #{tag_info[:name]} on page #{page_idx} at char #{match_start}")
            return build_area_from_match(tag_info, entries, expanded, match_start, name_target.length, page_idx)
          end

          search_from = match_start + 1
        end
      end

      nil
    end

    # True when the characters immediately after `after_idx` in `expanded`
    # look like the inside of a DocuSeal tag — the match must be directly
    # followed (after skipping whitespace) by `;`, `=`, or `}}`. Any other
    # character means the sequence is just the field name used as plain
    # label text and `find_position_by_name_only` should keep searching.
    def looks_like_tag_context?(expanded, after_idx)
      return false if after_idx.nil? || after_idx >= expanded.length

      idx = after_idx
      first_char = nil
      second_char = nil
      while idx < expanded.length
        ch = expanded[idx][:char]
        idx += 1
        next if ch.match?(SKIPPABLE_WHITESPACE)
        if first_char.nil?
          first_char = ch
        else
          second_char = ch
          break
        end
      end
      return false if first_char.nil?

      return true if first_char == ';' || first_char == '='
      return true if first_char == '}' && second_char == '}'

      false
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

      # Capture the rendered font size (in PDF points) so we can make the form
      # field's font size match the surrounding document text. Pdfium reports
      # the exact size used in the PDF after LibreOffice resolved the template's
      # docDefaults/theme/Normal-style chain — that's the authoritative number.
      measured_font_size_pt = collect_measured_font_size(entries, expanded, match_start, target_len)

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

      # Field dimensions by type. Checkbox, radio and stamp have intrinsic
      # visual sizes (single-char square, fixed-size image) so we ignore the
      # tag text extent entirely. Everything else takes its width from the
      # tag text but always uses a fixed default height — the DOCX text
      # wrapping height is meant to indicate where the tag lives, not how
      # tall the form field should be.
      case tag_info[:type]
      when 'checkbox', 'radio'
        tag_w = 0.02
        tag_h = 0.02
      when 'stamp'
        tag_w = 0.10
        tag_h = 0.08
      when 'signature', 'initials'
        tag_w = [[raw_w, 0.20].max, 0.48].min
        tag_h = 0.04
      when 'image'
        tag_w = [[raw_w, 0.20].max, 0.48].min
        tag_h = 0.05
      else
        # Single-line inputs: text, number, date, phone, select, multiple,
        # cells, verification, kba, file, payment. Width follows the tag
        # text, default height is a fixed single row.
        tag_w = [[raw_w, 0.08].max, 0.48].min
        tag_h = 0.025
      end

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

      # Add table cell padding so the field doesn't visually sit on top of the
      # cell borders. Pdfium reports the x of the first `{{` character, which
      # tends to be flush with the cell's left content edge; rendering a filled
      # value there makes it overlap the vertical border line. A small inset
      # (~4pt on letter-size) keeps the field inside the cell padding area.
      if tag_info[:in_table]
        cell_pad = TABLE_CELL_PADDING
        col_left_bound = entries.map { |e| e[:x] }.min || 0.0
        col_right_bound = entries.map { |e| e[:endx] || (e[:x] + (e[:w] || 0.01)) }.max || 1.0

        case para_align
        when 'center'
          # Centered in cell; just shrink width slightly so left/right edges
          # stay off the borders on narrow columns.
          max_w = [col_right_bound - col_left_bound - (cell_pad * 2), 0.03].max
          tag_w = [tag_w, max_w].min
          tag_x = col_left_bound + ((col_right_bound - col_left_bound) - tag_w) / 2.0
        when 'right'
          # Inset from the right border.
          tag_x = [tag_x - cell_pad, col_left_bound + cell_pad].max
        else
          # Default left-aligned: inset from the left border.
          tag_x += cell_pad
          max_w = [col_right_bound - tag_x - cell_pad, 0.03].max
          tag_w = [tag_w, max_w].min
        end

        Rails.logger.debug("ExtractDocxFieldPositions: #{tag_info[:name]} table-padded -> x=#{tag_x.round(3)} w=#{tag_w.round(3)}")
      end

      {
        page: page_idx,
        x: [[tag_x, 0.0].max, 0.95].min,
        y: [[tag_y, 0.0].max, 0.95].min,
        w: [[tag_w, 0.015].max, 0.48].min,
        h: tag_h,
        _measured_font_size_pt: measured_font_size_pt
      }
    end

    # Read the rendered font size from the PDF text nodes covered by the tag
    # match. Pdfium reports font size in PDF points (typically 1/72 inch), which
    # is exactly what HexaPDF expects on the rendering side. Returns nil when
    # Pdfium didn't surface a usable value.
    def collect_measured_font_size(entries, expanded, match_start, target_len)
      stop = [match_start + target_len, expanded.length].min
      sizes = (match_start...stop).map do |i|
        entry = entries[expanded[i][:node_idx]]
        entry && entry[:font_size]
      end.compact.reject { |s| s <= 0 }
      return nil if sizes.empty?
      # Median is more robust than mean if a single glyph was substituted.
      sorted = sizes.sort
      median = sorted[sorted.length / 2]
      median.round
    rescue StandardError
      nil
    end

    # Whitespace characters that can appear inside PDF text output and must be
    # treated as "skip this char" when matching a tag sequence. `\s` in Ruby
    # covers the ASCII set, but LibreOffice frequently inserts non-breaking
    # spaces (U+00A0), thin/hair spaces, and zero-width characters that break
    # substring matching when not accounted for.
    SKIPPABLE_WHITESPACE = /[\s\u00A0\u200B\u200C\u200D\u2028\u2029\u202F\u2060\uFEFF]/.freeze

    # Find a character sequence in expanded chars array
    # Returns the index of the first matching character, or nil
    def find_sequence_in_expanded(expanded, target_chars, from: 0)
      return nil if target_chars.empty? || expanded.empty?

      (from...(expanded.length - target_chars.length + 1)).each do |start|
        j = 0
        k = start

        while k < expanded.length && j < target_chars.length
          ch = expanded[k][:char]

          # Skip whitespace in source (including unicode variants LibreOffice
          # sometimes emits, like non-breaking / zero-width space)
          if ch.match?(SKIPPABLE_WHITESPACE)
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

    # Word's effective default when docDefaults and the Normal style both omit
    # an explicit <w:sz>. ECMA-376 falls back to 10pt, but every modern Word /
    # LibreOffice release renders at 11pt. Using 11pt keeps the filled form
    # value visually consistent with the surrounding document text in the cases
    # where neither the DOCX nor the rendered PDF surfaced a size.
    DEFAULT_FONT_SIZE_PT = 11

    # Word's fallback font when docDefaults and Normal both omit <w:rFonts>.
    # Helvetica maps 1:1 to Arial (Word's practical default on new blank docs).
    DEFAULT_FONT_NAME = 'Helvetica'

    # Apply font name/size defaults to a field's preferences so the rendered
    # form value always uses the same typography as the surrounding document
    # text. Precedence (highest → lowest):
    #   1. font/size already on the DOCX paragraph/run
    #   2. size Pdfium reported at the tag's position in the rendered PDF
    #   3. Word's effective defaults (Helvetica / 11pt)
    def apply_font_defaults_to_field(field_def, measured_font_size_pt)
      return unless field_def

      preferences = field_def[:preferences] || {}

      preferences['font'] = DEFAULT_FONT_NAME if preferences['font'].blank?

      if preferences['font_size'].blank?
        preferences['font_size'] =
          if measured_font_size_pt.to_i.positive?
            measured_font_size_pt.to_i
          else
            DEFAULT_FONT_SIZE_PT
          end
      end

      field_def[:preferences] = preferences
    end

    # Threshold (in normalized page coordinates, 0..1) beyond which a table
    # tag is considered horizontally misplaced compared to its column
    # siblings. 0.04 ≈ 25pt on Letter — much larger than any legitimate
    # run-to-run tracking jitter, small enough to catch the "attached to
    # preceding paragraph's tail" failure mode where the offset is typically
    # 20%+ of the page width.
    TABLE_COLUMN_X_TOLERANCE = 0.04

    # Threshold (normalized page coords) for considering a tag's y value an
    # outlier relative to the expected row y derived from its siblings. ~10pt.
    TABLE_ROW_Y_TOLERANCE = 0.012

    # Post-process positioned table tags to snap obvious outliers back to
    # the column/row position established by their sibling tags.
    #
    # Motivation: LibreOffice sometimes renders a table cell's white
    # placeholder text at the trailing position of the PREVIOUS paragraph
    # instead of inside the cell. This puts checkbox/date fields that sit
    # alone in the first row of a table far to the right and one line too
    # high. Because the remaining rows of the same table/column render
    # correctly, we can use their (x, y) to detect and correct the outlier.
    #
    # Correction rules (only applied when a tag has ≥2 siblings in the same
    # table+column on the same page):
    #   * x is replaced with the siblings' median x when the current x
    #     deviates by more than TABLE_COLUMN_X_TOLERANCE.
    #   * y is replaced with the expected-row y (row_idx × row spacing
    #     derived from siblings) when the current y deviates by more than
    #     TABLE_ROW_Y_TOLERANCE.
    def correct_misplaced_table_tag_positions(positioned, pdf_text_map = nil)
      return if positioned.blank?

      # Group by (page, table_idx, col_idx) — these share a column's x and
      # a deterministic row→y mapping.
      groups = positioned.group_by do |e|
        ti = e[:tag_info]
        next nil unless ti[:in_table] && !ti[:table_idx].nil? && !ti[:col_idx].nil? && !ti[:row_idx].nil?
        [e[:area][:page], ti[:table_idx], ti[:col_idx]]
      end
      groups.delete(nil)

      groups.each do |_group_key, entries|
        next if entries.size < 2

        # LibreOffice's misplacement always shifts the tag to the RIGHT
        # (attaches to the tail of the preceding paragraph). So the
        # smallest x among siblings is the one that stayed inside the
        # column. Use it as the reference column left edge.
        reference_x = entries.map { |e| e[:area][:x] }.min

        # Any sibling within tolerance of reference_x is trustworthy for
        # extrapolating the row → y relationship.
        consistent = entries.select { |e| (e[:area][:x] - reference_x).abs <= TABLE_COLUMN_X_TOLERANCE }
        next if consistent.empty?

        consistent_ys = consistent.map { |e| [e[:tag_info][:row_idx], e[:area][:y]] }
        row_y_slope, row_y_intercept = linear_fit(consistent_ys)

        entries.each do |entry|
          area = entry[:area]
          tag_info = entry[:tag_info]
          row_idx = tag_info[:row_idx]

          x_is_outlier = (area[:x] - reference_x) > TABLE_COLUMN_X_TOLERANCE
          expected_y = row_y_slope ? (row_y_slope * row_idx + row_y_intercept) : nil
          y_is_outlier = expected_y && (area[:y] - expected_y).abs > TABLE_ROW_Y_TOLERANCE

          next unless x_is_outlier || y_is_outlier

          # Prefer the row's actual label y from the PDF when available —
          # this is more accurate than linear extrapolation for 2-row
          # tables (where regression only has one data point) and always
          # accurate when LibreOffice rendered the neighboring cell text
          # correctly, which is the overwhelming common case.
          label_y = find_row_label_y(tag_info, pdf_text_map, area[:page])
          correction_y =
            if label_y && (area[:y] - label_y).abs > TABLE_ROW_Y_TOLERANCE
              label_y
            elsif y_is_outlier && expected_y
              expected_y
            end

          old_x = area[:x]
          old_y = area[:y]
          area[:x] = reference_x if x_is_outlier
          area[:y] = correction_y if correction_y

          Rails.logger.info(
            "ExtractDocxFieldPositions: Correcting misplaced table tag #{tag_info[:name]} " \
            "(table=#{tag_info[:table_idx]} row=#{row_idx} col=#{tag_info[:col_idx]}): " \
            "(#{old_x.round(3)}, #{old_y.round(3)}) -> (#{area[:x].round(3)}, #{area[:y].round(3)})" \
            "#{label_y ? " [label_y=#{label_y.round(3)}]" : ''}"
          )
        end
      end
    end

    # Look up the y of a table row by searching the PDF for the text of
    # the row's neighboring cells. Returns the y of the first decent
    # match on `page`, or nil when no match is found (or the inputs are
    # missing). This is the authoritative row y because the renderer
    # only mislays short invisible tag paragraphs — the sibling cell
    # text (long, visible) always lands on the correct row.
    MIN_LABEL_SEARCH_CHARS = 6

    def find_row_label_y(tag_info, pdf_text_map, page)
      return nil if pdf_text_map.blank? || tag_info[:row_labels].blank? || page.nil?

      page_entries = pdf_text_map.select { |e| e[:page] == page }
      return nil if page_entries.empty?

      expanded = []
      page_entries.each_with_index do |entry, node_idx|
        entry[:text].each_char { |c| expanded << { char: c, node_idx: node_idx } }
      end

      tag_info[:row_labels].each do |label|
        next if label.blank?

        compact = label.gsub(/\s+/, '')
        next if compact.length < MIN_LABEL_SEARCH_CHARS

        # Use a prefix long enough to be distinctive but short enough to
        # avoid line-wrap splits inside the PDF text stream.
        probe = compact[0, [compact.length, 30].min]
        match_idx = find_sequence_in_expanded(expanded, probe.chars)
        next unless match_idx

        entry = page_entries[expanded[match_idx][:node_idx]]
        return entry[:y]
      end

      nil
    rescue StandardError => e
      Rails.logger.debug("ExtractDocxFieldPositions: find_row_label_y failed: #{e.message}")
      nil
    end

    # Simple linear regression: fit y = slope * x + intercept over points
    # [[x1, y1], [x2, y2], ...]. Returns [slope, intercept] or [nil, nil]
    # when there isn't enough variance to fit (all x equal). Used for the
    # row_idx → y mapping inside a table column.
    def linear_fit(points)
      return [nil, nil] if points.size < 2

      xs = points.map { |p| p[0].to_f }
      ys = points.map { |p| p[1].to_f }
      mean_x = xs.sum / xs.size
      mean_y = ys.sum / ys.size

      denom = xs.sum { |x| (x - mean_x)**2 }
      return [nil, mean_y] if denom.zero?

      numer = xs.zip(ys).sum { |x, y| (x - mean_x) * (y - mean_y) }
      slope = numer / denom
      intercept = mean_y - (slope * mean_x)
      [slope, intercept]
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
      # Only carry explicit non-default alignments (center/right); left/justify are
      # HexaPDF's default behavior and don't need to be stored.
      align_value = tag_info[:alignment].to_s.downcase
      if align_value.present? && align_value.in?(%w[center right])
        preferences['align'] = align_value
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
