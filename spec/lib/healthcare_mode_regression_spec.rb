# frozen_string_literal: true

require 'rails_helper'

# Regression guard: with the default (unset / healthcare) mode and a single
# tenant, every Standard-Mode gate must be a no-op so existing agencies see no
# behavioral change (Requirement 9).
RSpec.describe 'Healthcare-mode (default) regression' do
  before { Docuseal.reset_product_mode! }
  after { Docuseal.reset_product_mode! }

  describe 'default product mode' do
    it 'defaults to healthcare when unset' do
      expect(Docuseal.product_mode).to eq(Docuseal::HEALTHCARE_MODE)
      expect(Docuseal.standard_mode?).to be(false)
    end
  end

  describe 'field mapping is unchanged' do
    it 'preserves candidate and signer field types' do
      expect(Templates::ProductModeFieldTypes.normalize_type('candidatessn')).to eq('candidatessn')
      expect(Templates::ProductModeFieldTypes.normalize_type('signerfullname')).to eq('signerfullname')
    end

    it 'leaves a candidate field hash untouched' do
      field = { 'type' => 'candidatessn', 'preferences' => { 'mask' => true } }

      expect(Templates::ProductModeFieldTypes.normalize_field(field)).to eq(field)
    end
  end

  describe 'cross-account sharing is allowed' do
    it 'permits linked/testing account sharing' do
      expect(Docuseal.cross_account_sharing_allowed?).to be(true)
    end
  end

  describe 'per-company config fallback' do
    it 'is NOT isolated in a single-tenant healthcare deployment (legacy fallback active)' do
      allow(Docuseal).to receive(:multitenant?).and_return(false)

      expect(Docuseal.per_company_config_isolation?).to be(false)
    end
  end

  describe 'Nexus api_visible scope still filters' do
    let(:account) { create(:account) }
    let(:admin) { create(:user, account:, role: 'admin') }

    it 'excludes api_visible=false folders (Nexus toggle honored)' do
      hidden = create(:template_folder, account:, author: admin, api_visible: false)

      expect(account.template_folders.api_visible).not_to include(hidden)
    end
  end

  describe 'super admin ability at home (no acting company)' do
    let(:home_account) { create(:account, name: 'Home') }
    let(:other_account) { create(:account, name: 'Other') }
    let(:super_admin) { create(:user, account: home_account, role: 'super_admin') }

    it 'manages its own company content and can manage companies, but is scoped (not unconditional manage :all)' do
      ability = Ability.new(super_admin)

      # Full control of own company + platform company management.
      expect(ability.can?(:manage, TemplateFolder.new(account_id: home_account.id))).to be(true)
      expect(ability.can?(:manage, Account.new)).to be(true)

      # But NOT another company's content (isolation holds even at home).
      expect(ability.can?(:manage, TemplateFolder.new(account_id: other_account.id))).to be(false)
    end
  end
end
