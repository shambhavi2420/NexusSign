# frozen_string_literal: true

# Platform Super Admin company management: list, create (Account + first Company
# Admin), and archive/unarchive companies for the productized deployment.
# See .kiro/specs/standard-productized-mode (Requirement 4).
class CompaniesController < ApplicationController
  skip_authorization_check

  before_action :authorize_super_admin

  def index
    @companies = Account.order(:name)
  end

  def new
    @company = Account.new
    @admin = User.new
  end

  def create
    @company = Account.new(company_params)
    @company.timezone = Accounts.normalize_timezone(@company.timezone.presence || 'UTC')
    @company.locale = @company.locale.presence || 'en-US'

    @admin = @company.users.new(admin_params)
    @admin.role = User::ADMIN_ROLE
    @admin.password = SecureRandom.hex if @admin.password.blank?

    if @company.valid? && @admin.save
      # Initialize the company's default folder (lazy creator on Account).
      @company.default_template_folder

      UserMailer.invitation_email(@admin).deliver_later!

      redirect_to companies_path, notice: I18n.t('company_has_been_created')
    else
      # Surface whichever record failed.
      @company.valid?
      render :new, status: :unprocessable_content
    end
  end

  # PATCH /companies/:id/archive
  def archive
    company = Account.find(params[:id])
    company.update!(archived_at: Time.current)

    # If the super admin was acting inside this company, drop that context.
    session.delete(:acting_account_id) if session[:acting_account_id] == company.id

    redirect_to companies_path, notice: I18n.t('company_has_been_archived')
  end

  # PATCH /companies/:id/unarchive
  def unarchive
    company = Account.find(params[:id])
    company.update!(archived_at: nil)

    redirect_to companies_path, notice: I18n.t('company_has_been_restored')
  end

  private

  def authorize_super_admin
    return if current_user&.super_admin?

    redirect_to root_path, alert: I18n.t('not_authorized')
  end

  def company_params
    params.require(:account).permit(:name, :timezone, :locale)
  end

  def admin_params
    params.require(:admin).permit(:first_name, :last_name, :email)
  end
end
