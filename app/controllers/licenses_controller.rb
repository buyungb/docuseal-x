# frozen_string_literal: true

class LicensesController < ApplicationController
  skip_before_action :maybe_redirect_to_license
  skip_authorization_check

  before_action :ensure_not_multitenant!
  before_action :load_license_info

  def show; end

  def checkout
    customer_email = checkout_params[:customer_email].presence || current_user.email
    seats = checkout_params[:seats].to_i
    seats = 1 if seats < 1

    unit_price = BigDecimal(Docuseal::APLINDO_DEFAULT_AMOUNT_IDR.to_s)
    total_amount = unit_price * seats

    response = client.create_checkout_session(
      customer_email: customer_email,
      seats: seats,
      amount_idr: total_amount,
      product_slug: Docuseal::APLINDO_PRODUCT_SLUG
    )

    @license_info.customer_email = customer_email
    @license_info.save! if @license_info.changed?

    payment_url = response[:payment_url].to_s
    checkout_id = response[:checkout_id].to_s

    if payment_url.blank?
      respond_to do |format|
        format.json { render json: { error: I18n.t('something_went_wrong') }, status: :unprocessable_content }
        format.html { redirect_to license_path, alert: I18n.t('something_went_wrong') }
      end
      return
    end

    respond_to do |format|
      format.json { render json: { payment_url: payment_url, checkout_id: checkout_id } }
      format.html { redirect_to payment_url, allow_other_host: true }
    end
  rescue Aplindo::LicenseClient::Error => e
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :bad_gateway }
      format.html { redirect_to license_path, alert: e.message }
    end
  end

  def activate
    raw_key = activate_params[:key].to_s
    normalized_key = normalize_key(raw_key)

    if normalized_key.blank?
      return redirect_to license_path, alert: I18n.t('please_provide_a_valid_license_key',
                                                     default: 'Please provide a valid license key.')
    end

    @license_info.save! unless @license_info.persisted?
    @license_info.ensure_machine_id!

    result = client.activate(
      key: normalized_key,
      machine_id: @license_info.machine_id
    )

    @license_info.update!(
      token: result[:token],
      license_id: result[:license_id],
      product: result[:product] || Docuseal::APLINDO_PRODUCT_SLUG,
      expires_at: result[:expires_at],
      activated_at: Time.current,
      status: 'active',
      last_heartbeat_error: nil
    )

    LicenseHeartbeatJob.set(wait: Docuseal::APLINDO_HEARTBEAT_INTERVAL.seconds).perform_later

    redirect_to root_path, notice: I18n.t('license_activated', default: 'License activated.')
  rescue Aplindo::LicenseClient::Error => e
    redirect_to license_path, alert: e.message
  end

  private

  def ensure_not_multitenant!
    redirect_to root_path if Docuseal.multitenant?
  end

  # The hosted checkout is rendered inside a SweetAlert2 modal iframe on this
  # page, so allow http/https/data frame sources here only. SweetAlert2 itself
  # is served from /vendor (same origin), so script-src is not loosened.
  # `http:` is included so local-dev license servers (e.g. http://localhost:8080)
  # can be framed.
  def set_csp
    super
    policy = request.content_security_policy
    return unless policy

    policy.frame_src(*Array(policy.frame_src), :http, :https, :data)
  end

  def load_license_info
    @license_info = LicenseInfo.current
  end

  def client
    @client ||= Aplindo::LicenseClient.new
  end

  def checkout_params
    return ActionController::Parameters.new unless params[:license]

    params.require(:license).permit(:customer_email, :seats)
  end

  def activate_params
    return ActionController::Parameters.new unless params[:license]

    params.require(:license).permit(:key)
  end

  def normalize_key(raw)
    cleaned = raw.to_s.upcase.gsub(/[^A-Z0-9]/, '')
    return '' if cleaned.blank?

    cleaned.scan(/.{1,4}/).join('-')
  end
end
