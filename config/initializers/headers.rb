# config/initializers/headers.rb
Rails.application.config.action_dispatch.default_headers.merge!({
  'X-Frame-Options' => 'ALLOWALL'
})
