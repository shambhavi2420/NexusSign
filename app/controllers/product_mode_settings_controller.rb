# frozen_string_literal: true

# Lets the Platform Super Admin set the product mode (standard vs healthcare)
# for the CURRENT company. Product mode is per-company with a platform default
# fallback (Option B): the platform (lowest-id) account's setting is the default
# that companies inherit; any company can override it with its own value, or
# clear the override to inherit the default again.
# See .kiro/specs/standard-productized-mode.
class ProductModeSettingsController < ApplicationController
  skip_authorization_check

  before_action :authorize_super_admin

  INHERIT = 'inherit'

  def show
    @company = current_account
    @is_platform = platform_account?(@company)
    # The company's own override, or nil when it inherits the default.
    @override = Docuseal.read_mode_config(@company&.id)
    @effective_mode = Docuseal.product_mode(@company)
    @default_mode = Docuseal.platform_default_product_mode
  end

  def update
    mode = params[:product_mode].to_s
    config = AccountConfig.find_or_initialize_by(account: current_account, key: AccountConfig::PRODUCT_MODE_KEY)

    if mode == INHERIT && !platform_account?(current_account)
      # A non-platform company can clear its override to inherit the default.
      config.destroy if config.persisted?
    elsif Docuseal::PRODUCT_MODES.include?(mode)
      config.value = mode
      config.save!
    else
      return redirect_to settings_product_mode_path, alert: I18n.t('not_authorized')
    end

    Docuseal.reset_product_mode!

    redirect_to settings_product_mode_path, notice: I18n.t('changes_have_been_saved')
  end

  private

  def authorize_super_admin
    return if current_user.super_admin?

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  # The platform account (lowest id) holds the global default; it cannot
  # "inherit" — its value IS the default.
  def platform_account?(account)
    account.present? && account.id == Account.order(:id).limit(1).pick(:id)
  end
  helper_method :platform_account?
end
