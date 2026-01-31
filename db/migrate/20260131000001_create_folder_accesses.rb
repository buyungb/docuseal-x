# frozen_string_literal: true

class CreateFolderAccesses < ActiveRecord::Migration[7.1]
  def change
    create_table :folder_accesses do |t|
      t.references :template_folder, null: false, foreign_key: true
      t.bigint :user_id, null: false

      t.timestamps
    end

    add_index :folder_accesses, %i[template_folder_id user_id], unique: true
  end
end
