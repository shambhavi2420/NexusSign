# frozen_string_literal: true

# Maps a user's role to CanCanCan permissions.
#
# super_admin -> unrestricted (manage :all).
# admin       -> full operational access plus the settings sections a super
#                admin granted them (see SettingsSections / User#admin_permissions).
# editor/viewer -> scoped content access.
class Ability
  include CanCan::Ability

  # `acting_account_id` scopes a super admin's content abilities to a specific
  # company (the sticky "acting company"). When nil, a super admin keeps the
  # unrestricted `manage :all`. This is how the Platform Super Admin operates
  # inside one company at a time without leaking across companies.
  # See .kiro/specs/standard-productized-mode (Requirement 3.6).
  def initialize(user, acting_account_id = nil)
    return unless user

    case user.role
    when User::SUPER_ADMIN_ROLE then super_admin_abilities(user, acting_account_id)
    when User::ADMIN_ROLE then admin_abilities(user)
    when 'editor' then editor_abilities(user)
    when 'viewer' then viewer_abilities(user)
    end
  end

  private

  # A super admin is ALWAYS scoped to exactly one company at a time — the
  # "current" company, which is the acting company when one is selected, or
  # their own account (home) otherwise. There is no unscoped `manage :all`:
  # content (templates, folders, submissions, users, etc.) is always fenced to
  # the current company so one company's data never appears while viewing
  # another (including at home). Cross-company reach is limited to the platform
  # management surfaces that genuinely need it: listing/creating/archiving
  # companies (Account) and reading any Account for the switcher.
  # We use hash conditions (not blocks) so accessible_by generates correct SQL.
  # See .kiro/specs/standard-productized-mode (Requirement 3.6).
  def super_admin_abilities(user, acting_account_id)
    current_account_id = acting_account_id.presence || user.account_id
    account_scope = { account_id: current_account_id }

    # Core content, scoped to the current company.
    can :manage, Template, account_scope
    can :manage, TemplateFolder, account_scope
    can :manage, TemplateSharing, template: account_scope
    can :manage, Submission, account_scope
    can :manage, Submitter, account_scope
    can :manage, Team, account_scope
    can :manage, TemplateAccess, template: account_scope
    can :manage, TemplateFolderPermission, template_folder: account_scope
    can :manage, TeamMembership, team: account_scope

    # Users of the current company (drives the Users settings page).
    can :manage, User, account_scope

    # The super admin's OWN user record must always be manageable regardless of
    # which company they're acting in, so the Profile page (authorize! :manage,
    # current_user) works everywhere. This overrides the account scope for self.
    can :manage, User, id: user.id

    # Per-account configuration (account / personalization / email / storage /
    # webhook / SSO / esign settings for the current company).
    can :manage, AccountConfig, account_scope
    can :manage, EncryptedConfig, account_scope
    can :manage, WebhookUrl, account_scope

    # Self-owned records (the super admin's own profile/token/configs).
    can :manage, UserConfig, user_id: user.id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id

    # Platform-management reach: the super admin can read every company (for the
    # switcher and Companies list) and manage the company records themselves
    # (create/archive). This is the ONLY cross-company capability.
    can :read, Account
    can :manage, Account

    # Countless pagination, as super admins normally have.
    can :manage, :countless
  end

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
    can :manage, User, id: user.id

    # Account access (read/update) is a grantable section, not a baseline
    # ability, so it is applied via apply_settings_sections below.
    apply_settings_sections(user)

    # Super admins are the highest level of control: a regular admin (even one
    # granted the Users section) must never edit, delete, or change a super
    # admin. This cannot-rule runs last so it overrides the section grant.
    cannot :manage, User, role: User::SUPER_ADMIN_ROLE
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
    can :manage, User, id: user.id
  end

  def viewer_abilities(user)
    can :read, Template, account_id: user.account_id
    can :read, TemplateFolder, account_id: user.account_id
    can :read, Submission, account_id: user.account_id
    can :read, Submitter, account_id: user.account_id
    can :manage, EncryptedUserConfig, user_id: user.id
    can :manage, UserConfig, user_id: user.id
    can :manage, AccessToken, user_id: user.id
    can :manage, User, id: user.id
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
