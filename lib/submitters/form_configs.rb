# frozen_string_literal: true

module Submitters
  module FormConfigs
    DEFAULT_KEYS = [AccountConfig::FORM_COMPLETED_BUTTON_KEY,
                    AccountConfig::FORM_COMPLETED_MESSAGE_KEY,
                    AccountConfig::FORM_WITH_CONFETTI_KEY,
                    AccountConfig::FORM_PREFILL_SIGNATURE_KEY,
                    AccountConfig::WITH_SIGNATURE_ID,
                    AccountConfig::ALLOW_TO_DECLINE_KEY,
                    AccountConfig::ENFORCE_SIGNING_ORDER_KEY,
                    AccountConfig::REQUIRE_SIGNING_REASON_KEY,
                    AccountConfig::REUSE_SIGNATURE_KEY,
                    AccountConfig::WITH_FIELD_LABELS_KEY,
                    AccountConfig::ALLOW_TO_PARTIAL_DOWNLOAD_KEY,
                    AccountConfig::ALLOW_TYPED_SIGNATURE,
                    AccountConfig::WITH_SUBMITTER_TIMEZONE_KEY,
                    AccountConfig::WITH_SIGNATURE_ID_REASON_KEY,
                    AccountConfig::CONSENT_DOCUMENT_URL_KEY,
                    AccountConfig::CONSENT_DOCUMENT_TEXT_KEY,
                    *(Docuseal.multitenant? ? [] : [AccountConfig::POLICY_LINKS_KEY])].freeze

    module_function

    def call(submitter, keys = [])
      configs = submitter.submission.account.account_configs.where(key: DEFAULT_KEYS + keys)

      completed_button = find_safe_value(configs, AccountConfig::FORM_COMPLETED_BUTTON_KEY) || {}
      completed_message = find_safe_value(configs, AccountConfig::FORM_COMPLETED_MESSAGE_KEY) || {}
      with_typed_signature = find_safe_value(configs, AccountConfig::ALLOW_TYPED_SIGNATURE) != false
      with_confetti = find_safe_value(configs, AccountConfig::FORM_WITH_CONFETTI_KEY) != false
      prefill_signature = find_safe_value(configs, AccountConfig::FORM_PREFILL_SIGNATURE_KEY) != false
      reuse_signature = find_safe_value(configs, AccountConfig::REUSE_SIGNATURE_KEY) != false
      with_decline = find_safe_value(configs, AccountConfig::ALLOW_TO_DECLINE_KEY) != false
      with_partial_download = find_safe_value(configs, AccountConfig::ALLOW_TO_PARTIAL_DOWNLOAD_KEY) != false
      with_signature_id = find_safe_value(configs, AccountConfig::WITH_SIGNATURE_ID) == true
      require_signing_reason = find_safe_value(configs, AccountConfig::REQUIRE_SIGNING_REASON_KEY) == true
      enforce_signing_order = find_safe_value(configs, AccountConfig::ENFORCE_SIGNING_ORDER_KEY) == true
      with_submitter_timezone = find_safe_value(configs, AccountConfig::WITH_SUBMITTER_TIMEZONE_KEY) == true
      with_signature_id_reason = find_safe_value(configs, AccountConfig::WITH_SIGNATURE_ID_REASON_KEY) != false
      with_field_labels = find_safe_value(configs, AccountConfig::WITH_FIELD_LABELS_KEY) != false
      policy_links = find_safe_value(configs, AccountConfig::POLICY_LINKS_KEY)

      # Consent: Check submitter > template per-role > submission > template > account defaults
      submitter_prefs = submitter.preferences || {}
      submission_prefs = submitter.submission.preferences || {}
      template_prefs = submitter.submission.template&.preferences || {}

      # Per-role consent from template preferences (set via UI)
      role_consent = (template_prefs['consent_roles'] || {})[submitter.uuid] || {}

      # Consent enabled: submitter API > template per-role > submission API > template global
      consent_enabled = if submitter_prefs.key?('consent_enabled')
                          submitter_prefs['consent_enabled'] == true
                        elsif role_consent.key?('enabled')
                          role_consent['enabled'] == true || role_consent['enabled'] == 'true'
                        elsif submission_prefs.key?('consent_enabled')
                          submission_prefs['consent_enabled'] == true
                        else
                          template_prefs['consent_enabled'] == true
                        end

      # Consent URL: submitter API > template per-role > submission API > template global > account
      consent_document_url = if consent_enabled
                               submitter_prefs['consent_document_url'].presence ||
                                 role_consent['url'].presence ||
                                 submission_prefs['consent_document_url'].presence ||
                                 template_prefs['consent_document_url'].presence ||
                                 find_safe_value(configs, AccountConfig::CONSENT_DOCUMENT_URL_KEY)
                             end

      # Consent text: submitter API > template per-role > submission API > template global > account
      consent_document_text = if consent_enabled
                                submitter_prefs['consent_document_text'].presence ||
                                  role_consent['text'].presence ||
                                  submission_prefs['consent_document_text'].presence ||
                                  template_prefs['consent_document_text'].presence ||
                                  find_safe_value(configs, AccountConfig::CONSENT_DOCUMENT_TEXT_KEY)
                              end

      attrs = { completed_button:, with_typed_signature:, with_confetti:,
                reuse_signature:, with_decline:, with_partial_download:,
                policy_links:, enforce_signing_order:, completed_message:,
                require_signing_reason:, prefill_signature:, with_submitter_timezone:,
                with_signature_id_reason:, with_signature_id:, with_field_labels:,
                consent_enabled:, consent_document_url:, consent_document_text: }

      keys.each do |key|
        attrs[key.to_sym] = configs.find { |e| e.key == key.to_s }&.value
      end

      attrs
    end

    def find_safe_value(configs, key)
      configs.find { |e| e.key == key }&.value
    end
  end
end
