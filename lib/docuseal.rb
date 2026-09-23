# frozen_string_literal: true

module Docuseal
  URL_CACHE = ActiveSupport::Cache::MemoryStore.new
  PRODUCT_URL = ''
  PRODUCT_EMAIL_URL = ''
  NEWSLETTER_URL = ''
  ENQUIRIES_URL = ''
  PRODUCT_NAME = 'NexusSIGN'
  DEFAULT_APP_URL = ENV.fetch('APP_URL', 'http://localhost:3000')
  GITHUB_URL = ''
  DISCORD_URL = ''
  TWITTER_URL = ''
  TWITTER_HANDLE = ''
  CHATGPT_URL = ''
  SUPPORT_EMAIL = ''
  HOST = ENV.fetch('HOST', 'localhost')
  AATL_CERT_NAME = ''
  CONSOLE_URL = if Rails.env.development?
                  'http://console.localhost.io:3001'
                elsif ENV['MULTITENANT'] == 'true'
                  "https://console.#{HOST}"
                else
                  ''
                end
  CLOUD_URL = if Rails.env.development?
                'http://localhost:3000'
              else
                ''
              end
  CDN_URL = if Rails.env.development?
              'http://localhost:3000'
            elsif ENV['MULTITENANT'] == 'true'
              "https://cdn.#{HOST}"
            else
              ''
            end

  CERTS = JSON.parse(ENV.fetch('CERTS', '{}'))
  TIMESERVER_URL = ENV.fetch('TIMESERVER_URL', nil)
  VERSION_FILE_PATH = Rails.root.join('.version')

  DEFAULT_URL_OPTIONS = {
    host: HOST,
    protocol: ENV['FORCE_SSL'].present? ? 'https' : 'http'
  }.freeze

  module_function

  def version
    @version ||= VERSION_FILE_PATH.read.strip if VERSION_FILE_PATH.exist?
  end

  def multitenant?
    ENV['MULTITENANT'] == 'true'
  end

  PRODUCT_MODES = [
    HEALTHCARE_MODE = 'healthcare',
    STANDARD_MODE = 'standard'
  ].freeze

  # Product mode is resolved PER-COMPANY with a platform default fallback
  # (Option B):
  #   1. the given company's own product_mode override (AccountConfig), else
  #   2. the platform (lowest-id account) default product_mode, else
  #   3. 'healthcare' (existing behavior).
  # Pass the company (Account) you're resolving for; nil resolves the platform
  # default. AccountConfig#value is JSON-serialized, so read through the model.
  # Memoized per-account per-process; call reset_product_mode! after a change.
  # See .kiro/specs/standard-productized-mode.
  def product_mode(account = nil)
    return HEALTHCARE_MODE unless AccountConfig.table_exists? && Account.exists?

    account_id = account.respond_to?(:id) ? account.id : account

    @product_mode_cache ||= {}
    cache_key = account_id || :__platform_default__
    cached = @product_mode_cache[cache_key]
    return cached if cached

    own = account_id && read_mode_config(account_id)
    resolved = own || platform_default_product_mode

    @product_mode_cache[cache_key] = resolved
  end

  # The platform-wide default mode, stored on the lowest-id account. This is the
  # value a company inherits when it has no override of its own.
  def platform_default_product_mode
    @platform_default_product_mode ||= begin
      platform_account_id = Account.order(:id).limit(1).pick(:id)
      read_mode_config(platform_account_id) || HEALTHCARE_MODE
    end
  end

  def standard_mode?(account = nil)
    product_mode(account) == STANDARD_MODE
  end

  def healthcare_mode?(account = nil)
    !standard_mode?(account)
  end

  # True when per-company configuration must be fully isolated (no "fall back to
  # the first account" config lookups) so a company never inherits another
  # company's SMTP/timeserver/certs/webhook/config values. True whenever the
  # given company is in Standard Mode, or for the hosted multitenant deployment.
  # See .kiro/specs/standard-productized-mode (Requirement 2.7).
  def per_company_config_isolation?(account = nil)
    standard_mode?(account) || multitenant?
  end

  # False when the given company is in Standard Mode: cross-company sharing doors
  # (linked/testing accounts, share-to-all-accounts) are disabled for it.
  # See .kiro/specs/standard-productized-mode (Requirement 5).
  def cross_account_sharing_allowed?(account = nil)
    !standard_mode?(account)
  end

  def reset_product_mode!
    @product_mode_cache = {}
    @platform_default_product_mode = nil
  end

  # Reads and validates a single account's product_mode override, or nil.
  def read_mode_config(account_id)
    return nil if account_id.blank?

    value = AccountConfig.find_by(account_id:, key: AccountConfig::PRODUCT_MODE_KEY)&.value

    PRODUCT_MODES.include?(value) ? value : nil
  end

  def advanced_formats?
    true
  end
  def demo?
    ENV['DEMO'] == 'true'
  end

  def active_storage_public?
    ENV['ACTIVE_STORAGE_PUBLIC'] == 'true'
  end

  def default_pkcs
    return if Docuseal::CERTS['enabled'] == false

    @default_pkcs ||= GenerateCertificate.load_pkcs(Docuseal::CERTS)
  end

  def fulltext_search?
    return @fulltext_search unless @fulltext_search.nil?

    @fulltext_search =
      if SearchEntry.table_exists?
        Docuseal.multitenant? || AccountConfig.exists?(key: :fulltext_search, value: true)
      else
        false
      end
  end

  def enable_pwa?
    true
  end

  def pdf_format
    @pdf_format ||= ENV['PDF_FORMAT'].to_s.downcase
  end

  def trusted_certs
    @trusted_certs ||=
      ENV['TRUSTED_CERTS'].to_s.gsub('\\n', "\n").split("\n\n").map do |base64|
        OpenSSL::X509::Certificate.new(base64)
      end
  end

  def default_url_options
    return DEFAULT_URL_OPTIONS if multitenant?

    @default_url_options ||= begin
      value = EncryptedConfig.find_by(key: EncryptedConfig::APP_URL_KEY)&.value if ENV['APP_URL'].blank?
      value ||= DEFAULT_APP_URL
      url = Addressable::URI.parse(value)
      { host: url.host, port: url.port, protocol: url.scheme }
    end
  end

  def product_name
    PRODUCT_NAME
  end

  def refresh_default_url_options!
    @default_url_options = nil
  end
end
