# frozen_string_literal: true

# WebhookNotifier Service
# Sends webhook notifications when submissions are completed
# Place this file in: app/services/webhook_notifier.rb

class WebhookNotifier
  def self.notify_completion(submission)
    return unless ENV['WEBHOOK_URL'].present?
    
    Rails.logger.info(" Preparing webhook for submission #{submission.id}")
    
    payload = build_payload(submission)
    
    # Send webhook in background thread to not block the request
    Thread.new do
      send_webhook(payload, submission.id)
    end
  end
  
  def self.build_payload(submission)
    {
      event: 'submission.completed',
      submission_id: submission.id,
      slug: submission.slug,
      template_id: submission.template_id,
      completed_at: Time.current.iso8601,
      submission_name: submission.name,
      submitters: submission.submitters.map do |submitter|
        {
          id: submitter.id,
          email: submitter.email,
          name: submitter.name,
          role: get_submitter_role(submission, submitter),
          completed_at: submitter.completed_at&.iso8601,
          declined_at: submitter.declined_at&.iso8601,
          status: submitter.status,
          values: submitter.values || {}
        }
      end,
      # Document URLs (valid for 7 days)
      audit_trail_url: submission.audit_trail_url(expires_at: 7.days.from_now),
      combined_document_url: submission.combined_document_url(expires_at: 7.days.from_now),
      # Additional metadata
      created_at: submission.created_at.iso8601,
      source: submission.source
    }
  end
  
  def self.get_submitter_role(submission, submitter)
    template_submitters = submission.template_submitters || []
    template_submitter = template_submitters.find { |ts| ts['uuid'] == submitter.uuid }
    template_submitter&.dig('name') || 'Signer'
  end
  
  def self.send_webhook(payload, submission_id)
    begin
      response = HTTParty.post(
        ENV['WEBHOOK_URL'],
        body: payload.to_json,
        headers: { 
          'Content-Type' => 'application/json',
          'X-Webhook-Secret' => ENV['WEBHOOK_SECRET'] || '',
          'User-Agent' => 'NexusSign-Webhook/1.0'
        },
        timeout: 15
      )
      
      if response.success?
        Rails.logger.info("Webhook sent successfully for submission #{submission_id}: HTTP #{response.code}")
      else
        Rails.logger.warn("Webhook returned non-success status for submission #{submission_id}: HTTP #{response.code}")
      end
    rescue HTTParty::Error => e
      Rails.logger.error("Webhook HTTP error for submission #{submission_id}: #{e.message}")
    rescue Timeout::Error => e
      Rails.logger.error("Webhook timeout for submission #{submission_id}: #{e.message}")
    rescue StandardError => e
      Rails.logger.error("Webhook failed for submission #{submission_id}: #{e.class} - #{e.message}")
    end
  end
end
