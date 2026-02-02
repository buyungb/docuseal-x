# frozen_string_literal: true

module Api
  class SubmissionsPdfController < ApiBaseController
    before_action do
      authorize!(:create, Template)
      authorize!(:create, Submission)
    end

    # POST /api/submissions/pdf
    # Create a one-off submission from PDF with embedded text field tags
    def create
      documents_data = normalize_documents(params[:documents] || [{ file: params[:file], name: params[:name] }])

      return render json: { error: 'No documents provided' }, status: :unprocessable_entity if documents_data.blank?

      # Create a temporary template
      template = current_account.templates.new(
        author: current_user,
        name: params[:name].presence || 'PDF Submission',
        folder: current_account.default_template_folder
      )

      template.save!

      # Process each PDF document
      documents_data.each do |doc_data|
        file_data = decode_file(doc_data[:file])
        next if file_data.blank?

        tempfile = Tempfile.new([doc_data[:name] || 'document', '.pdf'])
        tempfile.binmode
        tempfile.write(file_data)
        tempfile.rewind

        uploaded_file = ActionDispatch::Http::UploadedFile.new(
          filename: "#{doc_data[:name] || 'document'}.pdf",
          type: 'application/pdf',
          tempfile: tempfile
        )

        # Create attachment and process
        Templates::CreateAttachments.call(template, { files: [uploaded_file] }, extract_fields: true)

        # Parse text tags from PDF
        parse_and_add_text_tag_fields(template, file_data)

        tempfile.close
        tempfile.unlink
      end

      # Set up submitters from params
      submitters_params = params[:submitters] || [{ role: 'First Party', email: params[:email] }]

      # Build unique roles from text tag fields or use provided submitters
      roles = extract_roles_from_fields(template.fields) | submitters_params.map { |s| s[:role] || s[:name] }
      roles = ['First Party'] if roles.blank?

      template.submitters = roles.map do |role|
        {
          'uuid' => SecureRandom.uuid,
          'name' => role
        }
      end

      # Assign fields to submitters based on role
      assign_fields_to_submitters(template)

      template.save!

      # Create submissions
      submissions_attrs = [{
        submitters: submitters_params.map do |s|
          submitter_uuid = template.submitters.find { |sub| sub['name'] == (s[:role] || s[:name]) }&.dig('uuid')
          submitter_uuid ||= template.submitters.first['uuid']

          {
            uuid: submitter_uuid,
            email: s[:email],
            phone: s[:phone],
            name: s[:name],
            external_id: s[:external_id],
            metadata: s[:metadata] || {}
          }.compact
        end
      }]

      submissions = Submissions.create_from_submitters(
        template: template,
        user: current_user,
        source: :api,
        submitters_order: params[:order] || 'preserved',
        submissions_attrs: submissions_attrs,
        params: params
      )

      # Send signature requests if configured
      params[:send_email] = true unless params.key?(:send_email)
      Submissions.send_signature_requests(submissions) unless params[:send_email].in?(['false', false])

      render json: build_response(submissions)
    rescue StandardError => e
      Rails.logger.error("SubmissionsPdfController error: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))

      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def normalize_documents(documents)
      Array.wrap(documents).map do |doc|
        if doc.is_a?(Hash)
          { file: doc[:file], name: doc[:name] || doc[:filename] || 'document' }
        else
          { file: doc, name: 'document' }
        end
      end.compact
    end

    def decode_file(file_data)
      return nil if file_data.blank?

      if file_data.is_a?(String)
        Base64.decode64(file_data)
      elsif file_data.respond_to?(:read)
        file_data.read
      else
        file_data.to_s
      end
    rescue StandardError
      nil
    end

    def parse_and_add_text_tag_fields(template, pdf_data)
      require_relative '../../../lib/templates/parse_pdf_text_tags'

      return if template.documents.blank?

      attachment = template.documents.last

      begin
        pdf = HexaPDF::Document.new(io: StringIO.new(pdf_data))

        # Check if PDF contains text tags
        return unless Templates::ParsePdfTextTags.contains_tags?(pdf)

        # Parse text tags and get field definitions
        text_tag_fields = Templates::ParsePdfTextTags.call(pdf, attachment)

        return if text_tag_fields.blank?

        # Merge with existing fields (from AcroForm)
        existing_fields = template.fields || []
        template.fields = existing_fields + text_tag_fields
      rescue StandardError => e
        Rails.logger.warn("Error parsing PDF text tags: #{e.message}")
      end
    end

    def extract_roles_from_fields(fields)
      return [] if fields.blank?

      fields.filter_map { |f| f['role'] }.uniq
    end

    def assign_fields_to_submitters(template)
      return if template.fields.blank? || template.submitters.blank?

      default_submitter_uuid = template.submitters.first['uuid']

      template.fields.each do |field|
        if field['role'].present?
          # Find matching submitter by role name
          submitter = template.submitters.find { |s| s['name'] == field['role'] }
          field['submitter_uuid'] = submitter&.dig('uuid') || default_submitter_uuid
        else
          field['submitter_uuid'] ||= default_submitter_uuid
        end

        # Remove temporary role field
        field.delete('role')
      end
    end

    def build_response(submissions)
      submissions.flat_map do |submission|
        submission.submitters.map do |s|
          Submitters::SerializeForApi.call(s, with_documents: false, with_urls: true, params: params)
        end
      end
    end
  end
end
