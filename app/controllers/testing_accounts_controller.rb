# frozen_string_literal: true

class TestingAccountsController < ApplicationController
  skip_authorization_check only: :destroy

  # Impersonating a testing account is a cross-company door, disabled in
  # Standard Mode. See .kiro/specs/standard-productized-mode (Requirement 5.1).
  before_action :ensure_cross_account_sharing_allowed, only: :show

  def show
    authorize!(:manage, current_account)
    authorize!(:manage, current_user)

    impersonate_user(Accounts.find_or_create_testing_user(true_user.account))

    redirect_back(fallback_location: root_path)
  end

  def destroy
    stop_impersonating_user

    redirect_back(fallback_location: root_path)
  end

  private

  def ensure_cross_account_sharing_allowed
    return if Docuseal.cross_account_sharing_allowed?(current_account)

    redirect_back(fallback_location: root_path, alert: I18n.t('not_authorized'))
  end
end
