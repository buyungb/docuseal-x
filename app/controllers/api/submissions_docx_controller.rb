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
      processed_documents.each do |doc|
        # Convert DOCX to PDF if needed
        if doc[:content_type].include?('wordprocessingml') || doc[:name].to_s.end_with?('.docx')
          pdf_data = convert_docx_to_pdf(doc[:data], doc[:name])
          
          if pdf_data.nil?
            return render json: { 
              error: 'DOCX to PDF conversion not available. Please upload a PDF file instead, or configure Gotenberg service.',
              hint: 'Set GOTENBERG_URL environment variable to enable DOCX conversion (e.g., http://gotenberg:3000)'
            }, status: :unprocessable_entity
          end
          
          doc[:data] = pdf_data
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

      # Field detection strategy:
      # 1. Tags WITH type {{name;type=X}} are KEPT in DOCX (not replaced)
      # 2. After PDF conversion, use Pdfium to find {{...}} tag positions
      # 3. Merge DOCX field metadata with PDF tag positions
      #
      # Tags WITHOUT type: {{name}} → replaced with content from variables
      # Tags WITH type: {{name;type=X}} → kept visible for detection
      
      all_fields = []
      first_doc = template.documents.first
      
      if first_doc && docx_extracted_fields.any?
        begin
          document_data = first_doc.download
          
          # Use Pdfium to find {{...}} tags in PDF (more reliable than HexaPDF)
          Rails.logger.info("DOCX Submission: Using Pdfium to find {{...}} tag positions...")
          
          tag_positions = find_tags_with_pdfium(document_data, docx_extracted_fields)
          
          Rails.logger.info("DOCX Submission: Found #{tag_positions.size} tag positions")
          
          if tag_positions.any?
            # Match DOCX fields with detected positions by name
            docx_extracted_fields.each do |docx_field|
              field_name = docx_field[:name]
              position = tag_positions[field_name]
              
              if position
                merged = docx_field.merge(
                  uuid: SecureRandom.uuid,
                  areas: [{
                    page: position[:page],
                    x: position[:x],
                    y: position[:y],
                    w: default_width_for_type(docx_field[:type]),
                    h: default_height_for_type(docx_field[:type]),
                    attachment_uuid: first_doc.uuid
                  }]
                )
                all_fields << merged
                
                Rails.logger.info("  #{field_name} (#{docx_field[:type]}) -> pos=(#{position[:x].round(3)}, #{position[:y].round(3)})")
              else
                # No matching tag found - use fallback
                role = docx_field[:role]&.downcase || 'default'
                column_idx = determine_column_for_role(role) == :left ? 0 : 1
                add_fallback_field(all_fields, docx_field, role, column_idx, first_doc, 2)
                Rails.logger.warn("  #{field_name} -> FALLBACK (tag not found in PDF)")
              end
            end
          else
            Rails.logger.warn("DOCX Submission: No tags found in PDF, using fallback")
            use_fallback_positions(all_fields, docx_extracted_fields, first_doc)
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
                page: 0,
                x: base_x,
                y: 0.83,
                w: 0.38,
                h: 0.05,
                attachment_uuid: first_doc.uuid
              }]
            }
            Rails.logger.info("DOCX Submission: Created default signature field for #{role_name} at x=#{base_x}")
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
      submissions_attrs = [{
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
          
          # Convert to HashWithIndifferentAccess so both symbol and string keys work
          submitter_data = submitter_data.with_indifferent_access
          
          Rails.logger.info("DOCX Submission: Submitter #{i}: #{submitter_data.inspect}")
          
          submitter_data
        end
      }]

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
    
    # Find {{...}} tags in PDF using Pdfium and return positions
    # Returns: { "FieldName" => {page:, x:, y:}, ... }
    def find_tags_with_pdfium(pdf_data, docx_fields)
      positions = {}
      
      begin
        pdf_doc = Pdfium::Document.open_bytes(pdf_data)
        
        (0...pdf_doc.page_count).each do |page_idx|
          page = pdf_doc.get_page(page_idx)
          text_nodes = page.text_nodes
          
          # Build full page text with position mapping
          # text_nodes are already sorted by Y then X
          text_with_positions = []
          text_nodes.each do |node|
            content = node.content.to_s
            next if content.empty?
            
            text_with_positions << {
              text: content,
              x: node.x,       # Already normalized 0-1
              y: node.y,       # Already normalized 0-1
              w: node.w,
              h: node.h
            }
          end
          
          # Build full text for searching
          full_text = text_with_positions.map { |t| t[:text] }.join
          
          Rails.logger.info("DOCX Submission: Page #{page_idx} text length: #{full_text.length}")
          Rails.logger.debug("DOCX Submission: Page #{page_idx} text sample: #{full_text[0..500]}...")
          
          # Find each DOCX field's tag in the text
          docx_fields.each do |field|
            field_name = field[:name]
            next if positions[field_name]  # Already found
            
            # Search for the tag pattern containing this field name
            # Match: {{FieldName;...}} or {{FieldName}}
            field_pattern = /\{\{#{Regexp.escape(field_name)}[^}]*\}\}/
            
            match = full_text.match(field_pattern)
            next unless match
            
            # Find position of the match
            match_start = match.begin(0)
            
            # Find which text node contains this position
            char_count = 0
            text_with_positions.each do |node_info|
              node_end = char_count + node_info[:text].length
              
              if match_start >= char_count && match_start < node_end
                # Found the node containing the tag
                positions[field_name] = {
                  page: page_idx,
                  x: node_info[:x],
                  y: node_info[:y]
                }
                
                Rails.logger.info("  Found '#{field_name}' at page=#{page_idx} pos=(#{node_info[:x].round(3)}, #{node_info[:y].round(3)})")
                break
              end
              
              char_count = node_end
            end
          end
          
          page.close
        end
        
        pdf_doc.close
        
      rescue => e
        Rails.logger.error("find_tags_with_pdfium error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
      end
      
      positions
    end
    
    # Use fallback positions when PDF tag detection fails
    def use_fallback_positions(all_fields, docx_fields, first_doc)
      docx_by_role = docx_fields.group_by { |f| f[:role]&.downcase || 'default' }
      num_columns = [docx_by_role.size, 2].max
      
      docx_by_role.each_with_index do |(role, role_fields), role_idx|
        column_idx = role_idx % num_columns
        
        role_fields.each do |field|
          add_fallback_field(all_fields, field, role, column_idx, first_doc, num_columns)
        end
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
    def add_fallback_field(all_fields, docx_field, role, column_idx, first_doc, total_columns = 2)
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
          page: 0,
          x: base_x,
          y: [field_y, 0.95].min,  # Don't go past page bottom
          w: field_w,
          h: field_h,
          attachment_uuid: first_doc&.uuid
        }],
        uuid: SecureRandom.uuid
      )
      
      all_fields << fallback_field
      Rails.logger.info("  - Fallback: #{docx_field[:name]} (#{field_type}) role=#{role} col=#{column_idx} -> pos=(#{base_x.round(3)}, #{field_y.round(3)})")
    end
    
    # Extract tag positions from PDF using the PyMuPDF microservice
    def extract_tags_via_service(pdf_data, service_url)
      require 'net/http'
      require 'uri'
      require 'json'
      
      uri = URI.parse("#{service_url}/extract-tags")
      
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request.body = {
        pdf_base64: Base64.strict_encode64(pdf_data),
        normalize_positions: true
      }.to_json
      
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 30
      http.open_timeout = 10
      
      response = http.request(request)
      
      if response.code == '200'
        result = JSON.parse(response.body)
        
        if result['success'] && result['tags'].present?
          # Convert to our internal format
          result['tags'].map do |tag|
            {
              name: tag['name'],
              type: tag['type'],
              role: tag['role'],
              required: tag['required'],
              tag_content: tag['tag_content'],
              page: tag['page'],
              x: tag['x'],
              y: tag['y'],
              w: tag['w'],
              h: tag['h'],
              areas: [{
                page: tag['page'] || 0,
                x: tag['x'],
                y: tag['y'],
                w: tag['w'],
                h: tag['h'],
                attachment_uuid: nil  # Will be set later
              }]
            }.with_indifferent_access
          end
        else
          Rails.logger.warn("PDF Extractor returned no tags: #{result['message']}")
          []
        end
      else
        Rails.logger.error("PDF Extractor error: #{response.code} - #{response.body}")
        []
      end
    rescue StandardError => e
      Rails.logger.error("PDF Extractor service error: #{e.class} - #{e.message}")
      []
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

      # Create temp file for Gotenberg
      tempfile = Tempfile.new([filename.to_s.sub(/\.docx$/i, ''), '.docx'])
      tempfile.binmode
      tempfile.write(docx_data)
      tempfile.rewind

      begin
        require 'net/http'
        require 'uri'

        uri = URI.parse("#{gotenberg_url}/forms/libreoffice/convert")
        
        boundary = "----RubyMultipartPost#{rand(1000000)}"
        
        body = []
        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"files\"; filename=\"#{filename}\"\r\n"
        body << "Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n"
        body << docx_data
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
      ensure
        tempfile.close
        tempfile.unlink
      end
    end
  end
end
