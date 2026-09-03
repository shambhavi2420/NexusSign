# frozen_string_literal: true

class RevealAccessTokenController < ApplicationController
  before_action :authorize_api_section

  def show
    authorize!(:manage, current_user.access_token)
  end

  def create
    authorize!(:manage, current_user.access_token)

    if current_user.valid_password?(params[:password])
      render turbo_stream: turbo_stream.replace(:access_token_container,
                                                partial: 'reveal_access_token/access_token',
                                                locals: { token: current_user.access_token.token })
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'reveal_access_token/show',
                                                        locals: { error_message: I18n.t('wrong_password') }),
             status: :unprocessable_content
    end
  end

  private

  # Revealing the API token is part of the API settings screen, so gate it on
  # the granted 'api' section. Super admins are unrestricted; editors and
  # ungranted admins are blocked even though they can manage their own token.
  def authorize_api_section
    return if current_user.super_admin?
    return if current_user.can_access_setting?('api')

    raise CanCan::AccessDenied
  end
end
