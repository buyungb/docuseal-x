# frozen_string_literal: true

class CreateLicenseInfos < ActiveRecord::Migration[8.0]
  def change
    create_table :license_infos do |t|
      t.string :product
      t.string :license_id
      t.text :token
      t.string :machine_id
      t.string :customer_email
      t.string :status, null: false, default: 'pending'
      t.datetime :expires_at
      t.datetime :activated_at
      t.datetime :last_heartbeat_at
      t.text :last_heartbeat_error

      t.timestamps
    end
  end
end
