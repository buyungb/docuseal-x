# frozen_string_literal: true

module Abilities
  module SubmissionConditions
    module_function

    # For editors - can see submissions for own templates OR templates shared with them OR templates in shared folders
    def editor_collection(user)
      own_template_ids = Template.where(author_id: user.id, account_id: user.account_id).select(:id)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)
      templates_in_shared_folders = Template.where(folder_id: shared_folder_ids, account_id: user.account_id).select(:id)

      Submission.where(account_id: user.account_id)
                .where(
                  Submission.arel_table[:template_id].in(own_template_ids.arel)
                    .or(Submission.arel_table[:template_id].in(shared_template_ids.arel))
                    .or(Submission.arel_table[:template_id].in(templates_in_shared_folders.arel))
                )
    end

    # For viewers - can only see submissions for templates shared with them OR templates in shared folders
    def viewer_collection(user)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)
      shared_folder_ids = FolderAccess.where(user_id: user.id).select(:template_folder_id)
      templates_in_shared_folders = Template.where(folder_id: shared_folder_ids, account_id: user.account_id).select(:id)

      Submission.where(account_id: user.account_id)
                .where(
                  Submission.arel_table[:template_id].in(shared_template_ids.arel)
                    .or(Submission.arel_table[:template_id].in(templates_in_shared_folders.arel))
                )
    end
  end
end
