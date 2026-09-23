# frozen_string_literal: true

require 'rails_helper'

# The template Move dialog (folder autocomplete + move target) must never expose
# or use another company's folders (Requirement 2.3).
describe 'Move folder isolation', type: :request do
  let(:company_a) { create(:account, name: 'Company A') }
  let(:company_b) { create(:account, name: 'Company B') }

  let(:admin_a) { create(:user, account: company_a, role: 'admin') }
  let(:admin_b) { create(:user, account: company_b, role: 'admin') }

  describe 'GET /template_folders_autocomplete' do
    it 'never lists another company\'s folders' do
      create(:template_folder, account: company_b, author: admin_b, name: 'CompanyB Secret Folder')
      create(:template_folder, account: company_a, author: admin_a, name: 'CompanyA Contracts')

      sign_in(admin_a)

      get '/template_folders_autocomplete', params: { q: '' }

      expect(response).to have_http_status(:ok)
      names = response.parsed_body.map { |f| f['name'] }
      expect(names).not_to include('CompanyB Secret Folder')
    end
  end

  describe 'TemplateFolders.find_or_create_by_name with an explicit account' do
    it 'creates the destination folder in the given (acting) account' do
      folder = TemplateFolders.find_or_create_by_name(admin_a, 'Onboarding', company_b)

      expect(folder.account_id).to eq(company_b.id)
    end

    it 'defaults to the author\'s account when no account is given' do
      folder = TemplateFolders.find_or_create_by_name(admin_a, 'Onboarding')

      expect(folder.account_id).to eq(company_a.id)
    end
  end

  # Regression: a super admin acting in another company must create new
  # template folders in the ACTING company, not their own account.
  describe 'template creation while acting as another company' do
    let(:platform_account) { create(:account, name: 'Platform FSM') }
    let(:super_admin) { create(:user, account: platform_account, role: 'super_admin') }

    before do
      allow_any_instance_of(ActionView::Base).to receive(:javascript_pack_tag).and_return('')
      allow_any_instance_of(ActionView::Base).to receive(:stylesheet_pack_tag).and_return('')
      sign_in(super_admin)
      post '/acting_company', params: { account_id: company_b.id }
    end

    it 'creates the named folder in the acting company (Company B), not the platform account' do
      post '/templates', params: { template: { name: 'Contract' }, folder_name: 'SDNA Folder' }

      folder = TemplateFolder.find_by(name: 'SDNA Folder')
      expect(folder).to be_present
      expect(folder.account_id).to eq(company_b.id)
      expect(folder.account_id).not_to eq(platform_account.id)
    end
  end
end
