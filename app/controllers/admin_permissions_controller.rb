# frozen_string_literal: true

# Lets a super admin control which settings sections a given admin can access.
class AdminPermissionsController < ApplicationController
  skip_authorization_check

  before_action :authorize_super_admin
  before_action :load_admin

  def edit; end

  def update
    @admin.admin_permissions = permissions_params

    redirect_to settings_users_path, notice: I18n.t('changes_have_been_saved')
  end

  private

  def authorize_super_admin
    return if current_user.super_admin?

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  def load_admin
    @admin = current_account.users.active.find(params[:user_id])

    return if @admin.role == User::ADMIN_ROLE

    redirect_to settings_users_path, alert: I18n.t('not_authorized')
  end

  def permissions_params
    Array(params.dig(:user, :admin_permissions)).select(&:present?)
  end
end
