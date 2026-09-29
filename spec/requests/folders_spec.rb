# frozen_string_literal: true

require 'rails_helper'

describe 'Folders API' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }

  describe 'GET /api/folders' do
    it 'hides blank folders and keeps the Default folder' do
      author # ensure a user exists so the Default folder can resolve its author
      default_folder = account.default_template_folder
      folder_with_templates = create(:template_folder, :with_templates, account:, author:, name: 'Contracts')
      _empty_folder = create(:template_folder, account:, author:, name: 'Empty')

      get '/api/folders', headers: { 'x-auth-token': author.access_token.token }

      expect(response).to have_http_status(:ok)

      names = response.parsed_body['data'].map { |f| f['name'] }

      expect(names).to include(default_folder.name)
      expect(names).to include(folder_with_templates.name)
      expect(names).not_to include('Empty')
    end

    it 'includes a folder that only has templates in a subfolder' do
      parent_folder = create(:template_folder, account:, author:, name: 'Parent')
      subfolder = create(:template_folder, account:, author:, name: 'Child', parent_folder:)
      create(:template, account:, author:, folder: subfolder)

      get '/api/folders', headers: { 'x-auth-token': author.access_token.token }

      names = response.parsed_body['data'].map { |f| f['name'] }

      expect(names).to include('Parent')
    end
  end
end
