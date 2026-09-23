# frozen_string_literal: true

require 'rails_helper'

# Verifies that a Platform Super Admin's abilities are scoped to the acting
# company when one is selected, and unrestricted otherwise (Requirement 3.6).
RSpec.describe Ability do
  let(:platform_account) { create(:account, name: 'Platform') }
  let(:company_b) { create(:account, name: 'Company B') }

  let(:super_admin) { create(:user, account: platform_account, role: 'super_admin') }
  let(:admin_b) { create(:user, account: company_b, role: 'admin') }

  let(:folder_b) { create(:template_folder, account: company_b, author: admin_b) }
  let(:template_b) { create(:template, account: company_b, author: admin_b, folder: folder_b, attachment_count: 0) }

  let(:own_folder) { create(:template_folder, account: platform_account, author: super_admin) }
  let(:own_template) do
    create(:template, account: platform_account, author: super_admin, folder: own_folder, attachment_count: 0)
  end

  context 'with no acting company (unrestricted)' do
    subject(:ability) { described_class.new(super_admin) }

    it 'manages its OWN company records but not another company (scoped even at home)' do
      expect(ability.can?(:manage, own_template)).to be(true)
      expect(ability.can?(:manage, template_b)).to be(false)
    end

    it 'can still manage companies (platform management)' do
      expect(ability.can?(:manage, Account.new)).to be(true)
    end
  end

  context 'when acting inside Company B' do
    subject(:ability) { described_class.new(super_admin, company_b.id) }

    it 'can manage Company B records' do
      expect(ability.can?(:manage, template_b)).to be(true)
      expect(ability.can?(:manage, folder_b)).to be(true)
    end

    it 'cannot manage records in another company (the platform account)' do
      expect(ability.can?(:manage, own_template)).to be(false)
      expect(ability.can?(:manage, own_folder)).to be(false)
    end

    it 'can manage the acting company\'s users and configs (Settings works)' do
      user_b = create(:user, account: company_b, role: 'editor')
      config_b = create(:account_config, account: company_b, key: AccountConfig::FORM_WITH_CONFETTI_KEY, value: true)

      expect(ability.can?(:manage, user_b)).to be(true)
      expect(ability.can?(:manage, config_b)).to be(true)
      expect(ability.can?(:manage, company_b)).to be(true)
    end

    it 'cannot manage another company\'s users' do
      other_user = create(:user, account: platform_account, role: 'editor')

      expect(ability.can?(:manage, other_user)).to be(false)
    end
  end

  context 'when acting company equals the super admin\'s own account' do
    subject(:ability) { described_class.new(super_admin, platform_account.id) }

    it 'manages its own account content, not another company' do
      expect(ability.can?(:manage, own_template)).to be(true)
      expect(ability.can?(:manage, template_b)).to be(false)
    end
  end
end
