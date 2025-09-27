# frozen_string_literal: true

module Api
  class AttachmentsController < ActionController::API
    include ActionController::Cookies
    include ActiveStorage::SetCurrent

    COOKIE_STORE_LIMIT = 10

    def create
      submitter = Submitter.find_by!(slug: params[:submitter_slug])

      if params[:type].in?(%w[initials signature])
        image = Vips::Image.new_from_file(params[:file].path)

        if ImageUtils.blank?(image)
          Rollbar.error("Empty signature: #{submitter.id}") if defined?(Rollbar)

          return render json: { error: "#{params[:type]} is empty" }, status: :unprocessable_content
        end

        if ImageUtils.error?(image)
          Rollbar.error("Error signature: #{submitter.id}") if defined?(Rollbar)

          return render json: { error: "#{params[:type]} error, try to sign on another device" },
                        status: :unprocessable_content
        end
      end

      attachment = Submitters.create_attachment!(submitter, params)

      if params[:remember_signature] == 'true' && submitter.email.present?
        cookies.encrypted[:signature_uuids] = build_new_cookie_signatures_json(submitter, attachment)
      end

      render json: attachment.as_json(only: %i[uuid created_at], methods: %i[url filename content_type])
    end

    def build_new_cookie_signatures_json(submitter, attachment)
      values =
        begin
          JSON.parse(cookies.encrypted[:signature_uuids].presence || '{}')
        rescue JSON::ParserError
          {}
        end

      values[submitter.email] = attachment.uuid

      values = values.to_a.last(COOKIE_STORE_LIMIT).to_h if values.size > COOKIE_STORE_LIMIT

      values.to_json
    end
  end
end
