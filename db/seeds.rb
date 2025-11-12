# Create OAuth client
app = Doorkeeper::Application.find_or_create_by!(name: "Production Client") do |a|
  a.redirect_uri = ""
  a.scopes = ""
end
puts "=" * 50
puts "Client ID: #{app.uid}"
puts "Client Secret: #{app.secret}"
puts "=" * 50

# Create test user (adjust fields based on your User model)
User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.first_name = 'Admin'
  u.last_name = 'User'
  u.role = 'admin'
  u.password = 'SecurePassword123!'
  u.password_confirmation = 'SecurePassword123!'
  u.account_id = Account.first&.id || Account.create!(name: 'Default').id
end
puts "Test user created: admin@example.com"
