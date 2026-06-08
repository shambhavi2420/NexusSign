# frozen_string_literal: true

module Api
  class SubmitterFormViewsController < ApiBaseController
    skip_before_action :authenticate_user!
    skip_authorization_check

    def create
      @submitter = Submitter.find_by!(slug: params[:submitter_slug])

      @submitter.opened_at = Time.current
      @submitter.save

      SubmissionEvents.create_with_tracking_data(@submitter, 'view_form', request)

      WebhookUrls.enqueue_events(@submitter, 'form.viewed')

      enqueue_viewed_notification_email(@submitter)

      render json: {}
    end

    private

    def enqueue_viewed_notification_email(submitter)
      user = submitter.submission.created_by_user || submitter.template&.author

      return unless user
      return unless submitter.account.users.exists?(id: user.id)

      template = submitter.template
      return if template && template.preferences['viewed_notification_email_enabled'] == false
      return unless user.user_configs.find_by(key: UserConfig::RECEIVE_VIEWED_EMAIL)&.value == true ||
                    template&.preferences&.dig('viewed_notification_email_enabled') == true

      SubmitterMailer.viewed_email(submitter, user).deliver_later!
    end
  end
end
