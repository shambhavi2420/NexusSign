# frozen_string_literal: true

describe 'TemplateFolderPermissions', type: :request do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:, role: 'admin') }
  let(:folder) { create(:template_folder, account:, author: owner) }

  describe 'GET /folders/:folder_id/permissions' do
    context 'when the user is the folder owner' do
      before { sign_in(owner) }

      it 'returns 200 with the list of permitted users' do
        other_user = create(:user, account:, role: 'editor')
        create(:template_folder_permission, template_folder: folder, user: other_user)

        get "/folders/#{folder.id}/permissions"

        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        emails = body.map { |u| u['email'] }

        expect(emails).to include(owner.email)
        expect(emails).to include(other_user.email)
      end

      it 'returns user attributes matching the expected fields' do
        get "/folders/#{folder.id}/permissions"

        expect(response).to have_http_status(:ok)

        body = response.parsed_body
        expect(body.first.keys).to match_array(%w[id email first_name last_name role])
      end
    end

    context 'when the user is an admin but not the owner' do
      let(:admin) { create(:user, account:, role: 'admin') }

      before { sign_in(admin) }

      it 'returns 200' do
        get "/folders/#{folder.id}/permissions"

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the user is neither owner nor admin' do
      let(:non_owner) { create(:user, account:, role: 'editor') }

      before { sign_in(non_owner) }

      it 'redirects (CanCan::AccessDenied)' do
        get "/folders/#{folder.id}/permissions"

        expect(response).to have_http_status(:redirect)
      end
    end
  end

  describe 'POST /folders/:folder_id/permissions' do
    before { sign_in(owner) }

    context 'with a valid same-account user' do
      it 'creates a permission record and returns 201' do
        target_user = create(:user, account:, role: 'editor')

        expect {
          post "/folders/#{folder.id}/permissions", params: { user_id: target_user.id }
        }.to change(TemplateFolderPermission, :count).by(1)

        expect(response).to have_http_status(:created)
      end
    end

    context 'with a cross-account user' do
      it 'returns 404 because the user is not found in the current account scope' do
        other_account = create(:account)
        cross_user = create(:user, account: other_account, role: 'editor')

        expect {
          post "/folders/#{folder.id}/permissions", params: { user_id: cross_user.id }
        }.not_to change(TemplateFolderPermission, :count)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to include('error' => 'User not found')
      end
    end

    context 'with an unknown user_id' do
      it 'returns 404' do
        expect {
          post "/folders/#{folder.id}/permissions", params: { user_id: 0 }
        }.not_to change(TemplateFolderPermission, :count)

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body).to include('error' => 'User not found')
      end
    end
  end

  describe 'DELETE /folders/:folder_id/permissions/:id' do
    before { sign_in(owner) }

    context 'when the user has a permission record' do
      it 'removes the record and returns 204' do
        target_user = create(:user, account:, role: 'editor')
        create(:template_folder_permission, template_folder: folder, user: target_user)

        expect {
          delete "/folders/#{folder.id}/permissions/#{target_user.id}"
        }.to change(TemplateFolderPermission, :count).by(-1)

        expect(response).to have_http_status(:no_content)
      end
    end

    context 'when the user does not exist' do
      it 'still returns 204' do
        expect {
          delete "/folders/#{folder.id}/permissions/#{0}"
        }.not_to change(TemplateFolderPermission, :count)

        expect(response).to have_http_status(:no_content)
      end
    end
  end
end
