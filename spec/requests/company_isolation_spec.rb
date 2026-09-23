# frozen_string_literal: true

require 'rails_helper'

# Isolation harness for the logical company partition (Requirement 2).
# A user in Company A must never read, update, or delete Company B's records by
# id/slug/uuid. Isolation is enforced by CanCanCan account_id scoping
# (lib/ability.rb) via load_and_authorize_resource / accessible_by.
#
# These specs exercise the JSON API so we assert on clean HTTP status codes
# without depending on the (webpack-compiled) HTML layout.
describe 'Company isolation', type: :request do
  let(:company_a) { create(:account, name: 'Company A') }
  let(:company_b) { create(:account, name: 'Company B') }

  let(:admin_a) { create(:user, account: company_a, role: 'admin') }
  let(:admin_b) { create(:user, account: company_b, role: 'admin') }

  # Company B's records — the ones Company A must not reach.
  let(:folder_b) { create(:template_folder, account: company_b, author: admin_b) }
  let(:template_b) do
    create(:template, account: company_b, author: admin_b, folder: folder_b, attachment_count: 0)
  end

  def auth(user)
    { 'x-auth-token': user.access_token.token }
  end

  describe 'reading another company\'s template' do
    it 'forbids GET /api/templates/:id for a cross-company user' do
      get "/api/templates/#{template_b.id}", headers: auth(admin_a)

      expect(response).to have_http_status(:forbidden)
    end

    it 'allows the owning company to read its own template' do
      get "/api/templates/#{template_b.id}", headers: auth(admin_b)

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'listing templates' do
    it 'never includes another company\'s templates' do
      template_b # create it

      get '/api/templates', headers: auth(admin_a)

      expect(response).to have_http_status(:ok)
      ids = response.parsed_body['data'].map { |t| t['id'] }
      expect(ids).not_to include(template_b.id)
    end
  end

  describe 'updating another company\'s template' do
    it 'forbids PUT /api/templates/:id for a cross-company user' do
      put "/api/templates/#{template_b.id}",
          params: { name: 'Hijacked' }.to_json,
          headers: auth(admin_a).merge('Content-Type' => 'application/json')

      expect(response).to have_http_status(:forbidden)
      expect(template_b.reload.name).not_to eq('Hijacked')
    end
  end

  describe 'archiving (deleting) another company\'s template' do
    it 'forbids DELETE /api/templates/:id for a cross-company user' do
      template_b

      delete "/api/templates/#{template_b.id}", headers: auth(admin_a)

      expect(response).to have_http_status(:forbidden)
      expect(template_b.reload.archived_at).to be_nil
    end
  end

  describe 'listing folders' do
    it 'never includes another company\'s folders' do
      folder_b

      get '/api/folders', headers: auth(admin_a)

      # Endpoint returns folders scoped to the caller's account; Company B's
      # folder must not appear regardless of the exact payload shape.
      expect(response.body).not_to include(folder_b.name)
    end
  end
end
