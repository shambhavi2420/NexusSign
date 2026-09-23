# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Docuseal, '.product_mode' do
  # Per-company mode with platform-default fallback (Option B). The platform
  # account is the lowest-id account; its value is the default other companies
  # inherit.
  let!(:platform_account) { create(:account, name: 'Platform') }
  let!(:company_b) { create(:account, name: 'Company B') }

  def set_platform_default(value)
    AccountConfig.create!(account: Account.order(:id).first, key: AccountConfig::PRODUCT_MODE_KEY, value:)
    Docuseal.reset_product_mode!
  end

  def set_override(account, value)
    AccountConfig.create!(account:, key: AccountConfig::PRODUCT_MODE_KEY, value:)
    Docuseal.reset_product_mode!
  end

  before do
    AccountConfig.where(key: AccountConfig::PRODUCT_MODE_KEY).delete_all
    Docuseal.reset_product_mode!
  end

  after { Docuseal.reset_product_mode! }

  context 'when nothing is set' do
    it 'defaults to healthcare for the platform and for any company' do
      expect(Docuseal.product_mode).to eq(Docuseal::HEALTHCARE_MODE)
      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::HEALTHCARE_MODE)
      expect(Docuseal.standard_mode?(company_b)).to be(false)
    end
  end

  context 'when the platform default is standard' do
    before { set_platform_default(Docuseal::STANDARD_MODE) }

    it 'a company with no override inherits standard' do
      expect(Docuseal.platform_default_product_mode).to eq(Docuseal::STANDARD_MODE)
      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::STANDARD_MODE)
      expect(Docuseal.standard_mode?(company_b)).to be(true)
    end

    it 'a company can override back to healthcare' do
      set_override(company_b, Docuseal::HEALTHCARE_MODE)

      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::HEALTHCARE_MODE)
      # Platform default and other companies are unaffected.
      expect(Docuseal.platform_default_product_mode).to eq(Docuseal::STANDARD_MODE)
    end
  end

  context 'when the platform default is healthcare' do
    it 'a company can override to standard independently' do
      set_override(company_b, Docuseal::STANDARD_MODE)

      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::STANDARD_MODE)
      expect(Docuseal.product_mode(platform_account)).to eq(Docuseal::HEALTHCARE_MODE)
    end
  end

  context 'when a stored value is invalid' do
    before { set_override(company_b, 'bogus') }

    it 'ignores it and falls back to the default' do
      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::HEALTHCARE_MODE)
    end
  end

  describe '.reset_product_mode!' do
    it 'busts the per-account cache so a changed override is picked up' do
      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::HEALTHCARE_MODE)

      AccountConfig.create!(account: company_b, key: AccountConfig::PRODUCT_MODE_KEY, value: Docuseal::STANDARD_MODE)

      # Still cached until reset
      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::HEALTHCARE_MODE)

      Docuseal.reset_product_mode!

      expect(Docuseal.product_mode(company_b)).to eq(Docuseal::STANDARD_MODE)
    end
  end
end
