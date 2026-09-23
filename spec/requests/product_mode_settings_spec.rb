# frozen_string_literal: true

require 'rails_helper'

describe 'ProductModeSettings', type: :request do
  let(:account) { create(:account) }
  let(:super_admin) { create(:user, account:, role: 'super_admin') }
  let(:admin) { create(:user, account:, role: 'admin') }

  after { Docuseal.reset_product_mode! }

  describe 'GET /settings/product_mode' do
    context 'when the user is a super admin' do
      before { sign_in(super_admin) }

      # Fully rendering the page requires compiled webpack assets (Shakapacker),
      # which aren't built in this environment. Stub the pack tag helpers so the
      # page renders and we can assert the super admin is authorized (HTTP 200).
      before do
        allow_any_instance_of(ActionView::Base).to receive(:javascript_pack_tag).and_return('')
        allow_any_instance_of(ActionView::Base).to receive(:stylesheet_pack_tag).and_return('')
      end

      it 'authorizes access and returns 200' do
        get '/settings/product_mode'

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the user is a regular admin' do
      before { sign_in(admin) }

      it 'denies access' do
        get '/settings/product_mode'

        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe 'PATCH /settings/product_mode' do
    context 'when the user is a super admin' do
      before { sign_in(super_admin) }

      it 'sets the current company\'s mode to standard and persists it' do
        patch '/settings/product_mode', params: { product_mode: Docuseal::STANDARD_MODE }

        expect(response).to redirect_to(settings_product_mode_path)
        Docuseal.reset_product_mode!
        expect(Docuseal.product_mode(account)).to eq(Docuseal::STANDARD_MODE)
      end

      it 'switches the current company back to healthcare' do
        create(:account_config, account:, key: AccountConfig::PRODUCT_MODE_KEY, value: Docuseal::STANDARD_MODE)

        patch '/settings/product_mode', params: { product_mode: Docuseal::HEALTHCARE_MODE }

        Docuseal.reset_product_mode!
        expect(Docuseal.product_mode(account)).to eq(Docuseal::HEALTHCARE_MODE)
      end

      it 'rejects an invalid mode value' do
        patch '/settings/product_mode', params: { product_mode: 'bogus' }

        expect(response).to redirect_to(settings_product_mode_path)
        Docuseal.reset_product_mode!
        expect(Docuseal.product_mode(account)).to eq(Docuseal::HEALTHCARE_MODE)
      end
    end

    context 'when the user is a regular admin' do
      before { sign_in(admin) }

      it 'denies access and does not change the mode' do
        patch '/settings/product_mode', params: { product_mode: Docuseal::STANDARD_MODE }

        expect(response).to redirect_to(root_path)
        Docuseal.reset_product_mode!
        expect(Docuseal.product_mode).to eq(Docuseal::HEALTHCARE_MODE)
      end
    end
  end
end
