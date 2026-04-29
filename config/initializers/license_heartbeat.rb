# frozen_string_literal: true

# Re-enqueue the recurring license heartbeat job once per process boot.
# A daily Rails.cache flag prevents an enqueue storm when many workers boot.
Rails.application.config.after_initialize do
  next if Docuseal.multitenant?
  next if defined?(Rails::Console)
  next if Rails.env.test?
  next unless defined?(Sidekiq) && (defined?(Puma) || defined?(Sidekiq::CLI))

  begin
    next unless ActiveRecord::Base.connection.data_source_exists?('license_infos')
    next unless LicenseInfo.first&.active?

    flag_key = "license_heartbeat_boot:#{Date.current}"
    next if Rails.cache.exist?(flag_key)

    Rails.cache.write(flag_key, true, expires_in: 1.day)

    LicenseHeartbeatJob.set(wait: 30.seconds).perform_later
  rescue StandardError => e
    Rails.logger.warn("license_heartbeat initializer skipped: #{e.message}")
  end
end
