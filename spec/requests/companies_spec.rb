# frozen_string_literal: true

require 'rails_helper'

# Company management for the Platform Super Admin (Requirement 4).
describe 'Companies', type: :request do
  let(:platform_account) { create(:account, name: 'Platform') }
  let(:super_admin) { create(:user, account: platform_account, role: 'super_admin') }
  let(:admin) { create(:user, account: platform_account, role: 'admin') }

  # Stub webpack pack tags so index/new HTML pages render without compiled assets.
  before do
    allow_any_instance_of(ActionView::Base).to receive(:javascript_pack_tag).and_return('')
    allow_any_instance_of(ActionView::Base).to receive(:stylesheet_pack_tag).and_return('')
  end

  describe 'authorization' do
    it 'denies a regular admin' do
      sign_in(admin)

      get '/companies'

      expect(response).to redirect_to(root_path)
    end

    it 'allows a super admin' do
      sign_in(super_admin)

      get '/companies'

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /companies' do
    before { sign_in(super_admin) }

    it 'creates a company with a first Company Admin and a default folder' do
      expect do
        post '/companies', params: {
          account: { name: 'Acme Corp', locale: 'en-US', timezone: 'UTC' },
          admin: { first_name: 'Ada', last_name: 'Admin', email: 'ada@acme.test' }
        }
      end.to change(Account, :count).by(1)

      company = Account.find_by(name: 'Acme Corp')
      expect(company).to be_present

      created_admin = company.users.find_by(email: 'ada@acme.test')
      expect(created_admin).to be_present
      expect(created_admin.role).to eq(User::ADMIN_ROLE)
      expect(created_admin.role).not_to eq(User::SUPER_ADMIN_ROLE)

      expect(company.default_template_folder).to be_present
    end
  end

  describe 'PATCH /companies/:id/archive' do
    before { sign_in(super_admin) }

    it 'archives the company so its users can no longer authenticate' do
      company = create(:account, name: 'ToArchive')
      company_user = create(:user, account: company, role: 'admin')

      patch "/companies/#{company.id}/archive"

      expect(company.reload.archived_at).to be_present
      # User#active_for_authentication? is false when the account is archived.
      expect(company_user.reload.active_for_authentication?).to be(false)
    end
  end

  describe 'PATCH /companies/:id/unarchive' do
    before { sign_in(super_admin) }

    it 'restores an archived company' do
      company = create(:account, name: 'ToRestore', archived_at: Time.current)

      patch "/companies/#{company.id}/unarchive"

      expect(company.reload.archived_at).to be_nil
    end
  end
end
