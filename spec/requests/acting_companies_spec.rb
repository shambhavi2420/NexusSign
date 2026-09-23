# frozen_string_literal: true

require 'rails_helper'

# Acting-company context for the Platform Super Admin (Requirement 3.6, 4.7, 4.8).
describe 'ActingCompanies', type: :request do
  let(:platform_account) { create(:account, name: 'Platform') }
  let(:company_b) { create(:account, name: 'Company B') }

  let(:super_admin) { create(:user, account: platform_account, role: 'super_admin') }
  let(:admin) { create(:user, account: platform_account, role: 'admin') }

  describe 'POST /acting_company' do
    context 'as a super admin' do
      before { sign_in(super_admin) }

      it 'sets the acting company in the session' do
        post '/acting_company', params: { account_id: company_b.id }

        expect(response).to redirect_to(root_path)
        expect(session[:acting_account_id]).to eq(company_b.id)
      end

      it 'rejects an unknown company' do
        post '/acting_company', params: { account_id: -1 }

        expect(session[:acting_account_id]).to be_nil
      end

      it 'rejects an archived company' do
        company_b.update!(archived_at: Time.current)

        post '/acting_company', params: { account_id: company_b.id }

        expect(session[:acting_account_id]).to be_nil
      end
    end

    context 'as a regular admin' do
      before { sign_in(admin) }

      it 'denies access and does not set the context' do
        post '/acting_company', params: { account_id: company_b.id }

        expect(response).to redirect_to(root_path)
        expect(session[:acting_account_id]).to be_nil
      end
    end
  end

  describe 'DELETE /acting_company' do
    before { sign_in(super_admin) }

    it 'clears the acting company' do
      post '/acting_company', params: { account_id: company_b.id }
      expect(session[:acting_account_id]).to eq(company_b.id)

      delete '/acting_company'

      expect(session[:acting_account_id]).to be_nil
    end
  end

  # Bug 1 regression: a super admin acting inside another company must still be
  # able to reach Settings pages for that company.
  describe 'Settings access while acting as another company' do
    before do
      allow_any_instance_of(ActionView::Base).to receive(:javascript_pack_tag).and_return('')
      allow_any_instance_of(ActionView::Base).to receive(:stylesheet_pack_tag).and_return('')
      sign_in(super_admin)
      post '/acting_company', params: { account_id: company_b.id }
    end

    it 'can open the Users settings page (scoped to Company B)' do
      create(:user, account: company_b, role: 'editor')

      get '/settings/users'

      expect(response).to have_http_status(:ok)
    end

    it 'can open the Folder Permissions settings page' do
      get '/settings/folder_permissions'

      expect(response).to have_http_status(:ok)
    end
  end
end
