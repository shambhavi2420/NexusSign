# frozen_string_literal: true

module ActionMailerConfigsInterceptor
  OPEN_TIMEOUT = ENV.fetch('SMTP_OPEN_TIMEOUT', '15').to_i
  READ_TIMEOUT = ENV.fetch('SMTP_READ_TIMEOUT', '25').to_i

  module_function

  def delivering_email(message)
    return message unless Rails.env.production?

    if Docuseal.demo?
      message.delivery_method(:test)

      return message
    end

    if Rails.env.production? && Rails.application.config.action_mailer.delivery_method
      from = ENV.fetch('SMTP_FROM').to_s.split(',').sample

      if from.match?(User::FULL_EMAIL_REGEXP)
        message[:from] = message[:from].to_s.sub(User::EMAIL_REGEXP, from)
      else
        message.from = from
      end

      return message
    end

    # Under per-company config isolation (multitenant or Standard Mode) we must
    # NOT inject a single global SMTP config for every message — that would send
    # one company's mail using another company's SMTP. Multitenant deployments
    # resolve SMTP per-account elsewhere; skip the global override here.
    unless Docuseal.per_company_config_isolation?
      # Resolve SMTP/from for the SENDING company (from message metadata), not
      # blindly the first account — otherwise every company's mail would show
      # the first account's name. Fall back to the first account's SMTP for
      # delivery when the sending company has none configured.
      sending_account = account_from_message(message)

      email_configs = EncryptedConfig.find_by(account: sending_account, key: EncryptedConfig::EMAIL_SMTP_KEY) if sending_account
      email_configs ||= EncryptedConfig.order(:account_id).find_by(key: EncryptedConfig::EMAIL_SMTP_KEY)

      if email_configs
        message.delivery_method(:smtp, build_smtp_configs_hash(email_configs))

        # Prefer the sending company's name for the display name so the "From"
        # reflects the actual company; fall back to the SMTP config's account.
        from_name = (sending_account&.name || email_configs.account.name).to_s.delete('"')
        message.from = %("#{from_name}" <#{email_configs.value['from_email']}>)
      else
        message.delivery_method(:test)
      end
    end

    message
  end

  # Derives the sending company (Account) from the message metadata that the
  # mailers attach (record_id/record_type). Returns nil if it can't resolve.
  def account_from_message(message)
    metadata = message.instance_variable_get(:@message_metadata)
    return nil if metadata.blank?

    record_type = metadata['record_type']
    record_id = metadata['record_id']
    return nil if record_type.blank? || record_id.blank?

    record = record_type.safe_constantize&.find_by(id: record_id)
    return nil unless record

    if record.respond_to?(:account)
      record.account
    elsif record.respond_to?(:account_id)
      Account.find_by(id: record.account_id)
    end
  rescue StandardError
    nil
  end

  def build_smtp_configs_hash(email_configs)
    value = email_configs.value

    {
      user_name: value['username'],
      password: value['password'],
      address: value['host'],
      port: value['port'],
      domain: value['domain'],
      openssl_verify_mode: value['security'] == 'noverify' ? OpenSSL::SSL::VERIFY_NONE : nil,
      authentication: value['password'].present? ? value.fetch('authentication', 'plain') : nil,
      enable_starttls_auto: value['security'] != 'tls',
      open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT,
      ssl: value['security'] == 'ssl',
      tls: value['security'] == 'tls' || (value['security'].blank? && value['port'].to_s == '465')
    }.compact_blank
  end
end
