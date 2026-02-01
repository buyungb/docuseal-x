# frozen_string_literal: true

class SendSubmitterInvitationWebhookJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])
    account = submitter.account

    return if submitter.completed_at?
    return if submitter.submission.archived_at?
    return if submitter.template&.archived_at?
    return if submitter.phone.blank?

    webhook_config = EncryptedConfig.find_by(account:, key: EncryptedConfig::PHONE_OTP_WEBHOOK_KEY)&.value

    return unless webhook_config.present? && webhook_config['url'].present?

    sign_url = Rails.application.routes.url_helpers.submit_form_url(
      slug: submitter.slug,
      host: Docuseal.default_url_options[:host] || 'localhost:3000'
    )

    payload = {
      event_type: 'invitation',
      phone_number: submitter.phone,
      sign_url: sign_url,
      timestamp: Time.current.iso8601,
      submitter_id: submitter.id,
      submitter_email: submitter.email,
      submitter_name: submitter.name,
      submission_id: submitter.submission_id,
      template_name: submitter.submission.template&.name,
      template_id: submitter.submission.template_id,
      message: "You have been invited to sign: #{submitter.submission.template&.name}. Click here to sign: #{sign_url}"
    }

    headers = {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json'
    }

    if webhook_config['bearer_token'].present?
      headers['Authorization'] = "Bearer #{webhook_config['bearer_token']}"
    end

    response = Faraday.post(webhook_config['url']) do |req|
      req.headers = headers
      req.body = payload.to_json
      req.options.timeout = 30
      req.options.open_timeout = 10
    end

    SubmissionEvent.create!(
      submitter:,
      event_type: 'send_sms',
      data: {
        phone: submitter.phone,
        webhook_status: response.status,
        webhook_success: response.success?
      }
    )

    Rails.logger.info("Invitation webhook sent to #{submitter.phone}: #{response.status}")
  rescue StandardError => e
    Rails.logger.error("Invitation webhook failed: #{e.message}")
    raise e
  end
end
