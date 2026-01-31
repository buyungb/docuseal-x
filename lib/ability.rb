# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    case user.role
    when User::ADMIN_ROLE
      admin_abilities(user)
    when User::EDITOR_ROLE
      editor_abilities(user)
    when User::VIEWER_ROLE
      viewer_abilities(user)
    else
      # Default to viewer for unknown roles
      viewer_abilities(user)
    end

    # Common abilities for all roles
    common_abilities(user)
  end

  private

  def admin_abilities(user)
    # Full manage on all account resources (original behavior)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end

    can :destroy, Template, account_id: user.account_id
    can :manage, TemplateAccess, template: { account_id: user.account_id }
    can :manage, TemplateFolder, account_id: user.account_id
    can :manage, FolderAccess, template_folder: { account_id: user.account_id }
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
    can :manage, User, account_id: user.account_id
    can :manage, EncryptedConfig, account_id: user.account_id
    can :manage, AccountConfig, account_id: user.account_id
    can :manage, Account, id: user.account_id
    can :manage, WebhookUrl, account_id: user.account_id
  end

  def editor_abilities(user)
    # Editors can only see their OWN templates OR templates shared with them via TemplateAccess
    can :read, Template, Abilities::TemplateConditions.editor_collection(user) do |template|
      Abilities::TemplateConditions.editor_entity(template, user:)
    end
    can %i[create update destroy], Template, author_id: user.id

    # Can manage sharing (TemplateAccess) for own templates
    can :manage, TemplateAccess, template: { author_id: user.id }

    # Own template folders + shared folders
    can :read, TemplateFolder, Abilities::FolderConditions.editor_collection(user) do |folder|
      Abilities::FolderConditions.editor_entity(folder, user:)
    end
    can %i[create update destroy], TemplateFolder, author_id: user.id

    # Can manage sharing (FolderAccess) for own folders
    can :manage, FolderAccess, template_folder: { author_id: user.id }

    # Can share own templates (TemplateSharing for external accounts)
    can :manage, TemplateSharing, template: { author_id: user.id }

    # Can only see submissions for own templates OR templates shared with them
    can :read, Submission, Abilities::SubmissionConditions.editor_collection(user)
    can %i[create update destroy], Submission, template: { author_id: user.id }

    # Can only see submitters for own templates OR templates shared with them
    can :read, Submitter, Abilities::SubmitterConditions.editor_collection(user)
    can %i[create update destroy], Submitter, submission: { template: { author_id: user.id } }

    # Can only read and update own user profile
    can :read, User, id: user.id
    can :update, User, id: user.id

    # Can read other users in the account (for sharing UI)
    can :read, User, account_id: user.account_id
  end

  def viewer_abilities(user)
    # Viewers can only see templates explicitly shared with them via TemplateAccess
    can :read, Template, Abilities::TemplateConditions.viewer_collection(user) do |template|
      Abilities::TemplateConditions.viewer_entity(template, user:)
    end

    # Only see folders shared with them
    can :read, TemplateFolder, Abilities::FolderConditions.viewer_collection(user) do |folder|
      Abilities::FolderConditions.viewer_entity(folder, user:)
    end

    # Can only see submissions for templates shared with them
    can :read, Submission, Abilities::SubmissionConditions.viewer_collection(user)

    # Can only see submitters for templates shared with them
    can :read, Submitter, Abilities::SubmitterConditions.viewer_collection(user)

    # Can only read own user profile
    can :read, User, id: user.id
  end

  def common_abilities(user)
    # All users can manage their own configs
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id

    # Admin and editor can manage their own access tokens
    can :manage, AccessToken, user_id: user.id if user.admin? || user.editor?
  end
end
