# frozen_string_literal: true

module Abilities
  module FolderConditions
    module_function

    # For editors - can see own folders OR folders shared with them
    def editor_collection(user)
      own_folders = TemplateFolder.where(author_id: user.id, account_id: user.account_id)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      # Also include default folder
      default_folder = TemplateFolder.where(account_id: user.account_id, name: TemplateFolder::DEFAULT_NAME)

      TemplateFolder.where(
        TemplateFolder.arel_table[:id].in(
          own_folders.select(:id).arel
            .union(:all, shared_folder_ids.arel)
            .union(:all, default_folder.select(:id).arel)
        )
      ).where(account_id: user.account_id)
    end

    def editor_entity(folder, user:)
      return true if folder.account_id.blank?
      return true if folder.author_id == user.id && folder.account_id == user.account_id
      return true if folder.folder_accesses.exists?(user_id: user.id)
      return true if folder.name == TemplateFolder::DEFAULT_NAME && folder.account_id == user.account_id

      false
    end

    # For viewers - can only see folders explicitly shared with them
    def viewer_collection(user)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      # Also include default folder
      default_folder = TemplateFolder.where(account_id: user.account_id, name: TemplateFolder::DEFAULT_NAME)

      TemplateFolder.where(
        TemplateFolder.arel_table[:id].in(
          shared_folder_ids.arel.union(:all, default_folder.select(:id).arel)
        )
      ).where(account_id: user.account_id)
    end

    def viewer_entity(folder, user:)
      return true if folder.account_id.blank?
      return true if folder.folder_accesses.exists?(user_id: user.id)
      return true if folder.name == TemplateFolder::DEFAULT_NAME && folder.account_id == user.account_id

      false
    end
  end
end
