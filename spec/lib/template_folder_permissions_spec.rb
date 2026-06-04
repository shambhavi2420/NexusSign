# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TemplateFolderPermissions do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:, role: 'editor') }
  let(:admin_user) { create(:user, account:, role: 'admin') }
  let(:editor_user) { create(:user, account:, role: 'editor') }

  describe '.can_view?' do
    let(:folder) { create(:template_folder, account:, author: owner) }

    context 'when user is the folder owner' do
      it 'returns true' do
        expect(described_class.can_view?(owner, folder)).to be(true)
      end

      it 'returns true even when the folder is restricted' do
        create(:template_folder_permission, user: editor_user, template_folder: folder)

        expect(described_class.can_view?(owner, folder)).to be(true)
      end
    end

    context 'when user is an admin' do
      it 'returns true for an unrestricted folder' do
        expect(described_class.can_view?(admin_user, folder)).to be(true)
      end

      it 'returns true for a restricted folder' do
        create(:template_folder_permission, user: editor_user, template_folder: folder)

        expect(described_class.can_view?(admin_user, folder)).to be(true)
      end
    end

    context 'when user is archived' do
      let(:archived_user) { create(:user, account:, role: 'editor', archived_at: Time.current) }

      it 'returns false on a restricted folder even with an explicit permission' do
        create(:template_folder_permission, user: archived_user, template_folder: folder)

        expect(described_class.can_view?(archived_user, folder)).to be(false)
      end
    end

    context 'when folder is unrestricted' do
      it 'returns true for any active account user' do
        expect(described_class.can_view?(editor_user, folder)).to be(true)
      end
    end

    context 'when folder is restricted' do
      before do
        # Make folder restricted by granting a different user permission
        other_user = create(:user, account:, role: 'editor')
        create(:template_folder_permission, user: other_user, template_folder: folder)
      end

      it 'returns false for a non-owner non-admin user without explicit permission' do
        unpermitted_user = create(:user, account:, role: 'editor')

        expect(described_class.can_view?(unpermitted_user, folder)).to be(false)
      end
    end

    context 'when user has explicit permission' do
      it 'returns true for a restricted folder' do
        create(:template_folder_permission, user: editor_user, template_folder: folder)

        expect(described_class.can_view?(editor_user, folder)).to be(true)
      end
    end
  end

  describe '.visible_to' do
    context 'when user is a non-admin' do
      it 'returns only accessible folders' do
        # Folder owned by someone else, unrestricted — visible
        unrestricted_folder = create(:template_folder, account:, author: owner)

        # Folder owned by someone else, restricted with permission for editor_user — visible
        permitted_folder = create(:template_folder, account:, author: owner)
        create(:template_folder_permission, user: editor_user, template_folder: permitted_folder)

        # Folder owned by someone else, restricted without permission — not visible
        restricted_folder = create(:template_folder, account:, author: owner)
        other_user = create(:user, account:, role: 'editor')
        create(:template_folder_permission, user: other_user, template_folder: restricted_folder)

        scope = TemplateFolder.where(account_id: account.id)
        result = described_class.visible_to(scope, editor_user)

        expect(result).to include(unrestricted_folder)
        expect(result).to include(permitted_folder)
        expect(result).not_to include(restricted_folder)
      end
    end

    context 'when user is an admin' do
      it 'returns all folders in the scope' do
        folder_a = create(:template_folder, account:, author: owner)
        folder_b = create(:template_folder, account:, author: owner)
        # Make folder_b restricted
        create(:template_folder_permission, user: editor_user, template_folder: folder_b)

        scope = TemplateFolder.where(account_id: account.id)
        result = described_class.visible_to(scope, admin_user)

        expect(result).to include(folder_a)
        expect(result).to include(folder_b)
      end
    end
  end

  describe '.permitted_users' do
    context 'when folder is restricted' do
      it 'returns owner, admins, and explicitly permitted active users, excluding archived' do
        folder = create(:template_folder, account:, author: owner)

        # Grant explicit permission to editor_user (makes folder restricted)
        create(:template_folder_permission, user: editor_user, template_folder: folder)

        # Archived user with explicit permission should be excluded
        archived_user = create(:user, account:, role: 'editor', archived_at: Time.current)
        create(:template_folder_permission, user: archived_user, template_folder: folder)

        # Unpermitted user should not be included
        unpermitted_user = create(:user, account:, role: 'editor')

        result = described_class.permitted_users(folder)
        result_ids = result.pluck(:id)

        expect(result_ids).to include(owner.id)
        expect(result_ids).to include(admin_user.id)
        expect(result_ids).to include(editor_user.id)
        expect(result_ids).not_to include(archived_user.id)
        expect(result_ids).not_to include(unpermitted_user.id)
      end
    end

    context 'when folder is unrestricted' do
      it 'returns all active account users' do
        folder = create(:template_folder, account:, author: owner)
        another_user = create(:user, account:, role: 'editor')
        archived_user = create(:user, account:, role: 'editor', archived_at: Time.current)

        result = described_class.permitted_users(folder)
        result_ids = result.pluck(:id)

        expect(result_ids).to include(owner.id)
        expect(result_ids).to include(admin_user.id)
        expect(result_ids).to include(another_user.id)
        expect(result_ids).not_to include(archived_user.id)
      end
    end
  end

  describe '.grant' do
    it 'is idempotent — multiple calls create only one permission record' do
      folder = create(:template_folder, account:, author: owner)

      described_class.grant(editor_user, folder)
      described_class.grant(editor_user, folder)
      described_class.grant(editor_user, folder)

      expect(TemplateFolderPermission.where(user: editor_user, template_folder: folder).count).to eq(1)
    end
  end

  describe '.revoke' do
    it 'is a no-op when no permission record exists (no error raised)' do
      folder = create(:template_folder, account:, author: owner)

      expect { described_class.revoke(editor_user, folder) }.not_to raise_error
      expect(TemplateFolderPermission.where(user: editor_user, template_folder: folder).count).to eq(0)
    end
  end
end
