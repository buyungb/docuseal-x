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
    can :manage, TemplateFolder, account_id: user.account_id
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
    # Read all templates in account, but only manage own templates (author_id)
    can :read, Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'read')
    end
    can %i[create update destroy], Template, author_id: user.id

    # Own template folders only
    can :read, TemplateFolder, account_id: user.account_id
    can %i[create update destroy], TemplateFolder, author_id: user.id

    # Can share own templates
    can :manage, TemplateSharing, template: { author_id: user.id }

    # Read all submissions, but only manage submissions for own templates
    can :read, Submission, account_id: user.account_id
    can %i[create update destroy], Submission, template: { author_id: user.id }

    # Read all submitters, but only manage submitters for own templates
    can :read, Submitter, account_id: user.account_id
    can %i[create update destroy], Submitter, submission: { template: { author_id: user.id } }

    # Can only read and update own user profile
    can :read, User, id: user.id
    can :update, User, id: user.id
  end

  def viewer_abilities(user)
    # Read-only access to templates
    can :read, Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'read')
    end

    # Read-only access to template folders
    can :read, TemplateFolder, account_id: user.account_id

    # Read-only access to submissions
    can :read, Submission, account_id: user.account_id

    # Read-only access to submitters
    can :read, Submitter, account_id: user.account_id

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
