# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Submitters::CreateStampAttachment do
  let(:account)    { create(:account) }
  let(:author)     { create(:user, account:) }
  let(:template)   { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:) }
  let(:submitter)  { submission.submitters.first }

  before do
    submitter.update!(name: 'Jane Doe', email: 'jane@example.com', ip: '203.0.113.42',
                      completed_at: Time.current)
  end

  describe '.build_ip_line' do
    it 'renders the signer IP' do
      expect(described_class.build_ip_line(submitter)).to eq("\nIP: 203.0.113.42")
    end

    it 'is blank when no IP was captured' do
      submitter.update!(ip: nil)
      expect(described_class.build_ip_line(submitter)).to eq('')
    end
  end

  describe '.build_document_id_line' do
    it 'renders the Document ID (MD5 of the submission slug)' do
      expected_id = Digest::MD5.hexdigest(submission.slug).upcase

      line = described_class.build_document_id_line(submitter)
      expect(line).to include('Document ID:')
      expect(line).to include(expected_id)
    end
  end

  describe '.generate_stamp_image' do
    it 'builds a stamp image without error for a completed submitter' do
      expect { described_class.generate_stamp_image(submitter) }.not_to raise_error
    end
  end
end
