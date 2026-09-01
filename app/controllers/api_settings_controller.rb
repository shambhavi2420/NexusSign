# frozen_string_literal: true

class ApiSettingsController < ApplicationController
  before_action :authorize_api_section

  def index
    authorize!(:read, current_user.access_token)
  end

  def create
    authorize!(:manage, current_user.access_token)

    current_user.access_token.token = SecureRandom.base58(AccessToken::TOKEN_LENGTH)

    current_user.access_token.save!

    redirect_back(fallback_location: settings_api_index_path, notice: I18n.t('api_token_has_been_updated'))
  end

  private

  # A regular admin can always read their own token, so gate the API settings
  # screen on the granted 'api' section. Super admins are unrestricted.
  def authorize_api_section
    return if current_user.super_admin?
    return if current_user.can_access_setting?('api')

    raise CanCan::AccessDenied
  end
end
