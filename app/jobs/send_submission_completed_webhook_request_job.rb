# frozen_string_literal: true

class SendSubmissionCompletedWebhookRequestJob
  include Sidekiq::Job
  sidekiq_options queue: :webhooks
  MAX_ATTEMPTS = 10

  def perform(params = {})
    submission = Submission.find(params['submission_id'])
    webhook_url = WebhookUrl.find(params['webhook_url_id'])
    attempt = params['attempt'].to_i

    return if webhook_url.url.blank? || webhook_url.events.exclude?('submission.completed')

    last_submitter = submission.submitters.where.not(completed_at: nil).max_by(&:completed_at)

    Submissions::EnsureResultGenerated.call(last_submitter)

    combined_pdf_data = build_combined_pdf_without_audit_trail(last_submitter)

    custom_data = {
      external_ids: last_submitter&.metadata&.dig('external_ids') || [],
      base64:       combined_pdf_data.present? ? Base64.strict_encode64(combined_pdf_data) : '',
      status:       'SIGNED'
    }

    resp = SendWebhookRequest.call(webhook_url,
                                   event_type: 'submission.completed',
                                   event_uuid: params['event_uuid'],
                                   record: submission,
                                   attempt: attempt,
                                   data: custom_data)

    if (resp.nil? || resp.status.to_i >= 400) && attempt <= MAX_ATTEMPTS &&
       (!Docuseal.multitenant? || submission.account.account_configs.exists?(key: :plan))
      SendSubmissionCompletedWebhookRequestJob.perform_in((2**attempt).minutes, {
                                                            **params,
                                                            'attempt' => attempt + 1,
                                                            'last_status' => resp&.status.to_i
                                                          })
    end
  end

  private

  def build_combined_pdf_without_audit_trail(submitter)
    documents = submitter.documents.preload(:blob).to_a
    return nil if documents.empty?
    return documents.first.blob.download if documents.size == 1

    combined = HexaPDF::Document.new

    documents.each do |doc|
      pdf = HexaPDF::Document.new(io: StringIO.new(doc.blob.download))
      pdf.pages.each { |page| combined.pages << combined.import(page) }
    end

    io = StringIO.new
    combined.write(io)
    io.string
  end
end
