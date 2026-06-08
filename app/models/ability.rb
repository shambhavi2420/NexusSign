# frozen_string_literal: true

class Ability
  include CanCan::Ability

  def initialize(user)
    return unless user

    if user.role == 'admin'
      can :manage, :all

    elsif user.role == 'editor'
      can :manage, Template, account_id: user.account_id
      can %i[read create], TemplateFolder, account_id: user.account_id
      can :manage, TemplateFolderPermission, template_folder: { account_id: user.account_id, author_id: user.id }
      can :manage, Submission, account_id: user.account_id
      can :manage, Submitter
      can :read, WebhookUrl, account_id: user.account_id
      can :manage, :countless
      can :manage, user

    elsif user.role == 'viewer'
      can :read, Template, account_id: user.account_id
      can :read, TemplateFolder, account_id: user.account_id
      can :read, Submission, account_id: user.account_id
      can :read, Submitter
      can :read, WebhookUrl, account_id: user.account_id
      can :manage, :countless
      can :manage, user
    end
  end
end
