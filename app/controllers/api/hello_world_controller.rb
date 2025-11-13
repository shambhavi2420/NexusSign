class Api::HelloWorldController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :maybe_redirect_to_setup
  skip_before_action :sign_in_for_demo
  skip_before_action :set_csp
  before_action :doorkeeper_authorize!
  skip_authorization_check

  def index
    begin
      respond_to do |format|
        format.html do
          render html: <<-HTML.html_safe
            <h1>Protected Page</h1>
            <p>Welcome, your token is valid!</p>
          HTML
        end

        format.json do
          render json: { message: "Hello, #{current_resource_owner.email}!" }
        end
      end

    rescue Doorkeeper::Errors::InvalidToken, Doorkeeper::Errors::TokenExpired
      respond_to do |format|
        format.html do
          render html: <<-HTML.html_safe, status: :unauthorized
            <script>
              console.log("TOKEN_EXPIRED");
              window.parent.postMessage(
                { type: 'TOKEN_EXPIRED', message: 'Access token expired' },
                'https://sf-new-uat.laboredge.com/'
              );
            </script>
          HTML
        end

        format.json do
          render json: { error: 'TOKEN_EXPIRED', message: 'Access token expired' }, status: :unauthorized
        end
      end
    end
  end

  private

  def current_resource_owner
    @current_resource_owner ||= User.find(doorkeeper_token.resource_owner_id) if doorkeeper_token
  end
end
