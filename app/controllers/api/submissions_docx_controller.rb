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

      variables = (params[:variables] || {}).to_unsafe_h

      # Create a temporary template
      template = current_account.templates.new(
        author: current_user,
        name: params[:name].presence || 'DOCX Submission',
        folder: current_account.default_template_folder
      )

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
      # For DOCX files, we create TWO PDFs:
      # 1. PDF with tags - used for detecting tag positions
      # 2. PDF without tags - the clean final document where form fields are placed
      tagged_pdf_data = nil
      
      processed_documents.each do |doc|
        # Convert DOCX to PDF if needed
        if doc[:content_type].include?('wordprocessingml') || doc[:name].to_s.end_with?('.docx')
          original_docx_data = doc[:data]
          
          # Step 1: Convert DOCX (with tags) to PDF for position detection
          Rails.logger.info("DOCX Submission: Converting DOCX with tags to PDF for position detection...")
          tagged_pdf_data = convert_docx_to_pdf(original_docx_data, doc[:name])
          
          if tagged_pdf_data.nil?
            return render json: { 
              error: 'DOCX to PDF conversion not available. Please upload a PDF file instead, or configure Gotenberg service.',
              hint: 'Set GOTENBERG_URL environment variable to enable DOCX conversion (e.g., http://gotenberg:3000)'
            }, status: :unprocessable_entity
          end
          
          Rails.logger.info("DOCX Submission: Tagged PDF size: #{tagged_pdf_data.bytesize} bytes")
          
          # Step 2: Remove tags from DOCX and convert to clean PDF
          Rails.logger.info("DOCX Submission: Removing tags from DOCX and converting to clean PDF...")
          clean_docx_data = remove_tags_from_docx(original_docx_data)
          clean_pdf_data = convert_docx_to_pdf(clean_docx_data, doc[:name])
          
          if clean_pdf_data.nil?
            Rails.logger.warn("DOCX Submission: Clean PDF conversion failed, using tagged PDF")
            clean_pdf_data = tagged_pdf_data
          else
            Rails.logger.info("DOCX Submission: Clean PDF size: #{clean_pdf_data.bytesize} bytes")
          end
          
          # Use the clean PDF (without tags) as the final document
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

      # Field detection strategy (TWO-PDF APPROACH):
      # 1. Use the TAGGED PDF (tagged_pdf_data) to detect tag positions
      # 2. The final document (first_doc) is the CLEAN PDF without tags
      # 3. Place form fields on the clean PDF using positions from tagged PDF
      #
      # This avoids complex tag removal - tags are removed at DOCX level before conversion
      
      all_fields = []
      first_doc = template.documents.first
      
      if first_doc && docx_extracted_fields.any? && tagged_pdf_data.present? && original_docx_data_for_positioning.present?
        begin
          require_relative '../../../lib/templates/extract_docx_field_positions'
          
          # NEW APPROACH: Use docx gem to parse DOCX structure + Pdfium to find positions
          # This correctly handles tables and inline tags by using label-based positioning
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
          else
            # Fallback to old approach if new module finds nothing
            Rails.logger.warn("DOCX Submission: ExtractDocxFieldPositions returned empty, using fallback")
            last_page = [get_pdf_page_count(tagged_pdf_data) - 1, 0].max
            use_pdf_fallback(all_fields, docx_extracted_fields, first_doc, last_page)
          end
        rescue StandardError => e
          Rails.logger.warn("DOCX Submission: Field detection failed: #{e.message}")
          Rails.logger.warn(e.backtrace.first(5).join("\n"))
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
        
        # Add optional attributes from official DocuSeal spec
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

    # Remove all {{...}} tags from DOCX content
    # This creates a clean version without visible tags
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
                
                # Preserve table row heights before tag removal
                # This prevents rows from collapsing when tag text is removed
                content = preserve_table_row_heights(content)
                
                # Remove tags from this XML file (replaces with spaces)
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
    
    # Remove {{...}} tags from Word document.xml using multiple strategies
    def remove_tags_from_document_xml(xml_content)
      tags_removed = 0
      
      # Ensure we're working with a string with proper encoding
      result_xml = xml_content.to_s.dup
      result_xml.force_encoding('UTF-8') if result_xml.respond_to?(:force_encoding)
      
      # Count initial tags for logging
      initial_tags = result_xml.scan(/\{\{[^}]+\}\}/)
      Rails.logger.info("DOCX TAG REMOVAL: Starting - found #{initial_tags.size} tags in raw XML")
      initial_tags.first(5).each { |t| Rails.logger.info("DOCX TAG REMOVAL:   - #{t}") }
      
      # STRATEGY 1: Direct string replacement on the raw XML
      # This is the most aggressive approach - replace tags anywhere they appear
      # The tag pattern matches {{anything_except_closing_braces}}
      tag_pattern = /\{\{[^}]+\}\}/
      
      # First, do a simple global replacement to catch obvious tags
      # Replace with EQUAL-LENGTH UNDERSCORES to preserve the exact same layout
      # between tagged and clean PDFs. Underscores have similar width to regular
      # characters (unlike spaces which are narrower), so line wrapping, cell heights,
      # and column widths stay identical between tagged PDF and clean PDF.
      before_count = result_xml.scan(tag_pattern).size
      if before_count > 0
        result_xml = result_xml.gsub(tag_pattern) { |m| '_' * m.length }
        tags_removed += before_count
        Rails.logger.info("DOCX TAG REMOVAL: Strategy 1 replaced #{before_count} tags with equal-length underscores")
      end
      
      # STRATEGY 2: Process w:t elements specifically
      # This handles cases where tags are within Word text elements
      wt_tag_count = 0
      result_xml = result_xml.gsub(%r{(<w:t[^>]*>)(.*?)(</w:t>)}m) do |_match|
        open_tag = Regexp.last_match(1)
        text_content = Regexp.last_match(2)
        close_tag = Regexp.last_match(3)
        
        if text_content.include?('{{') && text_content.include?('}}')
          clean_text = text_content.gsub(tag_pattern) { |m| '_' * m.length }
          if clean_text != text_content
            wt_tag_count += 1
            Rails.logger.debug("DOCX TAG REMOVAL: Cleaned w:t: '#{text_content}' -> '#{clean_text}'")
          end
          "#{open_tag}#{clean_text}#{close_tag}"
        else
          Regexp.last_match(0)
        end
      end
      tags_removed += wt_tag_count
      Rails.logger.info("DOCX TAG REMOVAL: Strategy 2 (w:t elements) cleaned #{wt_tag_count} elements") if wt_tag_count > 0
      
      # STRATEGY 3: Handle split tags using Nokogiri
      # Word sometimes splits {{tag}} across multiple <w:t> elements like:
      # <w:t>{{</w:t><w:t>signature</w:t><w:t>}}</w:t>
      begin
        doc = Nokogiri::XML(result_xml)
        namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
        nokogiri_removed = 0
        
        doc.xpath('//w:p', namespaces).each do |paragraph|
          text_nodes = paragraph.xpath('.//w:t', namespaces)
          next if text_nodes.empty?
          
          # Build the full paragraph text
          text_parts = text_nodes.map { |node| { node: node, text: node.text || '' } }
          full_text = text_parts.map { |p| p[:text] }.join
          
          # Process while there are tags
          iteration = 0
          while full_text.match?(tag_pattern) && iteration < 50
            iteration += 1
            match_data = full_text.match(tag_pattern)
            break unless match_data
            
            tag_start = match_data.begin(0)
            tag_end = match_data.end(0)
            
            # Remove tag from the appropriate text nodes, replacing with space
            # to preserve table row heights and layout
            current_pos = 0
            first_affected = true
            text_parts.each do |part|
              part_start = current_pos
              part_end = current_pos + part[:text].length
              
              if part_end > tag_start && part_start < tag_end
                remove_start = [tag_start - part_start, 0].max
                remove_end = [tag_end - part_start, part[:text].length].min
                
                # Insert equal-length underscores in the first affected node to preserve layout
                removed_len = remove_end - remove_start
                space_insert = first_affected ? ('_' * [removed_len, 1].max) : ''
                first_affected = false
                
                new_text = part[:text][0...remove_start].to_s + space_insert + part[:text][remove_end..].to_s
                part[:node].content = new_text
                part[:text] = new_text
              end
              
              current_pos = part_end
            end
            
            nokogiri_removed += 1
            full_text = text_parts.map { |p| p[:text] }.join
          end
        end
        
        if nokogiri_removed > 0
          tags_removed += nokogiri_removed
          Rails.logger.info("DOCX TAG REMOVAL: Strategy 3 (Nokogiri split tags) removed #{nokogiri_removed} tags")
          
          # Get the XML back, preserving declaration
          result_xml = doc.to_xml
          
          # Restore original XML declaration if needed
          if xml_content.start_with?('<?xml') && !result_xml.start_with?('<?xml')
            declaration = xml_content[/^<\?xml[^?]*\?>/]
            result_xml = "#{declaration}\n#{result_xml}" if declaration
          end
        end
        
      rescue StandardError => e
        Rails.logger.warn("DOCX TAG REMOVAL: Nokogiri pass failed: #{e.message}")
      end
      
      # STRATEGY 4: Final aggressive cleanup
      # One more pass to catch anything that might have been missed
      final_tags = result_xml.scan(tag_pattern)
      if final_tags.any?
        Rails.logger.warn("DOCX TAG REMOVAL: Final cleanup needed - #{final_tags.size} tags still present")
        final_tags.each { |t| Rails.logger.warn("DOCX TAG REMOVAL:   Remaining: #{t}") }
        
        result_xml = result_xml.gsub(tag_pattern) { |m| '_' * m.length }
        tags_removed += final_tags.size
        Rails.logger.info("DOCX TAG REMOVAL: Final cleanup replaced #{final_tags.size} tags with equal-length underscores")
      end
      
      # Verify complete replacement
      verify_tags = result_xml.scan(/\{\{[^}]+\}\}/)
      if verify_tags.any?
        Rails.logger.error("DOCX TAG REMOVAL: FAILED - #{verify_tags.size} tags still in document!")
        verify_tags.first(3).each { |t| Rails.logger.error("DOCX TAG REMOVAL:   #{t}") }
      else
        Rails.logger.info("DOCX TAG REMOVAL: SUCCESS - All tags replaced with underscores (total: #{tags_removed})")
      end
      
      # Make underscore placeholders invisible by setting font color to white.
      # This keeps the same character width (preserving layout) but hides the
      # underscores in the final clean PDF.
      if tags_removed > 0
        result_xml = make_underscores_white(result_xml)
      end
      
      [result_xml, tags_removed]
    end

    # Make underscore placeholder text invisible by setting font color to white.
    # Underscores preserve character width (so PDF layout matches the tagged PDF),
    # but we don't want them visible in the final document.
    #
    # Handles mixed content like "Buyer Signature: ___________" by splitting
    # the <w:r> into two runs: one normal (label) and one white (underscores).
    def make_underscores_white(xml_content)
      begin
        doc = Nokogiri::XML(xml_content)
        namespaces = { 'w' => 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' }
        modified = false
        
        # Find all w:r (run) elements containing w:t with underscores
        doc.xpath('//w:r', namespaces).each do |run|
          text_node = run.at_xpath('w:t', namespaces)
          next unless text_node
          
          text = text_node.text.to_s
          next unless text.include?('___')  # At least 3 consecutive underscores
          
          # Get existing run properties XML to clone for new runs
          rpr_node = run.at_xpath('w:rPr', namespaces)
          rpr_xml = rpr_node ? rpr_node.to_xml : nil
          
          # Split text into segments: [normal_text, underscore_run, normal_text, ...]
          segments = text.split(/(_{3,})/)
          next if segments.size <= 1  # No split needed (shouldn't happen)
          
          # If the entire text is underscores, just add white color to this run
          if text.match?(/\A_+\z/)
            rpr = rpr_node || begin
              new_rpr = Nokogiri::XML::Node.new('w:rPr', doc)
              run.children.first ? run.children.first.add_previous_sibling(new_rpr) : run.add_child(new_rpr)
              new_rpr
            end
            color = rpr.at_xpath('w:color', namespaces)
            if color
              color['w:val'] = 'FFFFFF'
            else
              color = Nokogiri::XML::Node.new('w:color', doc)
              color['w:val'] = 'FFFFFF'
              rpr.add_child(color)
            end
            modified = true
            next
          end
          
          # Mixed content: split into multiple runs
          # Build new runs to insert after the current run, then remove the current run
          new_runs = []
          segments.each do |seg|
            next if seg.empty?
            
            new_run = Nokogiri::XML::Node.new('w:r', doc)
            
            # Clone run properties
            if rpr_xml
              new_rpr = Nokogiri.XML(rpr_xml).root
              # Import the node into this document
              new_rpr = doc.import(new_rpr)
              new_run.add_child(new_rpr)
              
              # If this is an underscore segment, add white color
              if seg.match?(/\A_+\z/)
                color = new_rpr.at_xpath('w:color', namespaces)
                if color
                  color['w:val'] = 'FFFFFF'
                else
                  color = Nokogiri::XML::Node.new('w:color', doc)
                  color['w:val'] = 'FFFFFF'
                  new_rpr.add_child(color)
                end
              end
            elsif seg.match?(/\A_+\z/)
              # No existing rPr, create one with white color for underscore segments
              new_rpr = Nokogiri::XML::Node.new('w:rPr', doc)
              color = Nokogiri::XML::Node.new('w:color', doc)
              color['w:val'] = 'FFFFFF'
              new_rpr.add_child(color)
              new_run.add_child(new_rpr)
            end
            
            # Add the text element
            new_t = Nokogiri::XML::Node.new('w:t', doc)
            new_t['xml:space'] = 'preserve'
            new_t.content = seg
            new_run.add_child(new_t)
            
            new_runs << new_run
          end
          
          # Insert new runs after the current run, then remove the current run
          insert_point = run
          new_runs.each do |new_run|
            insert_point.add_next_sibling(new_run)
            insert_point = new_run
          end
          run.remove
          
          modified = true
        end
        
        if modified
          result = doc.to_xml
          # Preserve original XML declaration
          if xml_content.start_with?('<?xml') && !result.start_with?('<?xml')
            declaration = xml_content[/^<\?xml[^?]*\?>/]
            result = "#{declaration}\n#{result}" if declaration
          end
          Rails.logger.info("DOCX TAG REMOVAL: Made underscore placeholders white (invisible)")
          return result
        end
      rescue StandardError => e
        Rails.logger.warn("DOCX TAG REMOVAL: make_underscores_white failed: #{e.message}")
        Rails.logger.warn(e.backtrace.first(3).join("\n"))
      end
      
      xml_content
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
