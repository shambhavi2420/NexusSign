# frozen_string_literal: true

class ApplicationController < ActionController::Base
  BROWSER_LOCALE_REGEXP = /\A\w{2}(?:-\w{2})?/

  include ActiveStorage::SetCurrent
  include Pagy::Backend

  check_authorization unless: :devise_controller?

  around_action :with_locale
  before_action :sign_in_for_demo, if: -> { Docuseal.demo? }
  before_action :maybe_redirect_to_setup, unless: :signed_in?
  before_action :authenticate_user!, unless: :devise_controller?

  before_action :set_csp, if: -> { request.get? && !request.headers['HTTP_X_TURBO'] }

  helper_method :button_title,
                :current_account,
                :form_link_host,
                :svg_icon

  impersonates :user, with: ->(uuid) { User.find_by(uuid:) }

  rescue_from Pagy::OverflowError do
    redirect_to request.path
  end

  rescue_from RateLimit::LimitApproached do |e|
    Rollbar.error(e) if defined?(Rollbar)

    redirect_to request.referer, alert: 'Too many requests', status: :too_many_requests
  end

  if Rails.env.production? || Rails.env.test?
    rescue_from CanCan::AccessDenied do |e|
      Rollbar.warning(e) if defined?(Rollbar)

      redirect_to root_path, alert: e.message
    end
  end

  def default_url_options
    if request.domain == 'docuseal.com'
      return { host: 'docuseal.com', protocol: ENV['FORCE_SSL'].present? ? 'https' : 'http' }
    end

    Docuseal.default_url_options
  end

  def impersonate_user(user)
    raise ArgumentError unless user
    raise Pretender::Error unless true_user

    @impersonated_user = user

    request.session[:impersonated_user_id] = user.uuid
  end

  # Build the ability with the super admin's acting-company context so that,
  # while acting inside a company, even a super admin's content abilities are
  # scoped to that company (no cross-company leakage). Regular users are
  # unaffected (acting_company is nil for them).
  # See .kiro/specs/standard-productized-mode (Requirement 3.6).
  def current_ability
    @current_ability ||= Ability.new(current_user, acting_company&.id)
  end

  def pagy_auto(collection, **keyword_args)
    if current_ability.can?(:manage, :countless)
      pagy_countless(collection, **keyword_args)
    else
      pagy(collection, **keyword_args)
    end
  end

  private

  def with_locale(&)
    return yield unless current_account

    locale   = params[:lang].presence if Rails.env.development?
    locale ||= current_account.locale

    I18n.with_locale(locale, &)
  end

  def with_browser_locale(&)
    return yield if I18n.locale != :'en-US' && I18n.locale != :en

    locale   = params[:lang].presence
    locale ||= request.env['HTTP_ACCEPT_LANGUAGE'].to_s[BROWSER_LOCALE_REGEXP].to_s

    locale =
      if locale.starts_with?('en-') && locale != 'en-US'
        'en-GB'
      else
        locale.split('-').first.presence || 'en-GB'
      end

    locale = 'en-GB' unless I18n.locale_available?(locale)

    I18n.with_locale(locale, &)
  end

  def sign_in_for_demo
    sign_in(User.active.order('random()').take) unless signed_in?
  end

  # The company whose data the current request operates within.
  #
  # For regular users this is simply their own account. For the Platform Super
  # Admin it is the sticky "acting company" they selected (session-persisted),
  # falling back to their own account when none is selected or the selection is
  # no longer valid (missing/archived). See .kiro/specs/standard-productized-mode
  # (Requirement 3.6).
  def current_account
    return current_user&.account unless current_user&.super_admin?

    acting_company || current_user.account
  end

  # The super admin's selected acting company, or nil. Clears an invalid
  # selection so a stale/archived id can never scope a request.
  def acting_company
    return nil unless current_user&.super_admin?

    id = session[:acting_account_id]
    return nil if id.blank?

    account = Account.active.find_by(id:)

    if account.nil?
      session.delete(:acting_account_id)
      return nil
    end

    account
  end
  helper_method :acting_company

  # True when the super admin is acting inside a company other than their own.
  def acting_as_other_company?
    company = acting_company
    company.present? && company.id != current_user&.account_id
  end
  helper_method :acting_as_other_company?

  def maybe_redirect_to_setup
    redirect_to setup_index_path unless User.exists?
  end

  def button_title(title: I18n.t('submit'), disabled_with: I18n.t('submitting'), title_class: '', icon: nil,
                   icon_disabled: nil)
    render_to_string(partial: 'shared/button_title',
                     locals: { title:, disabled_with:, title_class:, icon:, icon_disabled: })
  end

  def svg_icon(icon_name, class: '')
    render_to_string(partial: "icons/#{icon_name}", locals: { class: })
  end

  def form_link_host
    Docuseal.default_url_options[:host]
  end

  def maybe_redirect_com
    return if request.domain != 'docuseal.co'

    redirect_to request.url.gsub('.co/', '.com/'), allow_other_host: true, status: :moved_permanently
  end

  def set_csp
    request.content_security_policy = current_content_security_policy.tap do |policy|
      policy.default_src :self
      policy.script_src :self
      policy.style_src :self, :unsafe_inline
      policy.img_src :self, :https, :http, :blob, :data
      policy.font_src :self, :https, :http, :blob, :data
      policy.manifest_src :self
      policy.media_src :self
      policy.frame_src :self
      policy.worker_src :self, :blob
      policy.connect_src :self

      policy.directives['connect-src'] << 'ws:' if Rails.env.development?
    end
  end
end
