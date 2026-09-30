# frozen_string_literal: true

require 'rails_helper'

# End-to-end: a PLAIN signature field (with_signature_id off, no reason) must
# still render the identity stamp with IP + Document ID on the completed PDF.
RSpec.describe Submissions::GenerateResultAttachments, 'signature stamp always renders' do
  let(:account)  { create(:account) }
  let(:author)   { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[signature]) }
  let(:submission) { create(:submission, :with_submitters, template:) }
  let(:submitter)  { submission.submitters.first }

  before do
    create(:encrypted_config, account:, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
  end

  # A tiny 1x1 PNG used as the signature image.
  let(:png_bytes) do
    Base64.decode64(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
    )
  end

  def sign_and_render
    signature_field = template.fields.find { |f| f['type'] == 'signature' }

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(png_bytes), filename: 'signature.png', content_type: 'image/png'
    )
    attachment = ActiveStorage::Attachment.create!(blob:, name: 'attachments', record: submitter)

    submitter.update!(
      name: 'Jane Doe',
      email: 'jane@example.com',
      ip: '203.0.113.42',
      completed_at: Time.current,
      values: { signature_field['uuid'] => attachment.uuid }
    )

    described_class.call(submitter)
    submitter.reload.documents_attachments.first
  end

  def pdf_text(attachment)
    require 'pdf-reader'
    io = StringIO.new(attachment.download)
    PDF::Reader.new(io).pages.map(&:text).join("\n")
  end

  it 'renders IP and Document ID on a plain signature (account setting off)' do
    # Sanity: the account has no with_signature_id config and the field is plain.
    expect(account.account_configs.find_by(key: AccountConfig::WITH_SIGNATURE_ID)).to be_nil
    signature_field = template.fields.find { |f| f['type'] == 'signature' }
    expect(signature_field['preferences']).to eq({})

    doc = sign_and_render
    text = pdf_text(doc)

    expect(text).to include('IP: 203.0.113.42')
    # The Document ID value (MD5 of the submission slug) appears on the stamp.
    expect(text).to include(Digest::MD5.hexdigest(submission.slug).upcase)
  end

  it 'omits the stamp when the field explicitly opts out (with_signature_id: false)' do
    signature_field = template.fields.find { |f| f['type'] == 'signature' }
    signature_field['preferences'] = { 'with_signature_id' => false }
    template.save!

    doc = sign_and_render
    text = pdf_text(doc)

    expect(text).not_to include('IP: 203.0.113.42')
  end
end
