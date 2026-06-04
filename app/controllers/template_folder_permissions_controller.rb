# frozen_string_literal: true

class TemplateFolderPermissionsController < ApplicationController
  skip_authorization_check

  before_action :load_folder
  before_action :authorize_owner_or_admin

  # GET /folders/:folder_id/permissions
  def index
    @users = TemplateFolderPermissions.permitted_users(@template_folder)
    render json: @users.as_json(only: %i[id email first_name last_name role])
  end

  # POST /folders/:folder_id/permissions
  def create
    user = current_account.users.active.find(params[:user_id])
    TemplateFolderPermissions.grant(user, @template_folder)
    head :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'User not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /folders/:folder_id/permissions/:id
  def destroy
    user = current_account.users.find_by(id: params[:id])
    TemplateFolderPermissions.revoke(user, @template_folder) if user
    head :no_content
  end

  private

  def load_folder
    @template_folder = current_account.template_folders.find(params[:folder_id])
  end

  def authorize_owner_or_admin
    return if current_user.role == User::ADMIN_ROLE
    return if @template_folder.author_id == current_user.id

    raise CanCan::AccessDenied
  end
end
