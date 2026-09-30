# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Submissions::GenerateResultAttachments, '.build_signature_stamp_text' do
  let(:account)    { create(:account) }
  let(:author)     { create(:user, account:) }
  let(:template)   { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:) }
  let(:submitter)  { submission.submitters.first }

  # A lightweight stand-in for the signature attachment (only created_at is used).
  let(:attachment) { Struct.new(:created_at).new(Time.current) }

  before do
    submitter.update!(name: 'Jane Doe', email: 'jane@example.com', ip: '203.0.113.42')
  end

  def stamp_text(with_reason: true)
    described_class.build_signature_stamp_text(
      submitter, attachment, nil, account.locale,
      with_signature_id_reason: with_reason, with_submitter_timezone: false
    )
  end

  it 'includes the signer IP line' do
    expect(stamp_text).to include('IP: 203.0.113.42')
  end

  it 'includes the Document ID line with the MD5-of-slug value' do
    expected_id = Digest::MD5.hexdigest(submission.slug).upcase

    text = stamp_text
    expect(text).to include('Document ID:')
    expect(text).to include(expected_id)
  end

  it 'still includes the name/email reason line' do
    expect(stamp_text).to include('Jane Doe')
    expect(stamp_text).to include('<jane@example.com>')
  end

  it 'omits the IP line when no IP was captured' do
    submitter.update!(ip: nil)

    text = stamp_text
    expect(text).not_to include('IP:')
    # Document ID must still be present.
    expect(text).to include('Document ID:')
  end

  it 'includes IP and Document ID even without the reason line' do
    text = stamp_text(with_reason: false)

    expect(text).to include('IP: 203.0.113.42')
    expect(text).to include('Document ID:')
    # No "digitally signed by" reason line in this mode.
    expect(text).not_to include('Jane Doe')
  end
end
