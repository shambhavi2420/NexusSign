# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Templates::ProductModeFieldTypes do
  after { Docuseal.reset_product_mode! }

  describe '.normalize_type' do
    context 'in standard mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(true) }

      it 'downgrades candidate types to text' do
        expect(described_class.normalize_type('candidatessn')).to eq('text')
        expect(described_class.normalize_type('candidatepermanentcity')).to eq('text')
      end

      it 'downgrades signer name types to text' do
        expect(described_class.normalize_type('signerfullname')).to eq('text')
        expect(described_class.normalize_type('signerfirstname')).to eq('text')
        expect(described_class.normalize_type('signerlastname')).to eq('text')
      end

      it 'leaves standard types unchanged' do
        expect(described_class.normalize_type('text')).to eq('text')
        expect(described_class.normalize_type('signature')).to eq('signature')
        expect(described_class.normalize_type('date')).to eq('date')
      end

      it 'downgrades signer email and phone to text' do
        expect(described_class.normalize_type('signeremail')).to eq('text')
        expect(described_class.normalize_type('signerprimaryphone')).to eq('text')
      end
    end

    context 'in healthcare mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(false) }

      it 'leaves candidate and signer types unchanged (no regression)' do
        expect(described_class.normalize_type('candidatessn')).to eq('candidatessn')
        expect(described_class.normalize_type('signerfullname')).to eq('signerfullname')
      end
    end
  end

  describe '.normalize_field' do
    context 'in standard mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(true) }

      it 'rewrites the type and strips the SSN mask (symbol keys)' do
        field = { type: 'candidatessn', name: 'Candidate SSN', preferences: { 'mask' => true } }

        result = described_class.normalize_field(field)

        expect(result[:type]).to eq('text')
        expect(result[:preferences]).not_to have_key('mask')
      end

      it 'rewrites the type (string keys)' do
        field = { 'type' => 'signerfullname', 'name' => 'Signer Full Name' }

        result = described_class.normalize_field(field)

        expect(result['type']).to eq('text')
      end

      it 'does not mutate a standard field' do
        field = { 'type' => 'text', 'name' => 'Notes' }

        expect(described_class.normalize_field(field)).to eq(field)
      end
    end

    context 'in healthcare mode' do
      before { allow(Docuseal).to receive(:standard_mode?).and_return(false) }

      it 'is a no-op' do
        field = { type: 'candidatessn', preferences: { 'mask' => true } }

        expect(described_class.normalize_field(field)).to eq(field)
      end
    end
  end
end

RSpec.describe 'Per-company field stripping' do
  let!(:platform_account) { create(:account, name: 'Platform') }
  let!(:standard_company) { create(:account, name: 'Standard Co') }
  let!(:healthcare_company) { create(:account, name: 'Healthcare Co') }

  before do
    AccountConfig.where(key: AccountConfig::PRODUCT_MODE_KEY).delete_all
    # Only standard_company overrides to standard; the rest inherit the default (healthcare).
    AccountConfig.create!(account: standard_company, key: AccountConfig::PRODUCT_MODE_KEY,
                          value: Docuseal::STANDARD_MODE)
    Docuseal.reset_product_mode!
  end

  after { Docuseal.reset_product_mode! }

  it 'downgrades candidate/signer types ONLY for the standard company' do
    expect(Templates::ProductModeFieldTypes.normalize_type('candidatessn', standard_company)).to eq('text')
    expect(Templates::ProductModeFieldTypes.normalize_type('signeremail', standard_company)).to eq('text')

    # A healthcare company (inherits default) keeps the custom types.
    expect(Templates::ProductModeFieldTypes.normalize_type('candidatessn', healthcare_company)).to eq('candidatessn')
    expect(Templates::ProductModeFieldTypes.normalize_type('signeremail', healthcare_company)).to eq('signeremail')
  end
end
