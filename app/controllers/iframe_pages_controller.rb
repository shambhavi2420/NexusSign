class IframePagesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  content_security_policy false

  before_action :doorkeeper_authorize!

  def show
    begin
      respond_to do |format|
        format.html # renders app/views/iframe_pages/show.html.erb
        format.json { render json: { message: "Hello, #{current_resource_owner.email}!" } }
      end
    rescue Doorkeeper::Errors::InvalidToken, Doorkeeper::Errors::TokenExpired
      handle_token_expired
    end
  end

  def edit_template
    begin
      render # will render app/views/iframe_pages/edit_template.html.erb
    rescue Doorkeeper::Errors::InvalidToken, Doorkeeper::Errors::TokenExpired
      handle_token_expired
    end
  end

  def create_template
    begin
      render # will render app/views/iframe_pages/create_template.html.erb
    rescue Doorkeeper::Errors::InvalidToken, Doorkeeper::Errors::TokenExpired
      handle_token_expired
    end
  end

  private

  def handle_token_expired
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

  def current_resource_owner
    @current_resource_owner ||= User.find(doorkeeper_token.resource_owner_id) if doorkeeper_token
  end
end
