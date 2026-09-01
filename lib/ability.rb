# frozen_string_literal: true

# Maps a user's role to CanCanCan permissions.
#
# super_admin -> unrestricted (manage :all).
# admin       -> full operational access plus the settings sections a super
#                admin granted them (see SettingsSections / User#admin_permissions).
# editor/viewer -> scoped content access.
class Ability
  include CanCan::Ability

  def initialize(user)
    return unless user

    case user.role
    when User::SUPER_ADMIN_ROLE then can :manage, :all
    when User::ADMIN_ROLE then admin_abilities(user)
    when 'editor' then editor_abilities(user)
    when 'viewer' then viewer_abilities(user)
    end
  end

  private

  # A regular admin keeps full day-to-day operational access, but settings
  # sections are gated: they only receive the sections a super admin has
  # explicitly assigned via SettingsSections / UserConfig.
  def admin_abilities(user)
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
    can :manage, User, id: user.id

    # Account access (read/update) is a grantable section, not a baseline
    # ability, so it is applied via apply_settings_sections below.
    apply_settings_sections(user)
  end

  def editor_abilities(user)
    can %i[read create update], Template, Abilities::TemplateConditions.collection(user) do |template|
      Abilities::TemplateConditions.entity(template, user:, ability: 'manage')
    end
    can :destroy, Template, account_id: user.account_id
    can %i[read create update], TemplateFolder, account_id: user.account_id
    can :manage, TemplateSharing, template: { account_id: user.account_id }
    can :manage, Submission, account_id: user.account_id
    can :manage, Submitter, account_id: user.account_id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id
    can :read, WebhookUrl, account_id: user.account_id
  end

  def viewer_abilities(user)
    can :read, Template, account_id: user.account_id
    can :read, TemplateFolder, account_id: user.account_id
    can :read, Submission, account_id: user.account_id
    can :read, Submitter, account_id: user.account_id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id
    can :read, WebhookUrl, account_id: user.account_id
  end

  def apply_settings_sections(user)
    user.admin_permissions.each do |section_key|
      SettingsSections.abilities_for(section_key).each do |actions, subject, config_key|
        conditions = ability_conditions(subject, config_key, user)

        if conditions
          can actions, subject, conditions
        else
          can actions, subject
        end
      end
    end
  end

  # Scope grants to the admin's own account where the subject supports it.
  def ability_conditions(subject, config_key, user)
    return unless subject.is_a?(Class)

    conditions = {}
    conditions[:account_id] = user.account_id if subject.column_names.include?('account_id')
    conditions[:key] = config_key if config_key.present? && subject.column_names.include?('key')

    conditions.presence
  end
end
