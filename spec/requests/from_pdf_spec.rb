# frozen_string_literal: true

require 'rails_helper'

describe 'From PDF API (POST /api/submissions/from_pdf)' do
  let(:account) { create(:account) }
  let(:author)  { create(:user, account:) }
  let(:token)   { author.access_token.token }

  # Builds a one-page PDF with the given text lines and returns it base64-encoded.
  def pdf_base64(lines)
    require 'hexapdf'

    doc    = HexaPDF::Document.new
    canvas = doc.pages.add.canvas
    canvas.font('Helvetica', size: 12)
    y = 720
    lines.each do |line|
      canvas.text(line, at: [72, y])
      y -= 40
    end

    io = StringIO.new
    doc.write(io)
    Base64.strict_encode64(io.string)
  end

  def post_from_pdf(body)
    post '/api/submissions/from_pdf',
         params: body.to_json,
         headers: { 'x-auth-token': token, 'CONTENT_TYPE': 'application/json' }
  end

  describe 'validation' do
    it 'requires pdf_base64' do
      post_from_pdf(submitters: [{ email: 'a@example.com', role: 'Signer 1' }])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/pdf_base64/)
    end

    it 'requires submitters' do
      post_from_pdf(pdf_base64: pdf_base64(['${Signature}']))

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/submitters/)
    end

    it 'requires each submitter to have an email' do
      post_from_pdf(pdf_base64: pdf_base64(['${Signature}']),
                    submitters: [{ role: 'Signer 1' }])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/email/)
    end

    it 'requires each submitter to have a role' do
      post_from_pdf(pdf_base64: pdf_base64(['${Signature}']),
                    submitters: [{ email: 'a@example.com' }])

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body['error']).to match(/role/)
    end
  end

  describe 'tag-based PDF, single submitter' do
    it 'creates a submission and returns the standardized submitter array' do
      post_from_pdf(
        pdf_base64: pdf_base64(['${CandidateFullName}', '${Signature}', '${SignatureDate}']),
        filename:   'Offer.pdf',
        submitters: [{ email: 'jane@example.com', role: 'Signer 1', name: 'Jane Doe' }]
      )

      expect(response).to have_http_status(:created)

      body = response.parsed_body
      expect(body).to be_an(Array)
      expect(body.size).to eq(1)
      expect(body.first['email']).to eq('jane@example.com')
      expect(body.first['role']).to eq('Signer 1')
      expect(body.first).to have_key('embed_src')

      template = Template.last
      expect(template.folder.name).to eq('Tag Based Requests')
      expect(template.fields.size).to eq(3)
      # All roleless tags bound to the single submitter.
      submitter_uuid = template.submitters.first['uuid']
      expect(template.fields.map { |f| f['submitter_uuid'] }.uniq).to eq([submitter_uuid])
    end
  end

  describe 'tag-based PDF, multiple submitters with roles' do
    it 'binds each field to the submitter matching the tag role' do
      post_from_pdf(
        pdf_base64: pdf_base64(['${Signature;role=Signer 1}', '${Signature;role=Signer 2}']),
        submitters: [
          { email: 's1@example.com', role: 'Signer 1' },
          { email: 's2@example.com', role: 'Signer 2' }
        ]
      )

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.size).to eq(2)

      template = Template.last
      submitters_by_role = template.submitters.index_by { |s| s['name'] }
      fields_by_role = template.fields.group_by { |f| f['submitter_uuid'] }

      expect(fields_by_role[submitters_by_role['Signer 1']['uuid']].size).to eq(1)
      expect(fields_by_role[submitters_by_role['Signer 2']['uuid']].size).to eq(1)
    end
  end

  describe 'tag-based PDF, multiple submitters but roleless tags' do
    it 'returns 422 listing the tags that need a role' do
      post_from_pdf(
        pdf_base64: pdf_base64(['${Signature}', '${CandidateFullName}']),
        submitters: [
          { email: 's1@example.com', role: 'Signer 1' },
          { email: 's2@example.com', role: 'Signer 2' }
        ]
      )

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to match(/without a role/)
      expect(response.parsed_body['error']).to match(/Signature/)
    end
  end

  describe 'PDF with no tags at all' do
    it 'falls back to drawing signature boxes for each submitter' do
      post_from_pdf(
        pdf_base64: pdf_base64(['This document has no tags whatsoever.']),
        submitters: [
          { email: 's1@example.com', role: 'Signer 1' },
          { email: 's2@example.com', role: 'Signer 2' }
        ]
      )

      expect(response).to have_http_status(:created)
      expect(response.parsed_body.size).to eq(2)

      template = Template.last
      # One signature + one date field per submitter.
      types = template.fields.map { |f| f['type'] }
      expect(types.count('signature')).to eq(2)
      expect(types.count('date')).to eq(2)
    end
  end
end
