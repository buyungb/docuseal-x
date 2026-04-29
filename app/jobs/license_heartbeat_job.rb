# frozen_string_literal: true

class LicenseHeartbeatJob < ApplicationJob
  queue_as :recurrent

  # Self-rescheduling job; we swallow errors so retry_on doesn't enqueue
  # duplicates (the ensure block reschedules unconditionally).
  def perform
    return if Docuseal.multitenant?
    return unless LicenseInfo.table_exists?

    info = LicenseInfo.current
    return unless info.persisted?
    return if info.token.blank? || info.machine_id.blank?

    begin
      result = Aplindo::LicenseClient.new.heartbeat(token: info.token, machine_id: info.machine_id)

      info.update!(
        last_heartbeat_at: Time.current,
        expires_at: result[:expires_at] || info.expires_at,
        status: result[:status].presence || info.status,
        last_heartbeat_error: nil
      )
    rescue Aplindo::LicenseClient::Error => e
      info.update(last_heartbeat_error: e.message)
      Rails.logger.warn("LicenseHeartbeatJob: #{e.message}")
    rescue StandardError => e
      Rails.logger.warn("LicenseHeartbeatJob unexpected error: #{e.class}: #{e.message}")
    end
  ensure
    self.class.enqueue_next
  end

  def self.enqueue_next
    set(wait: Docuseal::APLINDO_HEARTBEAT_INTERVAL.seconds).perform_later
  rescue StandardError => e
    Rails.logger.warn("LicenseHeartbeatJob reschedule failed: #{e.message}")
  end
end
