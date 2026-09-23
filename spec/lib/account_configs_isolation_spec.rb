# frozen_string_literal: true

require 'rails_helper'

# Verifies per-company config isolation: under Standard Mode (or multitenant),
# a company must NOT inherit another company's config via the first-account
# fallback (Requirement 2.7).
RSpec.describe 'Per-company config isolation' do
  describe 'Docuseal.per_company_config_isolation?' do
    it 'is true when multitenant' do
      allow(Docuseal).to receive(:multitenant?).and_return(true)
      allow(Docuseal).to receive(:standard_mode?).and_return(false)

      expect(Docuseal.per_company_config_isolation?).to be(true)
    end

    it 'is true in standard mode WITHOUT multitenant (UI toggle alone is sufficient)' do
      allow(Docuseal).to receive(:multitenant?).and_return(false)
      allow(Docuseal).to receive(:standard_mode?).and_return(true)

      expect(Docuseal.per_company_config_isolation?).to be(true)
    end

    it 'is false for a single-tenant healthcare deployment' do
      allow(Docuseal).to receive(:multitenant?).and_return(false)
      allow(Docuseal).to receive(:standard_mode?).and_return(false)

      expect(Docuseal.per_company_config_isolation?).to be(false)
    end
  end

  # Signing certs and trusted certs must resolve per-company under isolation,
  # never falling back to another account's certs (Requirement 2.7).
  describe 'certificate isolation in Standard Mode (no MULTITENANT)' do
    let!(:company_a) { create(:account, name: 'Company A') }
    let(:company_b) { create(:account, name: 'Company B') }

    before do
      allow(Docuseal).to receive(:multitenant?).and_return(false)
      allow(Docuseal).to receive(:standard_mode?).and_return(true)
      stub_const('Docuseal::CERTS', {})
    end

    it 'does not resolve another account\'s signing certs for a company without its own' do
      sentinel = Object.new
      allow(Docuseal).to receive(:default_pkcs).and_return(sentinel)

      # Company A (first account) has a signing cert; Company B has none.
      create(:encrypted_config, account: Account.order(:id).first,
                                key: EncryptedConfig::ESIGN_CERTS_KEY,
                                value: GenerateCertificate.call.transform_values(&:to_pem))

      # For Company B (no own cert) isolation must fall back to the default pkcs,
      # never Company A's stored cert.
      expect(Accounts.load_signing_pkcs(company_b)).to eq(sentinel)
    end
  end

  describe 'AccountConfigs.find_for_account' do
    let!(:platform_account) { create(:account, name: 'Platform') }
    let(:company_b) { create(:account, name: 'Company B') }
    let(:key) { AccountConfig::FORM_WITH_CONFETTI_KEY }

    before do
      # The platform (first) account has a value; Company B does not.
      create(:account_config, account: Account.order(:id).first, key:, value: true)
    end

    context 'when isolation is on (standard/multitenant)' do
      before { allow(Docuseal).to receive(:per_company_config_isolation?).and_return(true) }

      it 'does NOT fall back to the first account for another company' do
        expect(AccountConfigs.find_for_account(company_b, key)).to be_nil
      end
    end

    context 'when isolation is off (single-tenant healthcare)' do
      before { allow(Docuseal).to receive(:per_company_config_isolation?).and_return(false) }

      it 'falls back to the first account (legacy single-tenant behavior)' do
        expect(AccountConfigs.find_for_account(company_b, key)).not_to be_nil
      end
    end
  end
end
