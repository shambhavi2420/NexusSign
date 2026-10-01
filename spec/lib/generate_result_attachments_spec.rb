# frozen_string_literal: true

require 'rails_helper'

# Text-extracting content processor: collects every drawn glyph run so specs can
# assert on the text baked into a generated PDF.
class ResultPdfTextCollector < HexaPDF::Content::Processor
  attr_reader :text

  def initialize(*)
    super
    @text = +''
  end

  def show_text(str)
    @text << decode_text(str)
  end

  def show_text_with_positioning(arr)
    @text << decode_text_with_positioning(arr)
  end
end

RSpec.describe Submissions::GenerateResultAttachments do
  let(:account)    { create(:account) }
  let(:author)     { create(:user, account:) }
  let(:template)   { create(:template, account:, author:, only_field_types: %w[signature]) }
  let(:submission) { create(:submission, :with_submitters, template:) }
  let(:submitter)  { submission.submitters.first }

  # Attaches the sample image as the submitter's signature and points the
  # signature field value at that attachment uuid, so the signature-id branch
  # that draws the electronic signature box is exercised.
  def attach_signature!
    signature_field = submission.template_fields.find { |f| f['type'] == 'signature' }

    blob = ActiveStorage::Blob.create_and_upload!(
      io: Rails.root.join('spec/fixtures/sample-image.png').open,
      filename: 'signature.png',
      content_type: 'image/png'
    )

    attachment = ActiveStorage::Attachment.create!(blob:, name: :attachments, record: submitter)

    submitter.update!(values: { signature_field['uuid'] => attachment.uuid },
                      completed_at: Time.current)

    attachment
  end

  def generate_result_pdf(submitter)
    attachments = described_class.call(submitter)

    attachments.find { |a| a.blob.content_type == 'application/pdf' }
  end

  def extract_text(pdf_attachment)
    doc = HexaPDF::Document.new(io: StringIO.new(pdf_attachment.blob.download))

    doc.pages.each_with_object(+'') do |page, acc|
      processor = ResultPdfTextCollector.new
      page.process_contents(processor)
      acc << processor.text
    end
  end

  before do
    submitter.update!(name: 'Jane Q Signer', email: 'jane@example.com', ip: '203.0.113.42')
    create(:account_config, account:, key: AccountConfig::WITH_SIGNATURE_ID, value: true)
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
    attach_signature!
  end

  it 'renders the email, DocID and IP in the electronic signature box' do
    text = extract_text(generate_result_pdf(submitter))

    # The signer name is intentionally NOT shown — the signature image is the
    # focal element.
    expect(text).not_to include('Jane Q Signer')
    expect(text).to include('jane@example.com')
    expect(text).to include('DocID:')
    expect(text).to include(Digest::MD5.hexdigest(submission.slug).upcase)
    expect(text).to include('IP: 203.0.113.42')
    expect(text).to include('E-Signed:')
    expect(text).to include(PdfSignatureBoxes::ELECTRONIC_SIGNATURE_LABEL)
  end

  it 'omits the IP line when no IP was captured' do
    submitter.update!(ip: nil)

    text = extract_text(generate_result_pdf(submitter))

    expect(text).to include('jane@example.com')
    expect(text).not_to include('IP:')
  end

  context 'without the signature-id account config' do
    before { AccountConfig.where(account:, key: AccountConfig::WITH_SIGNATURE_ID).delete_all }

    it 'still renders the electronic signature box on a plain signature field' do
      text = extract_text(generate_result_pdf(submitter))

      expect(text).to include('jane@example.com')
      expect(text).to include('E-Signed:')
      expect(text).to include(PdfSignatureBoxes::ELECTRONIC_SIGNATURE_LABEL)
    end
  end
end
