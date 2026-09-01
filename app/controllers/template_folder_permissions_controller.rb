# frozen_string_literal: true

class TemplateFolderPermissionsController < ApplicationController
  skip_authorization_check

  before_action :load_folder
  before_action :authorize_owner_or_admin

  # GET /folders/:folder_id/permissions
  def index
    @users = TemplateFolderPermissions.permitted_users(@template_folder)
    @teams = TemplateFolderPermissions.permitted_teams(@template_folder)

    render json: {
      users: @users.as_json(only: %i[id email first_name last_name role]),
      teams: @teams.as_json(only: %i[id name])
    }
  end

  # POST /folders/:folder_id/permissions
  def create
    if params[:team_id].present?
      team = current_account.teams.find(params[:team_id])
      TemplateFolderPermissions.grant_team(team, @template_folder)
    else
      user = current_account.users.active.find(params[:user_id])
      TemplateFolderPermissions.grant(user, @template_folder)
    end

    head :created
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Record not found' }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /folders/:folder_id/permissions/:id
  def destroy
    if params[:type] == 'team'
      team = current_account.teams.find_by(id: params[:id])
      if team
        if params[:revoke_members] == 'true'
          # Revoke individual permissions for all team members too
          team.users.each do |member|
            TemplateFolderPermissions.revoke(member, @template_folder)
          end
        end
        TemplateFolderPermissions.revoke_team(team, @template_folder)
        Rails.logger.info "[FolderPermissions] Revoked team #{team.id} from folder #{@template_folder.id} (revoke_members=#{params[:revoke_members]})"
      end
    else
      user = current_account.users.find_by(id: params[:id])

      if user
        TemplateFolderPermissions.revoke(user, @template_folder)
        count = TemplateFolderPermission.where(template_folder_id: @template_folder.id).count
        Rails.logger.info "[FolderPermissions] Revoked user #{user.id} from folder #{@template_folder.id}. Permission records now: #{count}"
      else
        Rails.logger.warn "[FolderPermissions] User not found: #{params[:id]}"
      end
    end

    head :no_content
  rescue StandardError => e
    Rails.logger.error "[FolderPermissions] Error in destroy: #{e.class}: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def load_folder
    @template_folder = current_account.template_folders.find(params[:folder_id])
  end

  def authorize_owner_or_admin
    return if current_user.admin?
    return if @template_folder.author_id == current_user.id

    raise CanCan::AccessDenied
  end
end
