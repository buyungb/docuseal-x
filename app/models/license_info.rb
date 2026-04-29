# frozen_string_literal: true

# == Schema Information
#
# Table name: license_infos
#
#  id                   :bigint           not null, primary key
#  activated_at         :datetime
#  customer_email       :string
#  expires_at           :datetime
#  last_heartbeat_at    :datetime
#  last_heartbeat_error :text
#  machine_id           :string
#  product              :string
#  status               :string           default("pending"), not null
#  token                :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  license_id           :string
#
class LicenseInfo < ApplicationRecord
  encrypts :token

  def self.current
    first_or_initialize
  end

  def active?
    status == 'active' && (expires_at.nil? || expires_at > Time.current)
  end

  def ensure_machine_id!
    return machine_id if machine_id.present?

    self.machine_id = SecureRandom.uuid
    save! if persisted?
    machine_id
  end
end
