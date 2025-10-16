class IframePagesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  content_security_policy false
  def show
    token = params[:my_token]
    if token.blank? || token != "96C7LLklRlvXLx3CxBF4UG2ycroGP24ktX"
      head :unauthorized
      return
    end
    # View will render if token is correct
  end
end
