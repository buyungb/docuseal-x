# frozen_string_literal: true

module Abilities
  module FolderConditions
    module_function

    # For editors - can see own folders OR folders shared with them OR default folder
    def editor_collection(user)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      TemplateFolder.where(account_id: user.account_id).where(
        TemplateFolder.arel_table[:author_id].eq(user.id)
          .or(TemplateFolder.arel_table[:id].in(shared_folder_ids.arel))
          .or(TemplateFolder.arel_table[:name].eq(TemplateFolder::DEFAULT_NAME))
      )
    end

    def editor_entity(folder, user:)
      return true if folder.account_id.blank?
      return true if folder.author_id == user.id && folder.account_id == user.account_id
      return true if folder.folder_accesses.exists?(user_id: user.id)
      return true if folder.name == TemplateFolder::DEFAULT_NAME && folder.account_id == user.account_id

      false
    end

    # For viewers - can only see folders explicitly shared with them OR default folder
    def viewer_collection(user)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      TemplateFolder.where(account_id: user.account_id).where(
        TemplateFolder.arel_table[:id].in(shared_folder_ids.arel)
          .or(TemplateFolder.arel_table[:name].eq(TemplateFolder::DEFAULT_NAME))
      )
    end

    def viewer_entity(folder, user:)
      return true if folder.account_id.blank?
      return true if folder.folder_accesses.exists?(user_id: user.id)
      return true if folder.name == TemplateFolder::DEFAULT_NAME && folder.account_id == user.account_id

      false
    end
  end
end
