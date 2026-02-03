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
      documents_data.each do |doc_data|
        file_data = decode_file(doc_data[:file])
        next if file_data.blank?

        # Process DOCX variables if any
        if variables.present? && docx_file?(file_data, doc_data[:name])
          require_relative '../../../lib/templates/process_docx_variables'
          file_data = Templates::ProcessDocxVariables.call(file_data, variables)
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
        tempfile = Tempfile.new([doc[:name], File.extname(doc[:name]).presence || '.docx'])
        tempfile.binmode
        tempfile.write(doc[:data])
        tempfile.rewind

        uploaded_file = ActionDispatch::Http::UploadedFile.new(
          filename: doc[:name],
          type: doc[:content_type],
          tempfile: tempfile
        )

        Templates::CreateAttachments.call(template, { files: [uploaded_file] }, extract_fields: true)

        tempfile.close
        tempfile.unlink
      end

      # Set up submitters from params
      submitters_params = params[:submitters] || [{ role: 'First Party', email: params[:email] }]

      # Build template submitters structure
      template.submitters = submitters_params.map.with_index do |s, i|
        {
          'uuid' => SecureRandom.uuid,
          'name' => s[:role] || s[:name] || "Party #{i + 1}"
        }
      end

      template.save!

      # Create submissions
      submissions_attrs = [{
        submitters: submitters_params.map.with_index do |s, i|
          {
            uuid: template.submitters[i]['uuid'],
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
      Rails.logger.error("SubmissionsDocxController error: #{e.message}")
      Rails.logger.error(e.backtrace.first(10).join("\n"))

      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def normalize_documents(documents)
      Array.wrap(documents).map do |doc|
        if doc.is_a?(Hash)
          { file: doc[:file], name: doc[:name] || doc[:filename] }
        else
          { file: doc, name: 'document.docx' }
        end
      end.compact
    end

    def decode_file(file_data)
      return nil if file_data.blank?

      if file_data.is_a?(String)
        # Try strict base64 decode first, fall back to lenient decode
        begin
          decoded = Base64.strict_decode64(file_data)
        rescue ArgumentError
          # Try lenient decode if strict fails (handles newlines in base64)
          decoded = Base64.decode64(file_data)
        end

        # Validate DOCX magic bytes (PK header for ZIP)
        unless decoded[0..3] == "PK\x03\x04"
          Rails.logger.error("Invalid DOCX file: missing PK header. First 4 bytes: #{decoded[0..3].bytes.inspect}")
          return nil
        end

        decoded
      elsif file_data.respond_to?(:read)
        file_data.read
      else
        file_data.to_s
      end
    rescue StandardError => e
      Rails.logger.error("decode_file error: #{e.message}")
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
  end
end
