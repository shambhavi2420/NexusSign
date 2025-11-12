class IframePagesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  content_security_policy false

  before_action :validate_token

  def show
    # Renders app/views/iframe_pages/show.html.erb
  end

  def edit_template
    # Renders app/views/iframe_pages/auto_sign.html.erb
  end

  def create_template
    # Renders app/views/iframe_pages/create_template.html.erb
  end

  private

  def validate_token
    token = params[:my_token]
    template_name = params[:template_name]
    folder_name = params[:folder_name]
    valid_token = "96C7LLklRlvXLx3CxBF4UG2ycroGP24ktX"

    if token.blank? || token != valid_token
      head :unauthorized
    end
  end
end
