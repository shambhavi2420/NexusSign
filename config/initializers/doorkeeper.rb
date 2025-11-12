Doorkeeper.configure do
  orm :active_record
  
  resource_owner_from_credentials do |routes|
    user = User.find_for_database_authentication(email: params[:username])
    user if user&.valid_password?(params[:password])
  end
  
  grant_flows %w[password]
  use_refresh_token
  access_token_expires_in 2.hours
end
