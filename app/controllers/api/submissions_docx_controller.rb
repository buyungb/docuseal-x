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
      # 1. PDF extractor service (PyMuPDF) finds {{name;type=X}} tags with exact positions
      # 2. Tags are already parsed with all attributes (name, type, role, etc.)
      # 3. Fallback: use DOCX-extracted metadata with calculated positions
      #
      # Note: Tags WITHOUT type ({{name}}) are replaced with content in DOCX processor
      # Only tags WITH type ({{name;type=X}}) become interactive form fields
      
      all_fields = []
      first_doc = template.documents.first
      
      if first_doc
        begin
          document_data = first_doc.download
          pdf_extractor_url = ENV.fetch('PDF_EXTRACTOR_URL', nil)
          
          if pdf_extractor_url.present?
            Rails.logger.info("DOCX Submission: Using PDF Extractor for field positions...")
            extracted_fields = extract_tags_via_service(document_data, pdf_extractor_url)
            
            if extracted_fields.any?
              Rails.logger.info("DOCX Submission: Found #{extracted_fields.size} form field tags")
              
              extracted_fields.each do |field|
                all_fields << {
                  uuid: SecureRandom.uuid,
                  name: field[:name],
                  type: field[:type] || 'text',
                  role: field[:role],
                  required: field[:required] != false,
                  readonly: field[:readonly] || false,
                  default_value: field[:default],
                  options: field[:options],
                  condition: field[:condition],
                  format: field[:format],
                  areas: [{
                    page: field[:page] || 0,
                    x: field[:x],
                    y: field[:y],
                    w: [field[:w], 0.15].max,
                    h: [field[:h], 0.03].max,
                    attachment_uuid: first_doc.uuid
                  }]
                }
                Rails.logger.info("  - Field: #{field[:name]} (#{field[:type]}) role=#{field[:role]} pos=(#{field[:x]&.round(3)}, #{field[:y]&.round(3)})")
              end
            end
          else
            Rails.logger.info("DOCX Submission: PDF_EXTRACTOR_URL not set, using DOCX metadata with fallback positions")
          end
          
          # Fallback: Use DOCX-extracted metadata with calculated positions
          if all_fields.empty? && docx_extracted_fields.any?
            Rails.logger.info("DOCX Submission: Using #{docx_extracted_fields.size} fields from DOCX with calculated positions")
            
            docx_by_role = docx_extracted_fields.group_by { |f| f[:role]&.downcase || 'default' }
            
            docx_by_role.each do |role, role_fields|
              column = determine_column_for_role(role)
              type_order = %w[signature initials image text number date datenow checkbox select]
              sorted_fields = role_fields.sort_by { |f| type_order.index(f[:type]) || 99 }
              
              sorted_fields.each do |field|
                add_fallback_field(all_fields, field, role, column, first_doc)
              end
            end
          end
        rescue StandardError => e
          Rails.logger.warn("DOCX Submission: Field detection failed: #{e.message}")
          Rails.logger.warn(e.backtrace.first(3).join("\n"))
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
    
    # Add a field with fallback positioning based on role and column
    def add_fallback_field(all_fields, docx_field, role, column, first_doc)
      role_lower = role.to_s.downcase
      field_type = docx_field[:type]
      
      # Count existing fields for this role to determine Y position
      role_field_count = all_fields.count { |f| (f[:role] || '').to_s.downcase == role_lower }
      
      # Base positions - configurable starting Y based on document layout
      # You can override these with API params in the future
      base_x = column == :left ? 0.08 : 0.52
      signature_start_y = 0.82  # Where signature section typically starts
      
      # Stack fields vertically
      field_y = signature_start_y + (role_field_count * 0.035)
      
      # Size based on field type
      is_signature = field_type.in?(%w[signature initials])
      field_w = is_signature ? 0.38 : 0.35
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
      Rails.logger.info("  - Fallback: #{docx_field[:name]} (#{field_type}) role=#{role} column=#{column} -> pos=(#{base_x}, #{field_y.round(3)})")
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
