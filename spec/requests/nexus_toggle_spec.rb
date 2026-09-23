# frozen_string_literal: true

require 'rails_helper'

# The "Visible on Nexus" folder toggle (api_visible) is a no-op in Standard Mode
# and the folders API keeps working, returning all active folders (Requirement 8).
describe 'Nexus visibility toggle', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, role: 'admin') }

  after { Docuseal.reset_product_mode! }

  describe 'TemplateFolder.api_visible scope' do
    it 'includes api_visible=false folders in standard mode (no-op)' do
      allow(Docuseal).to receive(:standard_mode?).and_return(true)
      hidden = create(:template_folder, account:, author: admin, api_visible: false)

      expect(account.template_folders.api_visible).to include(hidden)
    end

    it 'excludes api_visible=false folders in healthcare mode (no regression)' do
      allow(Docuseal).to receive(:standard_mode?).and_return(false)
      hidden = create(:template_folder, account:, author: admin, api_visible: false)

      expect(account.template_folders.api_visible).not_to include(hidden)
    end
  end

  describe 'PATCH /folders/:id ignores api_visible in standard mode' do
    before do
      allow(Docuseal).to receive(:standard_mode?).and_return(true)
      sign_in(admin)
    end

    it 'does not change api_visible' do
      folder = create(:template_folder, account:, author: admin, api_visible: true)

      patch "/folders/#{folder.id}", params: { template_folder: { api_visible: '0' } }

      expect(folder.reload.api_visible).to be(true)
    end
  end
end
