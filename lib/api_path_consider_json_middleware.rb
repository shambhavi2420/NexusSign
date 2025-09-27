# frozen_string_literal: true

class ApiPathConsiderJsonMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    if env['PATH_INFO'].starts_with?('/api') &&
       (!env['PATH_INFO'].ends_with?('/documents') || env['REQUEST_METHOD'] != 'POST') &&
       !env['PATH_INFO'].ends_with?('/attachments') &&
       !env['PATH_INFO'].ends_with?('/submitter_sms_clicks') &&
       !env['PATH_INFO'].ends_with?('/submitter_email_clicks')
      env['CONTENT_TYPE'] = 'application/json'
    end

    @app.call(env)
  end
end
