# frozen_string_literal: true

class ConsentSettingsController < ApplicationController
  authorize_resource :account_config, only: :index
  authorize_resource :account_config, parent: false, except: :index

  def index
    @consent_url_config = current_account.account_configs.find_or_initialize_by(
      key: AccountConfig::CONSENT_DOCUMENT_URL_KEY
    )
    @consent_text_config = current_account.account_configs.find_or_initialize_by(
      key: AccountConfig::CONSENT_DOCUMENT_TEXT_KEY
    )
  end

  def create
    consent_url_config = current_account.account_configs.find_or_initialize_by(
      key: AccountConfig::CONSENT_DOCUMENT_URL_KEY
    )
    consent_text_config = current_account.account_configs.find_or_initialize_by(
      key: AccountConfig::CONSENT_DOCUMENT_TEXT_KEY
    )

    consent_url_config.value = params[:consent_document_url].presence
    consent_text_config.value = params[:consent_document_text].presence || 'I have read and agree to the terms and conditions'

    if consent_url_config.value.present?
      consent_url_config.save!
      consent_text_config.save!
    else
      consent_url_config.destroy! if consent_url_config.persisted?
      consent_text_config.destroy! if consent_text_config.persisted?
    end

    redirect_to settings_consent_index_path, notice: I18n.t('settings_have_been_saved')
  end
end
