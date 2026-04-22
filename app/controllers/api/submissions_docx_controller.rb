# frozen_string_literal: true

module Api
  class SubmissionsDocxController < ApiBaseController
    before_action do
      authorize!(:create, Template)
      authorize!(:create, Submission)
    end

    # POST /api/submissions/docx
    # Create a one-off submission from DOCX with variables and embedded text field tags
    def create
      Params::SubmissionDocxValidator.call(params) if defined?(Params::SubmissionDocxValidator)

      documents_data = normalize_documents(params[:documents] || [{ file: params[:file], name: params[:name] }])

      return render json: { error: 'No documents provided' }, status: :unprocessable_entity if documents_data.blank?

      # [[...]] / {{...}} substitution uses one flat map; merge top-level `variables` with each
      # submitter's optional `variables` (request order; later submitters override duplicate keys).
      variables = merge_docx_substitution_variables(params[:variables], params[:submitters])

      # Store custom logo/branding if provided via API
      if params[:logo_url].present?
        current_account.account_configs.find_or_initialize_by(key: AccountConfig::COMPANY_LOGO_URL_KEY).tap do |config|
          config.value = params[:logo_url].to_s
          config.save!
        end
        Rails.logger.info("DOCX Submission: Set custom logo URL: #{params[:logo_url]}")
      end
      
      if params[:company_name].present?
        current_account.account_configs.find_or_initialize_by(key: AccountConfig::COMPANY_NAME_KEY).tap do |config|
          config.value = params[:company_name].to_s
          config.save!
        end
        Rails.logger.info("DOCX Submission: Set company name: #{params[:company_name]}")
      end
      
      if params[:stamp_url].present?
        current_account.account_configs.find_or_initialize_by(key: AccountConfig::STAMP_URL_KEY).tap do |config|
          config.value = params[:stamp_url].to_s
          config.save!
        end
        Rails.logger.info("DOCX Submission: Set stamp URL: #{params[:stamp_url]}")
      end

      # Create a temporary template
      template = current_account.templates.new(
        author: current_user,
        name: params[:name].presence || 'DOCX Submission',
        folder: current_account.default_template_folder
      )

      # Apply template-level preferences from the request (e.g. email attachment
      # toggles like completed_notification_email_attach_audit). These override
      # the account-level defaults for this specific submission's template.
      if params[:preferences].present?
        incoming_prefs = params[:preferences]
        incoming_prefs = incoming_prefs.to_unsafe_h if incoming_prefs.respond_to?(:to_unsafe_h)
        template.preferences = (template.preferences || {}).merge(incoming_prefs.deep_stringify_keys)
        Rails.logger.info("DOCX Submission: Template preferences applied: #{template.preferences.inspect}")
      end

      # Process each DOCX document
      processed_documents = []
      docx_extracted_fields = [] # Fields extracted from DOCX {{...}} tags
      original_docx_data_for_positioning = nil # Keep original DOCX for field positioning
      
      documents_data.each do |doc_data|
        file_data = decode_file(doc_data[:file])
        
        if file_data.blank?
          Rails.logger.error("DOCX Submission: file_data is blank for #{doc_data[:name]}")
          next
        end

        Rails.logger.info("DOCX Submission: Processing file #{doc_data[:name]}, size: #{file_data.bytesize} bytes")

        # Process DOCX - extract field tags BEFORE variable substitution
        if docx_file?(file_data, doc_data[:name])
          begin
            require_relative '../../../lib/templates/process_docx_variables'
            
            # Save original DOCX data for field positioning later
            original_docx_data_for_positioning = file_data.dup
            
            # Extract {{...}} field tags from DOCX (before they might get modified)
            fields = Templates::ProcessDocxVariables.extract_field_tags(file_data)
            if fields.any?
              Rails.logger.info("DOCX Submission: Extracted #{fields.size} field tags from DOCX")
              docx_extracted_fields.concat(fields)
            end
            
            # Process [[...]] variables if any
            if variables.present? && Templates::ProcessDocxVariables.contains_variables?(file_data)
              Rails.logger.info("DOCX Submission: File contains variables, processing...")
              file_data = Templates::ProcessDocxVariables.call(file_data, variables)
            else
              Rails.logger.info("DOCX Submission: File has no variables to process")
            end
          rescue StandardError => e
            Rails.logger.error("DOCX Submission: Error processing DOCX: #{e.message}")
            Rails.logger.error(e.backtrace.first(3).join("\n"))
            # Continue with original file if processing fails
          end
        end

        processed_documents << {
          data: file_data,
          name: doc_data[:name] || 'document',
          content_type: determine_content_type(doc_data[:name], file_data)
        }
      end

      return render json: { error: 'No valid documents processed' }, status: :unprocessable_entity if processed_documents.blank?

      template.save!

      # Create attachments from processed documents
      # SINGLE-PDF APPROACH:
      # 1. Make tags invisible in DOCX (white font color, original text preserved)
      # 2. Convert to PDF - this is the final document
      # 3. Detect tag positions in THIS SAME PDF using Pdfium
      #    (Pdfium extracts all text regardless of color, so white tags are still findable)
      # 4. Place form fields at the detected positions
      #
      # Using the SAME PDF for detection and display eliminates any layout mismatch
      # that could occur from two separate Gotenberg conversions.
      tagged_pdf_data = nil
      
      processed_documents.each do |doc|
        # Convert DOCX to PDF if needed
        if doc[:content_type].include?('wordprocessingml') || doc[:name].to_s.end_with?('.docx')
          original_docx_data = doc[:data]
          
          # Make tags invisible in DOCX (white color) and convert to PDF
          Rails.logger.info("DOCX Submission: Making tags invisible and converting to PDF...")
          clean_docx_data = remove_tags_from_docx(original_docx_data)
          clean_pdf_data = convert_docx_to_pdf(clean_docx_data, doc[:name])
          
          if clean_pdf_data.nil?
            return render json: { 
              error: 'DOCX to PDF conversion not available. Please upload a PDF file instead, or configure Gotenberg service.',
              hint: 'Set GOTENBERG_URL environment variable to enable DOCX conversion (e.g., http://gotenberg:3000)'
            }, status: :unprocessable_entity
          end
          
          Rails.logger.info("DOCX Submission: Clean PDF size: #{clean_pdf_data.bytesize} bytes")
          
          # Use the clean PDF for BOTH display AND position detection
          # White tag text is invisible to users but still extractable by Pdfium
          tagged_pdf_data = clean_pdf_data
          
          doc[:data] = clean_pdf_data
          doc[:name] = doc[:name].to_s.sub(/\.docx$/i, '.pdf')
          doc[:content_type] = 'application/pdf'
        end

        Rails.logger.info("DOCX Submission: Creating attachment for #{doc[:name]}, size: #{doc[:data].bytesize}, content_type: #{doc[:content_type]}")
        
        tempfile = Tempfile.new([File.basename(doc[:name], '.*'), File.extname(doc[:name]).presence || '.pdf'])
        tempfile.binmode
        tempfile.write(doc[:data])
        tempfile.flush
        tempfile.rewind

        Rails.logger.info("DOCX Submission: Tempfile created at #{tempfile.path}, size: #{tempfile.size}")

        uploaded_file = ActionDispatch::Http::UploadedFile.new(
          filename: doc[:name],
          type: doc[:content_type],
          tempfile: tempfile
        )

        Rails.logger.info("DOCX Submission: Calling CreateAttachments...")
        result = Templates::CreateAttachments.call(template, { files: [uploaded_file] }, extract_fields: true)
        Rails.logger.info("DOCX Submission: CreateAttachments result: #{result.inspect}")

        tempfile.close
        tempfile.unlink
      end

      # Reload template to get updated documents
      template.reload
      Rails.logger.info("DOCX Submission: Template has #{template.documents.count} documents")

      # Field detection: detect tag positions in the SAME PDF that users will see.
      # Tags are invisible (white) but Pdfium can still extract them, so positions
      # are guaranteed to match the final document layout exactly.
      
      all_fields = []
      first_doc = template.documents.first
      
      if first_doc && docx_extracted_fields.any? && tagged_pdf_data.present? && original_docx_data_for_positioning.present?
        begin
          require_relative '../../../lib/templates/extract_docx_field_positions'
          
          # PRIMARY: Use docx gem to parse DOCX structure + Pdfium for positions
          # This handles tables with column filtering for multi-column layouts
          Rails.logger.info("DOCX Submission: Using ExtractDocxFieldPositions (docx gem + Pdfium)...")
          
          positioned_fields = Templates::ExtractDocxFieldPositions.call(
            original_docx_data_for_positioning,
            tagged_pdf_data,
            first_doc
          )
          
          Rails.logger.info("DOCX Submission: ExtractDocxFieldPositions found #{positioned_fields.size} positioned fields")
          
          if positioned_fields.any?
            positioned_fields.each do |field|
              all_fields << field
              area = field[:areas]&.first
              Rails.logger.info("  #{field[:name]} (#{field[:type]}) -> page=#{area[:page]} pos=(#{area[:x].round(3)}, #{area[:y].round(3)}) size=(#{area[:w].round(3)}x#{area[:h].round(3)})")
            end
          end
        rescue LoadError, StandardError => e
          Rails.logger.warn("DOCX Submission: ExtractDocxFieldPositions failed: #{e.message}")
          Rails.logger.warn(e.backtrace.first(5).join("\n"))
        end

        # FALLBACK: If ExtractDocxFieldPositions found nothing (e.g. docx gem can't
        # parse the file), use ParsePdfTextTags which works directly on the tagged PDF
        # without needing the docx gem. This handles non-table documents reliably.
        if all_fields.empty? && tagged_pdf_data.present?
          begin
            require_relative '../../../lib/templates/parse_pdf_text_tags'
            
            Rails.logger.info("DOCX Submission: Falling back to ParsePdfTextTags (direct PDF tag detection)...")
            
            pdf_positioned_fields = Templates::ParsePdfTextTags.call(tagged_pdf_data, first_doc)
            
            Rails.logger.info("DOCX Submission: ParsePdfTextTags found #{pdf_positioned_fields.size} fields")

            # ParsePdfTextTags works from PDF only; inject DOCX formatting if available
            if original_docx_data_for_positioning.present?
              docx_formatting = extract_docx_field_formatting(original_docx_data_for_positioning)
              pdf_positioned_fields.each do |field|
                merge_docx_formatting_into_field(field, docx_formatting)
              end
            end

            pdf_positioned_fields.each do |field|
              all_fields << field
              area = field[:areas]&.first
              Rails.logger.info("  #{field[:name]} (#{field[:type]}) -> page=#{area[:page]} pos=(#{area[:x].round(3)}, #{area[:y].round(3)}) size=(#{area[:w].round(3)}x#{area[:h].round(3)})")
            end
          rescue StandardError => e
            Rails.logger.warn("DOCX Submission: ParsePdfTextTags failed: #{e.message}")
            Rails.logger.warn(e.backtrace.first(5).join("\n"))
          end
        end
        
        # LAST RESORT: Hardcoded positions if both methods failed
        if all_fields.empty?
          Rails.logger.warn("DOCX Submission: Both detection methods failed, using hardcoded fallback positions")
          last_page = [get_pdf_page_count(tagged_pdf_data) - 1, 0].max
          use_pdf_fallback(all_fields, docx_extracted_fields, first_doc, last_page)
        end
      end
      
      # Final fallback: Create default signature fields if no fields found
      if all_fields.empty?
        # No fields from DOCX tags, create default signature fields
        Rails.logger.info("DOCX Submission: No field tags in DOCX, creating default signature fields")
        raw_submitters = params[:submitters] || [{ role: 'First Party', email: params[:email] }]
        submitters_list = Array.wrap(raw_submitters)
        
        if first_doc
          # Get the last page of the document
          document_data = first_doc.download
          last_page = 0
          begin
            pdf_doc = Pdfium::Document.open_bytes(document_data)
            last_page = [pdf_doc.page_count - 1, 0].max
            pdf_doc.close
            Rails.logger.info("DOCX Submission: PDF has #{last_page + 1} pages, using last page (#{last_page})")
          rescue => e
            Rails.logger.warn("Could not get page count: #{e.message}")
          end
          
          submitters_list.each_with_index do |s, i|
            s = s.to_unsafe_h if s.is_a?(ActionController::Parameters)
            role_name = s.is_a?(Hash) ? (s['role'] || s[:role] || "Party #{i + 1}") : "Party #{i + 1}"
            
            # Position: left column for first submitter, right for second, etc.
            base_x = i.even? ? 0.08 : 0.52
            
            all_fields << {
              uuid: SecureRandom.uuid,
              name: "#{role_name} Signature",
              type: 'signature',
              required: true,
              role: role_name.to_s,
              areas: [{
                page: last_page,  # Use last page, not page 0
                x: base_x,
                y: 0.83,
                w: 0.38,
                h: 0.05,
                attachment_uuid: first_doc.uuid
              }]
            }
            Rails.logger.info("DOCX Submission: Created default signature field for #{role_name} at page=#{last_page} x=#{base_x}")
          end
        end
      end

      Rails.logger.info("DOCX Submission: Total fields to add: #{all_fields.size}")

      # Set up submitters from params
      raw_submitters = params[:submitters] || [{ role: 'First Party', email: params[:email] }]
      submitters_params = Array.wrap(raw_submitters).map do |s|
        s = s.to_unsafe_h if s.is_a?(ActionController::Parameters)
        s = s.with_indifferent_access if s.is_a?(Hash)
        s
      end

      Rails.logger.info("DOCX Submission: Creating with #{submitters_params.size} submitters")

      # Build template submitters structure
      template.submitters = submitters_params.map.with_index do |s, i|
        {
          'uuid' => SecureRandom.uuid,
          'name' => (s['role'] || s[:role] || s['name'] || s[:name] || "Party #{i + 1}").to_s
        }
      end

      # Assign fields to submitters
      assigned_fields = []
      all_fields.each_with_index do |field, field_idx|
        # Determine which submitter this field belongs to
        submitter_idx = if field[:role].present?
          # Find submitter by role name
          template.submitters.find_index { |s| s['name'].to_s.downcase == field[:role].to_s.downcase } || 0
        else
          # Assign round-robin to submitters
          field_idx % template.submitters.size
        end
        
        submitter_uuid = template.submitters[submitter_idx]['uuid']
        
        # Ensure areas have string keys and correct attachment_uuid
        field_areas = (field[:areas] || []).map do |area|
          area_hash = area.is_a?(Hash) ? area.stringify_keys : {}
          # Use first document if no attachment_uuid specified
          area_hash['attachment_uuid'] ||= template.documents.first&.uuid
          area_hash['page'] ||= 0
          area_hash['x'] = area_hash['x'].to_f
          area_hash['y'] = area_hash['y'].to_f
          area_hash['w'] = area_hash['w'].to_f
          area_hash['h'] = area_hash['h'].to_f
          area_hash
        end
        
        assigned_field = {
          'uuid' => field[:uuid] || SecureRandom.uuid,
          'submitter_uuid' => submitter_uuid,
          'name' => field[:name] || "Field #{field_idx + 1}",
          'type' => field[:type] || 'signature',
          'required' => field[:required].nil? ? true : field[:required],
          'readonly' => field[:readonly] || false,
          'areas' => field_areas
        }
        
        # Add optional attributes from official SealRoute spec
        assigned_field['default_value'] = field[:default_value] if field[:default_value].present?
        assigned_field['default'] = field[:default] if field[:default].present?
        assigned_field['preferences'] = field[:preferences] if field[:preferences].present?
        assigned_field['options'] = field[:options] if field[:options].present?
        assigned_field['condition'] = field[:condition] if field[:condition].present?
        assigned_field['format'] = field[:format] if field[:format].present?
        
        Rails.logger.info("DOCX Submission: Field '#{assigned_field['name']}' (#{assigned_field['type']}) assigned to submitter #{submitter_idx} (#{template.submitters[submitter_idx]['name']})")
        assigned_fields << assigned_field
      end

      # Build schema - just links to documents, NO fields here
      template.schema = template.documents.map do |doc|
        {
          'attachment_uuid' => doc.uuid,
          'name' => doc.filename.to_s
        }
      end
      
      # Fields go in the separate fields attribute
      template.fields = assigned_fields

      Rails.logger.info("DOCX Submission: Schema has #{template.schema.size} documents, #{template.fields.size} fields")
      
      # Log all fields for debugging
      Rails.logger.info("DOCX Submission: Final template fields:")
      template.fields.each_with_index do |f, i|
        area = f['areas']&.first
        pos_str = area ? "pos=(#{area['x'].to_f.round(3)}, #{area['y'].to_f.round(3)})" : "no position"
        Rails.logger.info("  #{i + 1}. #{f['name']} (type=#{f['type']}) #{pos_str}")
      end

      template.save!

      Rails.logger.info("DOCX Submission: Template saved with ID #{template.id}, submitters: #{template.submitters.inspect}")

      # Create submissions - use HashWithIndifferentAccess for compatibility
      submission_data = {
        submitters: submitters_params.map.with_index do |s, i|
          role_name = (s['role'] || s[:role] || s['name'] || s[:name] || "Party #{i + 1}").to_s
          email_val = (s['email'] || s[:email]).to_s
          phone_val = (s['phone'] || s[:phone]).to_s
          name_val = (s['name'] || s[:name]).to_s
          
          # Use string keys - create_from_submitters uses .slice('email', 'phone', 'name')
          submitter_data = {
            'uuid' => template.submitters[i]['uuid'],
            'role' => role_name
          }
          submitter_data['email'] = email_val if email_val.present?
          submitter_data['phone'] = phone_val if phone_val.present?
          submitter_data['name'] = name_val if name_val.present?
          submitter_data['external_id'] = (s['external_id'] || s[:external_id]).to_s if (s['external_id'] || s[:external_id]).present?
          submitter_data['metadata'] = (s['metadata'] || s[:metadata] || {})

          # Pass through communication and verification settings
          submitter_data['send_email'] = s['send_email'] || s[:send_email] unless (s['send_email'] || s[:send_email]).nil?
          submitter_data['send_sms'] = s['send_sms'] || s[:send_sms] unless (s['send_sms'] || s[:send_sms]).nil?
          submitter_data['require_phone_2fa'] = s['require_phone_2fa'] || s[:require_phone_2fa] unless (s['require_phone_2fa'] || s[:require_phone_2fa]).nil?
          submitter_data['require_email_2fa'] = s['require_email_2fa'] || s[:require_email_2fa] unless (s['require_email_2fa'] || s[:require_email_2fa]).nil?
          submitter_data['completed_redirect_url'] = (s['completed_redirect_url'] || s[:completed_redirect_url]).to_s if (s['completed_redirect_url'] || s[:completed_redirect_url]).present?
          submitter_data['reply_to'] = (s['reply_to'] || s[:reply_to]).to_s if (s['reply_to'] || s[:reply_to]).present?
          submitter_data['go_to_last'] = s['go_to_last'] || s[:go_to_last] unless (s['go_to_last'] || s[:go_to_last]).nil?
          submitter_data['order'] = s['order'] || s[:order] if (s['order'] || s[:order]).present?
          submitter_data['message'] = (s['message'] || s[:message]) if (s['message'] || s[:message]).present?

          # Pass through per-submitter consent settings
          submitter_data['consent_enabled'] = s['consent_enabled'] || s[:consent_enabled] unless (s['consent_enabled'] || s[:consent_enabled]).nil?
          submitter_data['consent_document_url'] = (s['consent_document_url'] || s[:consent_document_url]).to_s if (s['consent_document_url'] || s[:consent_document_url]).present?
          submitter_data['consent_document_text'] = (s['consent_document_text'] || s[:consent_document_text]).to_s if (s['consent_document_text'] || s[:consent_document_text]).present?

          # Convert to HashWithIndifferentAccess so both symbol and string keys work
          submitter_data = submitter_data.with_indifferent_access
          
          Rails.logger.info("DOCX Submission: Submitter #{i}: #{submitter_data.inspect}")
          
          submitter_data
        end
      }

      # Add consent settings if provided
      submission_data[:consent_enabled] = params[:consent_enabled] if params.key?(:consent_enabled)
      submission_data[:consent_document_url] = params[:consent_document_url] if params[:consent_document_url].present?
      submission_data[:consent_document_text] = params[:consent_document_text] if params[:consent_document_text].present?

      submissions_attrs = [submission_data]

      Rails.logger.info("DOCX Submission: submissions_attrs = #{submissions_attrs.inspect}")

      submissions = Submissions.create_from_submitters(
        template: template,
        user: current_user,
        source: :api,
        submitters_order: params[:order] || 'preserved',
        submissions_attrs: submissions_attrs,
        params: params
      )

      Rails.logger.info("DOCX Submission: Created #{submissions.size} submission(s)")
      submissions.each do |sub|
        Rails.logger.info("DOCX Submission: Submission ID=#{sub.id}, submitters=#{sub.submitters.map { |s| { id: s.id, email: s.email, phone: s.phone, slug: s.slug } }}")
      end

      # Pre-generate stamp attachments for all stamp fields so signers
      # see the stamp already filled in (no upload required)
      prefill_stamp_fields(submissions)

      # Always call send_signature_requests - it handles email AND phone webhooks
      # The send_email preference is already set at submitter level
      Rails.logger.info("DOCX Submission: Sending signature requests (email + phone webhook)...")
      Submissions.send_signature_requests(submissions)

      response_data = build_response(submissions)
      Rails.logger.info("DOCX Submission: Response = #{response_data.to_json}")
      
      render json: response_data
    rescue StandardError => e
      Rails.logger.error("SubmissionsDocxController error: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))

      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    # Build the variable hash passed to ProcessDocxVariables. Top-level `variables` is the base;
    # each element of `submitters` may include its own `variables` object (same keys as in the
    # DOCX, e.g. [[Nama Anggota]] → "Nama Anggota") so values can live next to the matching role.
    def merge_docx_substitution_variables(top_level, raw_submitters)
      base = (top_level || {}).respond_to?(:to_unsafe_h) ? top_level.to_unsafe_h : (top_level || {})
      base = base.deep_stringify_keys

      Array.wrap(raw_submitters).each do |sub|
        next if sub.blank?

        h = sub.respond_to?(:to_unsafe_h) ? sub.to_unsafe_h : sub
        h = h.stringify_keys if h.is_a?(Hash)
        next unless h.is_a?(Hash)

        nested = h['variables']
        next if nested.blank?

        nested = nested.respond_to?(:to_unsafe_h) ? nested.to_unsafe_h : nested
        base.merge!(nested.deep_stringify_keys)
      end

      base
    end

    DOCX_FONT_MAP = {
      'times new roman' => 'Times',
      'times' => 'Times',
      'courier new' => 'Courier',
      'courier' => 'Courier',
      'arial' => 'Helvetica',
      'helvetica' => 'Helvetica'
    }.freeze

    # Map DOCX <w:jc w:val="..."> values to the subset HexaPDF accepts.
    # Prevents "ArgumentError: :start is not a valid text_align value" from
    # Office Open XML alignments like "start", "end", "distribute".
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

    # Extract per-tag formatting (alignment, font) from the DOCX XML.
    # Returns { "TagName" => { alignment: "center", font: "Times" }, ... }
    def extract_docx_field_formatting(docx_data)
      require 'zip'
      require 'nokogiri'

      formatting = {}
      return formatting if docx_data.blank?

      tempfile = Tempfile.new(['docx_fmt', '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.close

      begin
        Zip::File.open(tempfile.path) do |zip_file|
          entry = zip_file.find_entry('word/document.xml')
          return formatting unless entry

          xml = Nokogiri::XML(entry.get_input_stream.read)
          ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }

          # Detect document defaults from docDefaults and Normal style
          doc_default_font = nil
          doc_default_font_size = nil

          default_rpr = xml.at_xpath('//w:docDefaults/w:rPrDefault/w:rPr', ns)
          if default_rpr
            rfonts = default_rpr.at_xpath('w:rFonts', ns)
            if rfonts
              raw = (rfonts['w:ascii']) rescue nil
              doc_default_font = DOCX_FONT_MAP[raw.to_s.downcase] if raw.present?
            end
            sz = default_rpr.at_xpath('w:sz', ns)
            if sz
              half_points = (sz['w:val'].to_i) rescue 0
              doc_default_font_size = half_points / 2 if half_points > 0
            end
          end

          unless doc_default_font
            normal_rfonts = xml.at_xpath('//w:style[@w:styleId="Normal"]/w:rPr/w:rFonts', ns)
            if normal_rfonts
              raw = (normal_rfonts['w:ascii']) rescue nil
              doc_default_font = DOCX_FONT_MAP[raw.to_s.downcase] if raw.present?
            end
          end

          unless doc_default_font_size
            normal_sz = xml.at_xpath('//w:style[@w:styleId="Normal"]/w:rPr/w:sz', ns)
            if normal_sz
              half_points = (normal_sz['w:val'].to_i) rescue 0
              doc_default_font_size = half_points / 2 if half_points > 0
            end
          end

          Rails.logger.info("extract_docx_field_formatting: document defaults font=#{doc_default_font.inspect} font_size=#{doc_default_font_size.inspect}pt")

          xml.xpath('//w:p', ns).each do |para|
            full_text = para.xpath('.//w:t', ns).map(&:text).join
            next unless full_text.include?('{{')

            full_text.scan(/\{\{([^}]*type=[^}]+)\}\}/i).each do |m|
              parts = m[0].split(';').map(&:strip)
              tag_name = parts.first
              next if tag_name.blank?

              jc = para.at_xpath('.//w:pPr/w:jc', ns)
              raw_alignment = jc['w:val'] if jc
              alignment = DOCX_ALIGNMENT_MAP[raw_alignment.to_s.downcase] if raw_alignment.present?

              r_fonts = para.at_xpath('.//w:r/w:rPr/w:rFonts', ns) ||
                        para.at_xpath('.//w:pPr/w:rPr/w:rFonts', ns)
              raw_font = (r_fonts['w:ascii'] if r_fonts) rescue nil
              mapped_font = DOCX_FONT_MAP[raw_font.to_s.downcase] if raw_font.present?
              mapped_font ||= doc_default_font

              sz = para.at_xpath('.//w:r/w:rPr/w:sz', ns) ||
                   para.at_xpath('.//w:pPr/w:rPr/w:sz', ns)
              raw_sz = (sz['w:val'].to_i if sz) rescue nil
              font_size_pt = raw_sz && raw_sz > 0 ? raw_sz / 2 : doc_default_font_size

              Rails.logger.info("extract_docx_field_formatting: #{tag_name} -> alignment=#{alignment.inspect} font=#{mapped_font.inspect} font_size=#{font_size_pt.inspect}pt (raw_font=#{raw_font.inspect})")

              formatting[tag_name] = { alignment: alignment, font: mapped_font, font_size: font_size_pt }
            end
          end
        end
      rescue StandardError => e
        Rails.logger.warn("extract_docx_field_formatting: #{e.message}")
      ensure
        tempfile.unlink
      end

      formatting
    end

    # Merge DOCX-derived formatting into a field that lacks it (fallback path).
    def merge_docx_formatting_into_field(field, docx_formatting)
      info = docx_formatting[field[:name].to_s]
      return unless info

      prefs = field[:preferences] || {}

      if info[:font].present? && prefs[:font].blank? && prefs['font'].blank?
        prefs[:font] = info[:font]
      end

      align_value = info[:alignment].to_s.downcase
      if align_value.present? && align_value.in?(%w[center right])
        if prefs[:align].blank? && prefs['align'].blank?
          prefs[:align] = align_value
        end
      end

      if info[:font_size].present? && prefs[:font_size].blank? && prefs['font_size'].blank?
        prefs[:font_size] = info[:font_size]
      end

      field[:preferences] = prefs if prefs.any?
    end

    # Pre-generate stamp attachments for all stamp fields.
    # This fills stamp fields with the custom stamp image (from stamp_url or logo_url)
    # so signers see it already filled in without needing to upload anything.
    def prefill_stamp_fields(submissions)
      submissions.each do |submission|
        template = submission.template
        next unless template
        
        fields = template.fields
        next if fields.blank?
        
        stamp_fields = fields.select { |f| f['type'] == 'stamp' }
        next if stamp_fields.empty?
        
        submission.submitters.each do |submitter|
          submitter_stamp_fields = stamp_fields.select { |f| f['submitter_uuid'] == submitter.uuid }
          next if submitter_stamp_fields.empty?
          
          submitter_stamp_fields.each do |field|
            begin
              attachment = Submitters::CreateStampAttachment.build_attachment(
                submitter,
                with_logo: field.dig('preferences', 'with_logo') != false
              )
              attachment.save! if attachment.new_record?
              
              submitter.values ||= {}
              submitter.values[field['uuid']] = attachment.uuid
              
              Rails.logger.info("DOCX Submission: Pre-filled stamp '#{field['name']}' for #{submitter.email}")
            rescue StandardError => e
              Rails.logger.warn("DOCX Submission: Failed to pre-fill stamp: #{e.message}")
            end
          end
          
          submitter.save! if submitter.changed?
        end
      end
    end
    
    # Use fallback positions when PDF tag detection fails
    def use_pdf_fallback(all_fields, docx_fields, first_doc, last_page)
      Rails.logger.info("DOCX Submission: Using fallback positions on page #{last_page}")
      
      docx_by_role = docx_fields.group_by { |f| f[:role]&.downcase || 'default' }
      num_columns = [docx_by_role.size, 2].max
      
      docx_by_role.each_with_index do |(role, role_fields), role_idx|
        column_idx = role_idx % num_columns
        
        role_fields.each do |field|
          add_fallback_field(all_fields, field, role, column_idx, first_doc, num_columns, last_page)
        end
      end
    end
    
    # Legacy fallback method
    def use_fallback_positions(all_fields, docx_fields, first_doc, page = 0)
      docx_by_role = docx_fields.group_by { |f| f[:role]&.downcase || 'default' }
      num_columns = [docx_by_role.size, 2].max
      
      docx_by_role.each_with_index do |(role, role_fields), role_idx|
        column_idx = role_idx % num_columns
        
        role_fields.each do |field|
          add_fallback_field(all_fields, field, role, column_idx, first_doc, num_columns, page)
        end
      end
    end
    
    # Get PDF page count using Pdfium
    def get_pdf_page_count(pdf_data)
      begin
        doc = Pdfium::Document.open_bytes(pdf_data)
        count = doc.page_count
        doc.close
        count
      rescue StandardError => e
        Rails.logger.warn("get_pdf_page_count error: #{e.message}")
        1 # Default to 1 page
      end
    end
    
    # Determine column (left/right) for a role name
    def determine_column_for_role(role)
      role_lower = role.to_s.downcase
      
      # Common role patterns for left column (first party)
      left_patterns = %w[buyer first customer client tenant employee applicant borrower patient]
      # Common role patterns for right column (second party)
      right_patterns = %w[seller second vendor supplier landlord employer company lender doctor provider]
      
      return :left if left_patterns.any? { |p| role_lower.include?(p) }
      return :right if right_patterns.any? { |p| role_lower.include?(p) }
      
      # Check for party numbering (Party 1, Party 2, etc.)
      if role_lower.match?(/party.?(\d+)/)
        num = role_lower.match(/party.?(\d+)/)[1].to_i
        return num.odd? ? :left : :right
      end
      
      :left # Default to left column
    end
    
    # Default field width based on type
    def default_width_for_type(field_type)
      case field_type.to_s
      when 'signature', 'initials', 'image'
        0.25
      when 'checkbox'
        0.03
      else
        0.15
      end
    end
    
    # Default field height based on type
    def default_height_for_type(field_type)
      case field_type.to_s
      when 'signature', 'initials', 'image'
        0.05
      when 'checkbox'
        0.025
      else
        0.025
      end
    end
    
    # Add a field with fallback positioning based on role and column index
    def add_fallback_field(all_fields, docx_field, role, column_idx, first_doc, total_columns = 2, page = 0)
      role_lower = role.to_s.downcase
      field_type = docx_field[:type]
      
      # Count existing fields for this role to determine Y position
      role_field_count = all_fields.count { |f| (f[:role] || '').to_s.downcase == role_lower }
      
      # Calculate X position based on column index and total columns
      # Spread columns evenly across the page width
      column_width = 1.0 / total_columns
      base_x = (column_idx * column_width) + 0.05  # 5% margin from column start
      
      signature_start_y = 0.82  # Where signature section typically starts
      
      # Stack fields vertically
      field_y = signature_start_y + (role_field_count * 0.035)
      
      # Size based on field type
      is_signature = field_type.in?(%w[signature initials])
      field_w = [is_signature ? 0.38 : 0.35, column_width - 0.1].min  # Don't exceed column width
      field_h = is_signature ? 0.045 : 0.025
      
      fallback_field = docx_field.merge(
        areas: [{
          page: page,  # Use provided page number
          x: base_x,
          y: [field_y, 0.95].min,  # Don't go past page bottom
          w: field_w,
          h: field_h,
          attachment_uuid: first_doc&.uuid
        }],
        uuid: SecureRandom.uuid
      )
      
      all_fields << fallback_field
      Rails.logger.info("  - Fallback: #{docx_field[:name]} (#{field_type}) role=#{role} col=#{column_idx} page=#{page} -> pos=(#{base_x.round(3)}, #{field_y.round(3)})")
    end
    
    def normalize_documents(documents)
      Array.wrap(documents).map do |doc|
        if doc.is_a?(ActionController::Parameters) || doc.is_a?(Hash)
          doc = doc.to_unsafe_h if doc.is_a?(ActionController::Parameters)
          file_data = doc['file'] || doc[:file]
          file_name = doc['name'] || doc[:name] || doc['filename'] || doc[:filename] || 'document.docx'
          { file: file_data, name: file_name }
        else
          { file: doc.to_s, name: 'document.docx' }
        end
      end.compact
    end

    def decode_file(file_data)
      return nil if file_data.blank?

      # Handle ActionController::Parameters
      if file_data.is_a?(ActionController::Parameters)
        file_data = file_data.to_unsafe_h.values.first || file_data.to_s
      end

      Rails.logger.info("decode_file: input type=#{file_data.class}, length=#{file_data.to_s.length}")

      # Convert to string if needed
      file_data = file_data.to_s unless file_data.is_a?(String)

      if file_data.is_a?(String)
        # Check if it looks like base64 (no binary characters in first 100 chars)
        sample = file_data[0..100].to_s
        is_base64 = sample.match?(/\A[A-Za-z0-9+\/=\s]+\z/)
        
        Rails.logger.info("decode_file: appears to be base64=#{is_base64}")

        if is_base64
          # Try strict base64 decode first, fall back to lenient decode
          begin
            decoded = Base64.strict_decode64(file_data.gsub(/\s/, ''))
            Rails.logger.info("decode_file: strict decode succeeded, size=#{decoded.bytesize}")
          rescue ArgumentError => e
            Rails.logger.info("decode_file: strict decode failed (#{e.message}), trying lenient")
            decoded = Base64.decode64(file_data)
            Rails.logger.info("decode_file: lenient decode, size=#{decoded.bytesize}")
          end
        else
          # Already binary data
          decoded = file_data
          decoded = decoded.dup.force_encoding('BINARY') if decoded.respond_to?(:force_encoding)
        end

        # Validate DOCX magic bytes (PK header for ZIP)
        first_bytes = decoded[0..3]
        Rails.logger.info("decode_file: first 4 bytes=#{first_bytes.bytes.inspect}")
        
        unless first_bytes == "PK\x03\x04"
          Rails.logger.error("Invalid DOCX file: missing PK header. First 4 bytes: #{first_bytes.bytes.inspect}")
          return nil
        end

        decoded
      elsif file_data.respond_to?(:read)
        file_data.read
      else
        file_data.to_s
      end
    rescue StandardError => e
      Rails.logger.error("decode_file error: #{e.class} - #{e.message}")
      Rails.logger.error(e.backtrace.first(5).join("\n"))
      nil
    end

    def docx_file?(data, filename)
      return true if filename.to_s.end_with?('.docx')

      # Check DOCX magic bytes (PK..)
      data[0..3] == "PK\x03\x04"
    end

    def determine_content_type(filename, _data)
      case File.extname(filename.to_s).downcase
      when '.docx'
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      when '.pdf'
        'application/pdf'
      else
        'application/octet-stream'
      end
    end

    def build_response(submissions)
      submissions.flat_map do |submission|
        submission.submitters.map do |s|
          Submitters::SerializeForApi.call(s, with_documents: false, with_urls: true, params: params)
        end
      end
    end

    def convert_docx_to_pdf(docx_data, filename)
      gotenberg_url = ENV.fetch('GOTENBERG_URL', nil)
      
      return nil if gotenberg_url.blank?

      Rails.logger.info("Converting DOCX to PDF via Gotenberg: #{gotenberg_url}")

      # Disable auto-hyphenation in DOCX before conversion
      modified_docx_data = disable_docx_hyphenation(docx_data)

      begin
        require 'net/http'
        require 'uri'

        uri = URI.parse("#{gotenberg_url}/forms/libreoffice/convert")
        
        boundary = "----RubyMultipartPost#{rand(1000000)}"
        
        body = []
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"files\"; filename=\"#{filename}\"\r\n"
        body << "Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n"
        body << modified_docx_data
        body << "\r\n--#{boundary}--\r\n"
        
        request = Net::HTTP::Post.new(uri.request_uri)
        request['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        request.body = body.join

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 60

        response = http.request(request)

        if response.code == '200'
          Rails.logger.info("DOCX to PDF conversion successful, size: #{response.body.bytesize}")
          response.body
        else
          Rails.logger.error("Gotenberg error: #{response.code} - #{response.body}")
          nil
        end
      rescue StandardError => e
        Rails.logger.error("DOCX to PDF conversion error: #{e.message}")
        nil
      end
    end

    # Make all {{...}} tags invisible in DOCX content (white font color)
    # This creates a clean version where tags are hidden but layout is preserved
    def remove_tags_from_docx(docx_data)
      require 'zip'
      require 'nokogiri'
      
      Rails.logger.info("DOCX TAG REMOVAL: Starting remove_tags_from_docx, input size: #{docx_data.bytesize} bytes")
      
      tags_removed = 0
      
      # List of XML files that may contain text with tags
      text_xml_files = [
        'word/document.xml',
        'word/header1.xml', 'word/header2.xml', 'word/header3.xml',
        'word/footer1.xml', 'word/footer2.xml', 'word/footer3.xml',
        'word/footnotes.xml', 'word/endnotes.xml',
        'word/comments.xml'
      ]
      
      begin
        # Use write_buffer to create the output ZIP in memory
        # This is the correct way to create a ZIP to a StringIO
        output_io = Zip::OutputStream.write_buffer do |zos|
          Zip::File.open_buffer(docx_data) do |zip_file|
            zip_file.each do |entry|
              content = entry.get_input_stream.read
              
              # Check if this is a text-containing XML file
              is_text_xml = text_xml_files.include?(entry.name) || 
                            entry.name.match?(/^word\/(header|footer)\d+\.xml$/)
              
              if is_text_xml
                original_size = content.length
                original_content = content.dup
                
                # Preserve table row heights (safety net for consistent layout)
                content = preserve_table_row_heights(content)
                
                # Make tags invisible in this XML file (white font color)
                content, removed = remove_tags_from_document_xml(content)
                tags_removed += removed
                
                if removed > 0 || content != original_content
                  Rails.logger.info("DOCX TAG REMOVAL: Processed #{entry.name} (#{original_size} -> #{content.length} bytes, #{removed} tags)")
                end
              end
              
              zos.put_next_entry(entry.name)
              zos.write(content)
            end
          end
        end
        
        # Get the resulting bytes
        output_io.rewind
        result = output_io.read
        
        Rails.logger.info("DOCX TAG REMOVAL: Complete! Removed #{tags_removed} tags, output size: #{result.bytesize} bytes")
        
        # Verify the result is a valid ZIP
        if result[0..3] == "PK\x03\x04"
          Rails.logger.info("DOCX TAG REMOVAL: Output verified as valid DOCX/ZIP")
          result
        else
          Rails.logger.error("DOCX TAG REMOVAL: Output is not a valid ZIP! Falling back to original")
          docx_data
        end
        
      rescue StandardError => e
        Rails.logger.error("DOCX TAG REMOVAL: FAILED - #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        docx_data
      end
    end
    
    # Make {{...}} tags invisible in Word document.xml by setting font color to white.
    #
    # IMPORTANT: We do NOT replace the tag text with different characters (e.g. underscores).
    # Replacing text changes character widths in proportional fonts, which causes the clean
    # PDF layout to differ from the tagged PDF. This misalignment means form fields detected
    # from the tagged PDF end up at wrong positions on the clean PDF.
    #
    # Instead, we keep the ORIGINAL tag characters and set their font color to white (FFFFFF).
    # This makes them invisible in the final PDF while preserving identical character widths,
    # line wrapping, cell heights, and overall layout between the tagged and clean PDFs.
    def remove_tags_from_document_xml(xml_content)
      tags_removed = 0
      tag_pattern = /\{\{[^}]+\}\}/

      return [xml_content, 0] unless xml_content.include?('{{')

      begin
        doc = Nokogiri::XML(xml_content)
        ns = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }

        doc.xpath('//w:p', ns).each do |para|
          # Collect all runs with their text nodes
          run_infos = []
          para.xpath('.//w:r', ns).each do |run|
            t_node = run.at_xpath('w:t', ns)
            next unless t_node
            run_infos << { run: run, t_node: t_node, text: t_node.text.to_s }
          end

          next if run_infos.empty?

          full_text = run_infos.map { |r| r[:text] }.join
          next unless full_text.match?(tag_pattern)

          # Find all tag character ranges in the concatenated paragraph text
          tag_ranges = []
          full_text.scan(tag_pattern) { tag_ranges << [$~.begin(0), $~.end(0)] }
          next if tag_ranges.empty?

          tags_removed += tag_ranges.size

          # For each run, determine overlap with tag ranges and make tag parts white
          pos = 0
          runs_to_replace = []

          run_infos.each do |ri|
            run_start = pos
            run_end = pos + ri[:text].length

            overlaps = tag_ranges.select { |ts, te| run_end > ts && run_start < te }

            if overlaps.any?
              # Compute which character indices within this run are inside tags
              tag_mask = Array.new(ri[:text].length, false)
              overlaps.each do |ts, te|
                local_start = [ts - run_start, 0].max
                local_end = [te - run_start, ri[:text].length].min
                (local_start...local_end).each { |i| tag_mask[i] = true }
              end

              if tag_mask.all?
                # Entire run is tag text - just set color to white
                set_run_color_white(ri[:run], doc, ns)
              elsif tag_mask.none?
                # No tag text (shouldn't happen due to overlap check)
              else
                # Mixed content - split into segments and create separate runs
                runs_to_replace << { ri: ri, tag_mask: tag_mask }
              end
            end

            pos = run_end
          end

          # Process mixed-content runs (split into white/normal segments)
          runs_to_replace.each do |info|
            ri = info[:ri]
            mask = info[:tag_mask]
            text = ri[:text]
            run = ri[:run]

            segments = split_into_segments(text, mask)
            next if segments.size <= 1

            rpr_node = run.at_xpath('w:rPr', ns)

            insert_point = run
            segments.each do |seg|
              new_run = Nokogiri::XML::Node.new('w:r', doc)

              # Clone run properties
              if rpr_node
                new_rpr = rpr_node.dup
                new_run.add_child(new_rpr)
                if seg[:is_tag]
                  ensure_white_color(new_rpr, doc, ns)
                end
              elsif seg[:is_tag]
                new_rpr = Nokogiri::XML::Node.new('w:rPr', doc)
                ensure_white_color(new_rpr, doc, ns)
                new_run.add_child(new_rpr)
              end

              new_t = Nokogiri::XML::Node.new('w:t', doc)
              new_t['xml:space'] = 'preserve'
              new_t.content = seg[:text]
              new_run.add_child(new_t)

              insert_point.add_next_sibling(new_run)
              insert_point = new_run
            end

            run.remove
          end
        end

        result_xml = doc.to_xml

        if xml_content.start_with?('<?xml') && !result_xml.start_with?('<?xml')
          declaration = xml_content[/^<\?xml[^?]*\?>/]
          result_xml = "#{declaration}\n#{result_xml}" if declaration
        end

        Rails.logger.info("DOCX TAG REMOVAL: Made #{tags_removed} tag(s) invisible (white font color, original text preserved for layout)")

        [result_xml, tags_removed]

      rescue StandardError => e
        Rails.logger.error("DOCX TAG REMOVAL: Failed: #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(3).join("\n"))
        [xml_content, 0]
      end
    end

    # Set the font color of a w:r (run) element to white
    def set_run_color_white(run, doc, ns)
      rpr = run.at_xpath('w:rPr', ns)
      unless rpr
        rpr = Nokogiri::XML::Node.new('w:rPr', doc)
        run.children.first ? run.children.first.add_previous_sibling(rpr) : run.add_child(rpr)
      end
      ensure_white_color(rpr, doc, ns)
    end

    # ECMA-376 §17.3.2 CT_RPr child sequence: elements listed here must all
    # appear AFTER <w:color>. Inserting <w:color> before the first one preserves
    # schema order, which is required by LibreOffice (and other strict OOXML
    # consumers) to actually honor the color when converting DOCX to PDF.
    # Without this, Nokogiri's default add_child appends <w:color> at the end
    # (after <w:lang>), LibreOffice silently drops the out-of-order element,
    # and the {{...}} tag text renders in its original color instead of white.
    ELEMENTS_AFTER_COLOR_IN_RPR = %w[
      spacing w kern position sz szCs highlight u effect bdr shd fitText
      vertAlign rtl cs em lang eastAsianLayout specVanish oMath
    ].freeze

    # Ensure a w:rPr element has white font color, placed in the correct
    # schema position (before <w:lang>, <w:sz>, <w:highlight>, etc.).
    def ensure_white_color(rpr, doc, ns)
      color = rpr.at_xpath('w:color', ns)
      if color
        color['w:val'] = 'FFFFFF'
        return
      end

      color = Nokogiri::XML::Node.new('w:color', doc)
      color['w:val'] = 'FFFFFF'
      insert_color_in_rpr(rpr, color, ns)
    end

    # Insert <w:color> at the schema-correct position inside <w:rPr>: right
    # before the first child element that, per ECMA-376, must appear after
    # <w:color>. If no such sibling exists, append.
    def insert_color_in_rpr(rpr, color, ns)
      anchor = rpr.element_children.find do |child|
        # Nokogiri returns local_name (no prefix) for namespaced children when
        # asked via `.name`, but a few Ruby/Nokogiri combinations return the
        # "w:lang" form. Normalize by stripping any prefix before comparing.
        local = child.name.sub(/\Aw:/, '')
        ELEMENTS_AFTER_COLOR_IN_RPR.include?(local)
      end

      if anchor
        anchor.add_previous_sibling(color)
      else
        rpr.add_child(color)
      end
    end

    # Split text into segments based on a boolean mask (tag vs non-tag)
    def split_into_segments(text, tag_mask)
      segments = []
      return segments if text.empty?

      current_is_tag = tag_mask[0]
      seg_start = 0

      (1..text.length).each do |i|
        is_tag = i < text.length ? tag_mask[i] : !current_is_tag
        if is_tag != current_is_tag || i == text.length
          segments << { text: text[seg_start...i], is_tag: current_is_tag }
          seg_start = i
          current_is_tag = is_tag
        end
      end

      segments
    end


    # Preserve table row heights for rows that contain {{...}} tags
    # This prevents rows from collapsing when tag text is replaced with spaces
    # Sets explicit w:trHeight on affected rows to maintain consistent layout
    def preserve_table_row_heights(xml_content)
      tag_pattern = /\{\{[^}]+\}\}/
      
      # Quick check: only process if there are tags AND tables
      return xml_content unless xml_content.include?('{{') && xml_content.include?('<w:tbl')
      
      begin
        doc = Nokogiri::XML(xml_content)
        namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
        modified = false
        
        # Find all table rows
        doc.xpath('//w:tr', namespaces).each do |row|
          # Check if any cell in this row contains a form field tag
          row_text = row.xpath('.//w:t', namespaces).map(&:content).join
          next unless row_text.match?(tag_pattern)
          
          # This row contains tags - ensure it has explicit row height
          tr_pr = row.at_xpath('w:trPr', namespaces)
          
          # Create trPr if it doesn't exist
          unless tr_pr
            tr_pr = Nokogiri::XML::Node.new('w:trPr', doc)
            row.children.first ? row.children.first.add_previous_sibling(tr_pr) : row.add_child(tr_pr)
            modified = true
          end
          
          # Check if trHeight already exists
          tr_height = tr_pr.at_xpath('w:trHeight', namespaces)
          
          unless tr_height
            # Add minimum row height (360 twips = ~0.25 inch = ~1 line of text)
            tr_height = Nokogiri::XML::Node.new('w:trHeight', doc)
            tr_height['w:val'] = '360'
            tr_height['w:hRule'] = 'atLeast'
            tr_pr.add_child(tr_height)
            modified = true
            Rails.logger.info("DOCX TAG REMOVAL: Set row height on table row containing tags")
          end
        end
        
        if modified
          result = doc.to_xml
          # Preserve original XML declaration
          if xml_content.start_with?('<?xml') && !result.start_with?('<?xml')
            declaration = xml_content[/^<\?xml[^?]*\?>/]
            result = "#{declaration}\n#{result}" if declaration
          end
          return result
        end
      rescue StandardError => e
        Rails.logger.warn("DOCX TAG REMOVAL: preserve_table_row_heights failed: #{e.message}")
      end
      
      xml_content
    end

    # Disable auto-hyphenation in DOCX by modifying word/settings.xml
    def disable_docx_hyphenation(docx_data)
      require 'zip'
      
      begin
        # Use write_buffer to create the output ZIP in memory
        output_io = Zip::OutputStream.write_buffer do |zos|
          Zip::File.open_buffer(docx_data) do |zip_file|
            zip_file.each do |entry|
              content = entry.get_input_stream.read
              
              if entry.name == 'word/settings.xml'
                # Add or modify autoHyphenation setting to disable it
                content = modify_settings_xml(content)
                Rails.logger.debug("DOCX: Modified settings.xml to disable hyphenation")
              elsif entry.name == 'word/document.xml'
                # Add suppressAutoHyphens to all paragraphs
                content = modify_document_xml(content)
                Rails.logger.debug("DOCX: Modified document.xml to suppress hyphenation")
              end
              
              zos.put_next_entry(entry.name)
              zos.write(content)
            end
          end
        end
        
        output_io.rewind
        output_io.read
      rescue StandardError => e
        Rails.logger.warn("Failed to disable DOCX hyphenation: #{e.message}, using original")
        docx_data
      end
    end

    def modify_settings_xml(content)
      # Check if autoHyphenation already exists
      if content.include?('w:autoHyphenation')
        # Set it to false
        content.gsub(/<w:autoHyphenation[^>]*\/>/, '<w:autoHyphenation w:val="false"/>')
               .gsub(/<w:autoHyphenation[^>]*>.*?<\/w:autoHyphenation>/m, '<w:autoHyphenation w:val="false"/>')
      else
        # Add it after the opening settings tag
        content.gsub(/<w:settings[^>]*>/) do |match|
          "#{match}\n  <w:autoHyphenation w:val=\"false\"/>"
        end
      end
    end

    def modify_document_xml(content)
      # Add w:suppressAutoHyphens to paragraph properties (w:pPr)
      # This ensures each paragraph won't be hyphenated
      
      # If pPr exists, add suppressAutoHyphens inside it
      modified = content.gsub(/<w:pPr>/) do |match|
        "#{match}<w:suppressAutoHyphens w:val=\"true\"/>"
      end
      
      # Also add to existing pPr that might have other attributes
      modified = modified.gsub(/<w:pPr ([^>]*)>/) do |match|
        attrs = $1
        "<w:pPr #{attrs}><w:suppressAutoHyphens w:val=\"true\"/>"
      end
      
      # For paragraphs without pPr, we could add it but that's more complex
      # The settings.xml change should handle most cases
      
      modified
    end
  end
end
