# frozen_string_literal: true

# Single source of truth for the configurable settings sections that a
# super admin can grant to (or revoke from) a regular admin.
#
# Each section maps a stable key to:
#   * label_key  - i18n key used for the checkbox label / nav link
#   * abilities   - the CanCanCan grants applied when an admin has the section.
#                   An array of [actions, subject] or [actions, subject, key]
#                   tuples. When a third element (key) is present the subject is
#                   scoped to that config key (used for EncryptedConfig, whose
#                   authorization is keyed by config type). Ability applies the
#                   grant scoped to the admin's account.
#
# The nav partial, the Ability model and the permissions UI all read from this
# catalog so hidden links and server-side enforcement never drift apart.
module SettingsSections
  # NOTE: keys are persisted per-user in UserConfig, so do not rename them
  # without a data migration.
  SECTIONS = {
    'account' => {
      label_key: 'account',
      abilities: [[%i[read update], Account]]
    },
    'email' => {
      label_key: 'email',
      abilities: [[%i[read create], EncryptedConfig, EncryptedConfig::EMAIL_SMTP_KEY]]
    },
    'storage' => {
      label_key: 'storage',
      abilities: [[%i[read create], EncryptedConfig, EncryptedConfig::FILES_STORAGE_KEY]]
    },
    'notifications' => {
      label_key: 'notifications',
      abilities: [[%i[read create], AccountConfig]]
    },
    'personalization' => {
      label_key: 'personalization',
      abilities: [[%i[read create], AccountConfig]]
    },
    'users' => {
      label_key: 'users',
      abilities: [[:manage, User]]
    },
    'teams' => {
      label_key: 'teams',
      abilities: [[:manage, Team], [:manage, TeamMembership]]
    },
    'folder_permissions' => {
      label_key: 'folder_permissions',
      abilities: [[:manage, TemplateFolderPermission]]
    },
    'api' => {
      label_key: 'API',
      abilities: [[:manage, AccessToken]]
    },
    'webhooks' => {
      label_key: 'webhook_settings',
      abilities: [[:manage, WebhookUrl]]
    },
    # Data migration and background jobs are guarded by custom controller /
    # route gates rather than a CanCanCan subject, so they have no abilities.
    # Access is driven purely by User#can_access_setting?(<key>).
    'data_migration' => {
      label_key: 'data_migration',
      abilities: []
    },
    'jobs' => {
      label_key: 'background_jobs',
      abilities: []
    }
  }.freeze

  module_function

  def keys
    SECTIONS.keys
  end

  def all
    SECTIONS
  end

  def label_key(key)
    SECTIONS.dig(key.to_s, :label_key)
  end

  def exists?(key)
    SECTIONS.key?(key.to_s)
  end

  def abilities_for(key)
    SECTIONS.dig(key.to_s, :abilities) || []
  end
end
