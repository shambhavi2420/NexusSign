# frozen_string_literal: true

require 'rails_helper'

describe 'Custom Submissions API (POST /api/submissions/custom_submissions)' do
  let(:account) { create(:account) }
  let(:author)  { create(:user, account:) }
  let(:token)   { author.access_token.token }

  def pdf_base64
    require 'hexapdf'
    doc = HexaPDF::Document.new
    doc.pages.add.canvas.tap { |c| c.font('Helvetica', size: 12); c.text('Body text', at: [72, 700]) }
    io = StringIO.new
    doc.write(io)
    Base64.strict_encode64(io.string)
  end

  def post_custom(body)
    post '/api/submissions/custom_submissions',
         params: body.to_json,
         headers: { 'x-auth-token': token, 'CONTENT_TYPE': 'application/json' }
  end

  it 'requires pdf_base64' do
    post_custom(submitters: [{ email: 'a@example.com', role: 'Signer 1' }])

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body['error']).to match(/pdf_base64/)
  end

  it 'draws one signature box per submitter (no separate date field) and returns the submitter array' do
    post_custom(
      pdf_base64: pdf_base64,
      filename: 'Doc.pdf',
      submitters: [
        { email: 's1@example.com', role: 'Signer 1' },
        { email: 's2@example.com', role: 'Signer 2' }
      ]
    )

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.size).to eq(2)

    template = Template.last
    expect(template.folder.name).to eq('Custom Requests')

    types = template.fields.map { |f| f['type'] }
    expect(types.count('signature')).to eq(2)
    # No date field on the custom submissions path: the final navy signature box
    # renders the E-Signed date itself, so a separate date field would duplicate it.
    expect(types.count('date')).to eq(0)
  end
end
