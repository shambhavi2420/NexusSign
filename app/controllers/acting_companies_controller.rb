# frozen_string_literal: true

# Lets the Platform Super Admin choose which company they are acting within
# (sticky/persisted in the session). Used by the "Enter" action on the company
# list and the top-bar company switcher. Super admins only.
# See .kiro/specs/standard-productized-mode (Requirements 3.6, 4.7, 4.8).
class ActingCompaniesController < ApplicationController
  skip_authorization_check

  before_action :authorize_super_admin

  # POST /acting_company  — set (Enter / switch) the acting company.
  def create
    account = Account.active.find_by(id: params[:account_id])

    if account.nil?
      return redirect_back(fallback_location: root_path, alert: I18n.t('not_authorized'))
    end

    session[:acting_account_id] = account.id

    # Land on the company's home area, per the "Enter" flow.
    redirect_to root_path, notice: I18n.t('acting_as_company', company: account.name)
  end

  # DELETE /acting_company — stop acting as another company (back to own).
  def destroy
    session.delete(:acting_account_id)

    redirect_back(fallback_location: root_path)
  end

  private

  def authorize_super_admin
    return if current_user&.super_admin?

    redirect_to root_path, alert: I18n.t('not_authorized')
  end
end
