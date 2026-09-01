# frozen_string_literal: true

class FolderPermissionsSettingsController < ApplicationController
  skip_authorization_check

  before_action :authorize_access

  def show
    @folders = manageable_folders
    @users = current_account.users.active.where.not(role: 'integration').order(:last_name, :first_name)
    @teams = current_account.teams.order(:name)
  end

  private

  def authorize_access
    return if folder_permissions_admin?
    return if current_account.template_folders.active.exists?(author_id: current_user.id)

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  def folder_permissions_admin?
    current_user.super_admin? || current_user.can_access_setting?('folder_permissions')
  end

  def manageable_folders
    scope = current_account.template_folders.active.order(:name)

    scope = if folder_permissions_admin?
              scope
            else
              scope.where(author_id: current_user.id)
            end

    # Only include folders that contain active templates (directly or in subfolders)
    templates_scope = current_account.templates.active
    TemplateFolders.filter_active_folders(scope, templates_scope)
  end
end
