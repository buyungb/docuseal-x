# frozen_string_literal: true

module Api
  class SendPhoneVerificationCodeController < ApiBaseController
    skip_before_action :authenticate_user!
    skip_authorization_check

    def create
      submitter = Submitter.find_by!(slug: params[:submitter_slug])
      phone = params[:phone].to_s.gsub(/[^\d+]/, '')

      return render json: { error: I18n.t('invalid_phone_number') }, status: :unprocessable_entity if phone.blank?

      # Rate limiting
      rate_key = "phone-verification-#{submitter.id}"
      if submitter.submission_events.where(event_type: 'send_2fa_phone').exists?(created_at: 30.seconds.ago..)
        return render json: { error: I18n.t('rate_limit_exceeded') }, status: :too_many_requests
      end

      # Check if webhook is configured
      webhook_config = EncryptedConfig.find_by(
        account: submitter.account,
        key: EncryptedConfig::PHONE_OTP_WEBHOOK_KEY
      )&.value

      unless webhook_config.present? && webhook_config['url'].present?
        return render json: { error: 'Phone verification not configured' }, status: :unprocessable_entity
      end

      # Generate OTP
      otp_value = [phone, submitter.slug].join(':')
      otp_code = PhoneVerificationCodes.generate(otp_value)

      # Send to webhook
      payload = {
        event_type: 'otp_verification',
        phone_number: phone,
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

      begin
        response = Faraday.post(webhook_config['url']) do |req|
          req.headers = headers
          req.body = payload.to_json
          req.options.timeout = 30
          req.options.open_timeout = 10
        end

        SubmissionEvent.create!(
          submitter:,
          event_type: 'send_2fa_phone',
          data: {
            phone:,
            webhook_status: response.status,
            webhook_success: response.success?
          }
        )

        if response.success?
          render json: { status: 'ok' }
        else
          render json: { error: 'Failed to send verification code' }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("Phone verification webhook failed: #{e.message}")
        render json: { error: 'Failed to send verification code' }, status: :unprocessable_entity
      end
    end
  end
end
