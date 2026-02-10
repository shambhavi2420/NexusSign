# frozen_string_literal: true
# == Schema Information
#
# Table name: submitters
#
#  id            :bigint           not null, primary key
#  completed_at  :datetime
#  declined_at   :datetime
#  email         :string
#  ip            :string
#  metadata      :text             not null
#  name          :string
#  opened_at     :datetime
#  phone         :string
#  preferences   :text             not null
#  sent_at       :datetime
#  slug          :string           not null
#  timezone      :string
#  ua            :string
#  uuid          :string           not null
#  values        :text             not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#  external_id   :string
#  submission_id :bigint           not null
#
# Indexes
#
#  index_submitters_on_account_id_and_id            (account_id,id)
#  index_submitters_on_completed_at_and_account_id  (completed_at,account_id)
#  index_submitters_on_email                        (email)
#  index_submitters_on_external_id                  (external_id)
#  index_submitters_on_slug                         (slug) UNIQUE
#  index_submitters_on_submission_id                (submission_id)
#
# Foreign Keys
#
#  fk_rails_...  (submission_id => submissions.id)
#
class Submitter < ApplicationRecord
  belongs_to :submission
  belongs_to :account
  has_one :template, through: :submission
  has_one :search_entry, as: :record, inverse_of: :record, dependent: :destroy if SearchEntry.table_exists?

  attribute :values, :string, default: -> { {} }
  attribute :preferences, :string, default: -> { {} }
  attribute :metadata, :string, default: -> { {} }
  attribute :slug, :string, default: -> { SecureRandom.base58(14) }

  serialize :values, coder: JSON
  serialize :preferences, coder: JSON
  serialize :metadata, coder: JSON

  has_many_attached :documents
  has_many_attached :attachments
  has_many_attached :preview_documents

  has_many :template_accesses, through: :submission
  has_many :email_events, as: :emailable, dependent: (Docuseal.multitenant? ? nil : :destroy)
  has_many :document_generation_events, dependent: :destroy
  has_many :submission_events, dependent: :destroy
  has_many :start_form_submission_events, -> { where(event_type: :start_form) },
           class_name: 'SubmissionEvent', dependent: :destroy, inverse_of: :submitter

  scope :completed, -> { where.not(completed_at: nil) }

  after_destroy :anonymize_email_events, if: -> { Docuseal.multitenant? }

  # 🎯 WEBHOOK TRIGGER - Calls your API when document is signed
  after_update :notify_webhook_if_all_completed

  def status
    if declined_at?
      'declined'
    elsif completed_at?
      'completed'
    elsif opened_at?
      'opened'
    elsif sent_at?
      'sent'
    else
      'awaiting'
    end
  end

  def application_key
    external_id
  end

  def friendly_name
    if name.present? && email.present? && email.exclude?(',')
      %("#{name.delete('"')}" <#{email}>)
    else
      email
    end
  end

  def first_name
    name&.split(/\s+/, 2)&.first
  end

  def last_name
    name&.split(/\s+/, 2)&.last
  end

  def status_event_at
    declined_at || completed_at || opened_at || sent_at || created_at
  end

  def with_signature_fields?
    @with_signature_fields ||= begin
      fields = submission.template_fields || template.fields
      signature_field_types = %w[signature initials]
      fields.any? { |f| f['submitter_uuid'] == uuid && signature_field_types.include?(f['type']) }
    end
  end

  private

  def anonymize_email_events
    email_events.each do |event|
      event.update!(email: Digest::MD5.base64digest(event.email))
    end
  end

  # WEBHOOK NOTIFICATION METHOD
  # This triggers when a submitter completes signing
  # It checks if ALL submitters are done, then calls your webhook
  def notify_webhook_if_all_completed
    # Only trigger if this submitter just completed (changed from nil to a timestamp)
    return unless saved_change_to_completed_at? && completed_at.present?

    # Reload submission to get fresh submitter data
    submission.reload

    # Check if ALL submitters for this submission have completed
    all_completed = submission.submitters.all? { |s| s.completed_at.present? }

    if all_completed
      Rails.logger.info("All submitters completed for submission #{submission.id} - triggering webhook")
      
      # Find all webhook URLs for this account that listen to submission.completed
      WebhookUrl.where(account_id: submission.account_id)
                .where("events @> ?", ['submission.completed'].to_json)
                .find_each do |webhook_url|
        SendSubmissionCompletedWebhookRequestJob.perform_async({
          'submission_id' => submission.id,
          'webhook_url_id' => webhook_url.id,
          'event_uuid' => SecureRandom.uuid,
          'attempt' => 0
        })
      end
    else
      pending_count = submission.submitters.count { |s| s.completed_at.blank? }
      Rails.logger.info("⏳ Submission #{submission.id} partially complete - #{pending_count} submitter(s) still pending")
    end
  rescue StandardError => e
    Rails.logger.error("Webhook notification failed for submission #{submission.id}: #{e.class} - #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
  end
end
