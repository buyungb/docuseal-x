# frozen_string_literal: true

class PhoneOtpSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, except: :index

  def index; end

  def create
    @encrypted_config.value = phone_otp_params

    if @encrypted_config.value['url'].blank?
      @encrypted_config.destroy! if @encrypted_config.persisted?
    else
      @encrypted_config.save!
    end

    # Also update the account config to enable/disable phone OTP
    account_config = current_account.account_configs.find_or_initialize_by(
      key: AccountConfig::PHONE_OTP_WEBHOOK_ENABLED_KEY
    )
    account_config.value = @encrypted_config.value['url'].present?
    account_config.save!

    redirect_to settings_phone_otp_index_path, notice: I18n.t('settings_have_been_saved')
  end

  private

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: EncryptedConfig::PHONE_OTP_WEBHOOK_KEY)
  end

  def phone_otp_params
    params.require(:encrypted_config).permit(:url, :bearer_token).to_h
  end
end
