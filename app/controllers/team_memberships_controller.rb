# frozen_string_literal: true

class TeamMembershipsController < ApplicationController
  skip_authorization_check

  before_action :authorize_admin
  before_action :load_team

  # POST /settings/teams/:team_id/memberships
  def create
    user = current_account.users.active.find(params[:user_id])
    TeamMembership.find_or_create_by!(team: @team, user:)

    redirect_to settings_team_path(@team), notice: I18n.t('user_added_to_team')
  rescue ActiveRecord::RecordNotFound
    redirect_to settings_team_path(@team), alert: I18n.t('user_not_found')
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_team_path(@team), alert: e.message
  end

  # DELETE /settings/teams/:team_id/memberships/:id
  def destroy
    membership = @team.team_memberships.find_by(user_id: params[:id])
    membership&.destroy

    redirect_to settings_team_path(@team), notice: I18n.t('user_removed_from_team')
  end

  private

  def authorize_admin
    return if current_user.admin?

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  def load_team
    @team = current_account.teams.find(params[:team_id])
  end
end
