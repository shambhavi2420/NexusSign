# frozen_string_literal: true

require 'rails_helper'

# Cross-account doors (linked/testing accounts, share-to-all) must be disabled
# in Standard Mode (Requirement 5).
describe 'Cross-account doors in Standard Mode', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, role: 'admin') }

  describe 'Docuseal.cross_account_sharing_allowed?' do
    after { Docuseal.reset_product_mode! }

    it 'is false in standard mode' do
      allow(Docuseal).to receive(:standard_mode?).and_return(true)
      expect(Docuseal.cross_account_sharing_allowed?).to be(false)
    end

    it 'is true in healthcare mode' do
      allow(Docuseal).to receive(:standard_mode?).and_return(false)
      expect(Docuseal.cross_account_sharing_allowed?).to be(true)
    end
  end

  describe 'GET /testing_account (impersonate testing account)' do
    before { sign_in(admin) }

    context 'in standard mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(true) }

      it 'is blocked' do
        get '/testing_account'

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe 'POST /templates/:template_id/template_sharings_testing' do
    before { sign_in(admin) }

    let(:template) { create(:template, account:, author: admin, attachment_count: 0) }

    context 'in standard mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(true) }

      it 'is forbidden' do
        post '/template_sharings_testing', params: { template_id: template.id, value: '1' }

        expect(response).to have_http_status(:forbidden)
        expect(TemplateSharing.where(template:).count).to eq(0)
      end
    end
  end
end
