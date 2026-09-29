# frozen_string_literal: true

class TeamsController < ApplicationController
  skip_authorization_check

  before_action :authorize_admin
  before_action :load_team, only: %i[show edit update destroy]

  def index
    @teams = current_account.teams.order(:name).preload(:users)
  end

  def new
    @team = current_account.teams.new
  end

  def create
    @team = current_account.teams.new(team_params)

    if @team.save
      redirect_to settings_teams_path, notice: I18n.t('team_has_been_created')
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'teams/new'), status: :unprocessable_content
    end
  end

  def show
    @members = @team.users.active.order(:last_name, :first_name)
    @available_users = current_account.users.active
                                      .where.not(role: 'integration')
                                      .where.not(id: @team.user_ids)
                                      .order(:last_name, :first_name)
  end

  def edit; end

  def update
    if @team.update(team_params)
      redirect_to settings_team_path(@team), notice: I18n.t('team_has_been_updated')
    else
      render turbo_stream: turbo_stream.replace(:modal, template: 'teams/edit'), status: :unprocessable_content
    end
  end

  def destroy
    @team.destroy!

    redirect_to settings_teams_path, notice: I18n.t('team_has_been_removed')
  end

  private

  def authorize_admin
    return if current_user.super_admin?
    return if current_user.admin? && current_user.can_access_setting?('teams')

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  def load_team
    @team = current_account.teams.find(params[:id])
  end

  def team_params
    params.require(:team).permit(:name)
  end
end
