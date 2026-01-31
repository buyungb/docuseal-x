# frozen_string_literal: true

class SendPhoneOtpWebhookJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])
    account = submitter.account

    webhook_config = EncryptedConfig.find_by(account:, key: EncryptedConfig::PHONE_OTP_WEBHOOK_KEY)&.value

    return unless webhook_config.present? && webhook_config['url'].present?

    phone = submitter.phone.to_s.gsub(/\D/, '')
    otp_value = [phone, submitter.slug].join(':')
    otp_code = PhoneVerificationCodes.generate(otp_value)

    payload = {
      phone_number: submitter.phone,
      otp: otp_code,
      timestamp: Time.current.iso8601,
      submitter_id: submitter.id,
      submitter_email: submitter.email,
      submitter_name: submitter.name,
      submission_id: submitter.submission_id,
      template_name: submitter.submission.template&.name
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
      submitter_id: submitter.id,
      event_type: 'send_2fa_phone',
      data: {
        phone: submitter.phone,
        webhook_status: response.status,
        webhook_success: response.success?
      }
    )

    raise "Webhook failed with status #{response.status}" unless response.success?
  rescue StandardError => e
    Rails.logger.error("Phone OTP webhook failed: #{e.message}")
    raise e
  end
end
