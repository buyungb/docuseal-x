# frozen_string_literal: true

class SubmitFormConsentController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  def create
    submitter = Submitter.find_by!(slug: params[:submit_form_slug])

    submission = submitter.submission

    return head :no_content if submitter.completed_at? ||
                               submitter.declined_at? ||
                               submission.archived_at? ||
                               submission.expired? ||
                               submission.template&.archived_at? ||
                               submitter.account.archived_at?

    configs = Submitters::FormConfigs.call(submitter)

    return head :no_content unless configs[:consent_enabled] && configs[:consent_document_url].present?

    return head :ok if submitter.submission_events.exists?(event_type: 'accept_consent')

    accepted_at = Time.current

    document_url  = configs[:consent_document_url].to_s
    document_text = (configs[:consent_document_text].presence ||
                     I18n.t('i_have_read_and_agree_to_the_terms_and_conditions')).to_s

    event_data = {
      document_url:,
      document_text:,
      accepted_at: accepted_at.iso8601
    }

    ApplicationRecord.transaction do
      submitter.preferences['consent_accepted_at'] = accepted_at.iso8601
      submitter.preferences['consent_document_url_snapshot'] = document_url
      submitter.preferences['consent_document_text_snapshot'] = document_text
      submitter.save!

      SubmissionEvents.create_with_tracking_data(submitter, 'accept_consent', request, event_data)
    end

    head :ok
  end
end
