# frozen_string_literal: true

module Abilities
  module SubmitterConditions
    module_function

    # For editors - can see submitters for own templates OR templates shared with them
    def editor_collection(user)
      own_template_ids = Template.where(author_id: user.id, account_id: user.account_id).select(:id)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)

      submission_ids = Submission.where(account_id: user.account_id)
                                 .where(
                                   Submission.arel_table[:template_id].in(own_template_ids.arel)
                                     .or(Submission.arel_table[:template_id].in(shared_template_ids.arel))
                                 )
                                 .select(:id)

      Submitter.where(submission_id: submission_ids)
    end

    # For viewers - can only see submitters for templates shared with them
    def viewer_collection(user)
      shared_template_ids = TemplateAccess.where(user_id: user.id).select(:template_id)
      submission_ids = Submission.where(account_id: user.account_id, template_id: shared_template_ids).select(:id)

      Submitter.where(submission_id: submission_ids)
    end
  end
end
