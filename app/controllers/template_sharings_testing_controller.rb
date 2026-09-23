# frozen_string_literal: true

class TemplateSharingsTestingController < ApplicationController
  load_and_authorize_resource :template, parent: true

  # Testing/linked-account sharing is a cross-company door, disabled in Standard
  # Mode. See .kiro/specs/standard-productized-mode (Requirement 5.1).
  before_action :ensure_cross_account_sharing_allowed

  before_action do
    authorize!(:manage, TemplateSharing.new(template: @template))
  end

  def create
    testing_account = Accounts.find_or_create_testing_user(true_user.account).account

    if params[:value] == '1'
      TemplateSharing.create!(ability: :manage, account: testing_account, template: @template)
    else
      TemplateSharing.find_by(template: @template, account: testing_account)&.destroy!
    end

    head :ok
  end

  private

  def ensure_cross_account_sharing_allowed
    head :forbidden unless Docuseal.cross_account_sharing_allowed?(true_user.account)
  end
end
