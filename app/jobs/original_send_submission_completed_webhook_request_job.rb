# frozen_string_literal: true
class OriginalSendSubmissionCompletedWebhookRequestJob
  include Sidekiq::Job
  sidekiq_options queue: :webhooks
  MAX_ATTEMPTS = 10

  def perform(params = {})
    submission = Submission.find(params['submission_id'])
    webhook_url = WebhookUrl.find(params['webhook_url_id'])
    attempt = params['attempt'].to_i

    return if webhook_url.url.blank? || webhook_url.events.exclude?('submission.completed')

    # Get the signed document from the last completed submitter
    last_submitter = submission.submitters.where.not(completed_at: nil).max_by(&:completed_at)
    signed_doc = last_submitter&.documents&.first

    serialized = Submissions::SerializeForApi.call(submission)

    # Remove audit log URLs - we only want the clean signed document
    serialized.delete('combined_document_url')
    serialized.delete('audit_log_url')

    # Attach signed document as base64 directly in payload
    if signed_doc
      serialized['signed_document'] = {
        'filename' => signed_doc.filename.to_s,
        'content_type' => signed_doc.blob.content_type,
        'base64' => Base64.strict_encode64(signed_doc.blob.download)
      }
    end

    # Enrich each submitter with metadata and external_ids
    submitters_by_id = submission.submitters.index_by(&:id)
    serialized['submitters']&.each do |submitter_json|
      submitter = submitters_by_id[submitter_json['id']]
      next unless submitter

      submitter_json['metadata']     = submitter.metadata
      submitter_json['external_ids'] = submitter.metadata&.dig('external_ids') || []
      submitter_json['external_id']  = submitter.external_id
    end

    resp = SendWebhookRequest.call(webhook_url,
                                   event_type: 'submission.completed',
                                   event_uuid: params['event_uuid'],
                                   record: submission,
                                   attempt: attempt,
                                   data: serialized)

    if (resp.nil? || resp.status.to_i >= 400) && attempt <= MAX_ATTEMPTS &&
       (!Docuseal.multitenant? || submission.account.account_configs.exists?(key: :plan))
      OriginalSendSubmissionCompletedWebhookRequestJob.perform_in((2**attempt).minutes, {
                                                            **params,
                                                            'attempt' => attempt + 1,
                                                            'last_status' => resp&.status.to_i
                                                          })
    end
  end
end
