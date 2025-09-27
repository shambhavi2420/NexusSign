# frozen_string_literal: true

module Api
  class FormEventsController < ApiBaseController
    load_and_authorize_resource :submitter, parent: false

    def index
      submitters = @submitters.where.not(completed_at: nil)

      params[:after] = Time.zone.at(params[:after].to_i) if params[:after].present?
      params[:before] = Time.zone.at(params[:before].to_i) if params[:before].present?

      submitters = paginate(
        submitters.preload(template: { folder: :parent_folder },
                           submission: [:submitters, { audit_trail_attachment: :blob,
                                                       combined_document_attachment: :blob }],
                           documents_attachments: :blob, attachments_attachments: :blob),
        field: :completed_at
      )

      expires_at = Accounts.link_expires_at(current_account)

      render json: {
        data: submitters.map do |s|
                {
                  event_type: 'form.completed',
                  timestamp: s.completed_at,
                  data: Submitters::SerializeForWebhook.call(s, expires_at:)
                }
              end,
        pagination: {
          count: submitters.size,
          next: submitters.last&.completed_at&.to_i,
          prev: submitters.first&.completed_at&.to_i
        }
      }
    end
  end
end
