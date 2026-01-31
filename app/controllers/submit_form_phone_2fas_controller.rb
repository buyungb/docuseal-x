# frozen_string_literal: true

class SubmitFormPhone2fasController < ApplicationController
  around_action :with_browser_locale

  skip_before_action :authenticate_user!
  skip_authorization_check

  before_action :load_submitter

  COOKIES_TTL = 12.hours
  COOKIES_DEFAULTS = { httponly: true, secure: Rails.env.production? }.freeze

  def create
    RateLimit.call("verify-phone-2fa-code-#{@submitter.id}", limit: 3, ttl: 60.seconds, enabled: true)

    value = [@submitter.phone.to_s.gsub(/\D/, ''), @submitter.slug].join(':')

    if PhoneVerificationCodes.verify(params[:one_time_code].to_s.gsub(/\D/, ''), value)
      SubmissionEvents.create_with_tracking_data(@submitter, 'phone_verified', request, { phone: @submitter.phone })

      cookies.encrypted[:phone_2fa_slug] =
        { value: @submitter.slug, expires: COOKIES_TTL.from_now, **COOKIES_DEFAULTS }

      redirect_to submit_form_path(@submitter.slug)
    else
      redirect_to submit_form_path(@submitter.slug, status: :phone_error), alert: I18n.t(:invalid_code)
    end
  rescue RateLimit::LimitApproached
    redirect_to submit_form_path(@submitter.slug, status: :phone_error), alert: I18n.t(:too_many_attempts)
  end

  def update
    if @submitter.submission_events.where(event_type: 'send_2fa_phone').exists?(created_at: 30.seconds.ago..)
      return redirect_to submit_form_path(@submitter.slug, status: :phone_error), alert: I18n.t(:rate_limit_exceeded)
    end

    RateLimit.call("send-phone-code-#{@submitter.id}", limit: 3, ttl: 60.seconds, enabled: true)

    SendPhoneOtpWebhookJob.perform_async('submitter_id' => @submitter.id)

    redir_params = params[:resend] ? { alert: I18n.t(:code_has_been_resent) } : {}

    redirect_to submit_form_path(@submitter.slug, status: :phone_sent), **redir_params
  rescue RateLimit::LimitApproached
    redirect_to submit_form_path(@submitter.slug, status: :phone_error), alert: I18n.t(:too_many_attempts)
  end

  private

  def load_submitter
    @submitter = Submitter.find_by!(slug: params[:submitter_slug])
  end
end
