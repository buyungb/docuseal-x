# frozen_string_literal: true

module Abilities
  module SubmissionConditions
    module_function

    # For editors - can see submissions for own templates OR templates shared with them OR templates in shared folders
    def editor_collection(user)
      own_template_ids = Template.where(author_id: user.id, account_id: user.account_id).select(:id)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)

      base_condition = Submission.arel_table[:template_id].in(own_template_ids.arel)
                                 .or(Submission.arel_table[:template_id].in(shared_template_ids.arel))

      if folder_access_table_exists?
        shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)
        templates_in_shared_folders = Template.where(folder_id: shared_folder_ids, account_id: user.account_id).select(:id)
        base_condition = base_condition.or(Submission.arel_table[:template_id].in(templates_in_shared_folders.arel))
      end

      Submission.where(account_id: user.account_id).where(base_condition)
    end

    # For viewers - can only see submissions for templates shared with them OR templates in shared folders
    def viewer_collection(user)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)

      base_condition = Submission.arel_table[:template_id].in(shared_template_ids.arel)

      if folder_access_table_exists?
        shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)
        templates_in_shared_folders = Template.where(folder_id: shared_folder_ids, account_id: user.account_id).select(:id)
        base_condition = base_condition.or(Submission.arel_table[:template_id].in(templates_in_shared_folders.arel))
      end

      Submission.where(account_id: user.account_id).where(base_condition)
    end

    def folder_access_table_exists?
      @folder_access_table_exists ||= ActiveRecord::Base.connection.table_exists?('folder_accesses')
    rescue StandardError
      false
    end
  end
end
