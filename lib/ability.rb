# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    return unless user

    if user.role == 'admin'
      can :manage, :all

    elsif user.role == 'editor'
      can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
        Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
      end
      can :destroy, Template, account_id: user.account_id
      can :manage, TemplateFolder, account_id: user.account_id
      can :manage, TemplateSharing, template: { account_id: user.account_id }
      can :manage, Submission, account_id: user.account_id
      can :manage, Submitter, account_id: user.account_id
      can :manage, EncryptedUserConfig, user_id: user.id
      can :manage, UserConfig, user_id: user.id
      can :manage, AccessToken, user_id: user.id
      can :read, WebhookUrl, account_id: user.account_id

    elsif user.role == 'viewer'
      can :read, Template, account_id: user.account_id
      can :read, TemplateFolder, account_id: user.account_id
      can :read, Submission, account_id: user.account_id
      can :read, Submitter, account_id: user.account_id
      can :manage, EncryptedUserConfig, user_id: user.id
      can :manage, UserConfig, user_id: user.id
      can :manage, AccessToken, user_id: user.id
      can :read, WebhookUrl, account_id: user.account_id
    end
  end
end
