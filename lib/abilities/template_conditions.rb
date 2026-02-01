# frozen_string_literal: true

module Abilities
  module TemplateConditions
    module_function

    # For admins - can see all templates in account
    def collection(user, ability: nil)
      templates = Template.where(account_id: user.account_id)

      return templates unless user.account.testing?

      shared_ids =
        TemplateSharing.where({ ability:, account_id: [user.account_id, TemplateSharing::ALL_ID] }.compact)
                       .select(:template_id)

      Template.where(Template.arel_table[:id].in(templates.select(:id).arel.union(:all, shared_ids.arel)))
    end

    def entity(template, user:, ability: nil)
      return true if template.account_id.blank?
      return true if template.account_id == user.account_id
      return false unless user.account.linked_account_account
      return false if template.template_sharings.to_a.blank?

      account_ids = [user.account_id, TemplateSharing::ALL_ID]

      template.template_sharings.to_a.any? do |e|
        e.account_id.in?(account_ids) && (ability.nil? || e.ability == 'manage' || e.ability == ability)
      end
    end

    # For editors - can see own templates OR templates shared with them OR templates in shared folders
    def editor_collection(user)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      Template.where(account_id: user.account_id).where(
        Template.arel_table[:author_id].eq(user.id)
          .or(Template.arel_table[:id].in(shared_template_ids.arel))
          .or(Template.arel_table[:folder_id].in(shared_folder_ids.arel))
      )
    end

    def editor_entity(template, user:)
      return true if template.account_id.blank?
      return true if template.author_id == user.id && template.account_id == user.account_id
      return true if template.template_accesses.exists?(user_id: user.id)
      return true if template.folder && FolderAccess.exists?(template_folder_id: template.folder_id, user_id: user.id)

      false
    end

    # For viewers - can only see templates explicitly shared with them OR templates in shared folders
    def viewer_collection(user)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)

      Template.where(account_id: user.account_id).where(
        Template.arel_table[:id].in(shared_template_ids.arel)
          .or(Template.arel_table[:folder_id].in(shared_folder_ids.arel))
      )
    end

    def viewer_entity(template, user:)
      return true if template.account_id.blank?
      return true if template.template_accesses.exists?(user_id: user.id)
      return true if template.folder && FolderAccess.exists?(template_folder_id: template.folder_id, user_id: user.id)

      false
    end
  end
end
