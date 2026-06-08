# frozen_string_literal: true

class ProcessSubmissionExpiredJob
  include Sidekiq::Job

  def perform(params = {})
    submission = Submission.find(params['submission_id'])

    return if submission.archived_at?
    return if submission.template&.archived_at?
    return if submission.submitters.where.not(declined_at: nil).exists?
    return unless submission.submitters.exists?(completed_at: nil)

    WebhookUrls.enqueue_events(submission, 'submission.expired')

    enqueue_expired_notification_email(submission)
  end

  private

  def enqueue_expired_notification_email(submission)
    user = submission.created_by_user || submission.template&.author

    return unless user
    return unless submission.account.users.exists?(id: user.id)
    return if user.user_configs.find_by(key: UserConfig::RECEIVE_EXPIRED_EMAIL)&.value == false
    return if submission.template&.preferences&.dig('expired_notification_email_enabled') == false

    SubmitterMailer.expired_email(submission, user).deliver_later!
  end
end
