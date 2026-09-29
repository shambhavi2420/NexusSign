# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Subfolder permission inheritance' do
  let(:account)      { create(:account) }
  let(:owner)        { create(:user, account:, role: 'editor') }
  let(:permitted)    { create(:user, account:, role: 'editor') }
  let(:outsider)     { create(:user, account:, role: 'editor') }

  describe 'TemplateFolderPermissions.inherit_permissions' do
    it 'copies the restricted parent\'s explicit user rows onto the child' do
      parent = create(:template_folder, account:, author: owner)
      create(:template_folder_permission, user: permitted, template_folder: parent)

      child = create(:template_folder, account:, author: owner, parent_folder: parent)
      TemplateFolderPermissions.inherit_permissions(child, parent)

      expect(TemplateFolderPermissions.restricted?(child)).to be(true)
      expect(TemplateFolderPermissions.can_view?(permitted, child)).to be(true)
      expect(TemplateFolderPermissions.can_view?(outsider, child)).to be(false)
    end

    it 'leaves the child unrestricted when the parent is unrestricted' do
      parent = create(:template_folder, account:, author: owner) # no permission rows -> open
      child  = create(:template_folder, account:, author: owner, parent_folder: parent)

      TemplateFolderPermissions.inherit_permissions(child, parent)

      expect(TemplateFolderPermissions.restricted?(child)).to be(false)
      # Open parent means open child: everyone on the account keeps access.
      expect(TemplateFolderPermissions.can_view?(outsider, child)).to be(true)
    end

    it 'is idempotent' do
      parent = create(:template_folder, account:, author: owner)
      create(:template_folder_permission, user: permitted, template_folder: parent)
      child = create(:template_folder, account:, author: owner, parent_folder: parent)

      2.times { TemplateFolderPermissions.inherit_permissions(child, parent) }

      expect(TemplateFolderPermission.where(template_folder_id: child.id, user_id: permitted.id).count).to eq(1)
    end
  end

  describe 'TemplateFolders.find_or_create_by_name creating a subfolder' do
    it 'restricts a new subfolder to the parent\'s audience, not everyone' do
      # Create the parent and restrict it to `permitted`.
      parent = account.template_folders.create!(author: owner, name: 'Clients')
      create(:template_folder_permission, user: permitted, template_folder: parent)

      # Now create "Clients / Acme" as a subfolder.
      child = TemplateFolders.find_or_create_by_name(owner, 'Clients / Acme')

      expect(child.parent_folder_id).to eq(parent.id)
      expect(TemplateFolderPermissions.restricted?(child)).to be(true)
      expect(TemplateFolderPermissions.can_view?(permitted, child)).to be(true)
      expect(TemplateFolderPermissions.can_view?(outsider, child)).to be(false)
    end

    it 'does not re-add inherited rows on a later find of the same subfolder' do
      parent = account.template_folders.create!(author: owner, name: 'Clients')
      create(:template_folder_permission, user: permitted, template_folder: parent)

      child = TemplateFolders.find_or_create_by_name(owner, 'Clients / Acme')

      # An admin later revokes `permitted` from the child directly.
      TemplateFolderPermission.where(template_folder_id: child.id, user_id: permitted.id).destroy_all
      # Keep the child restricted with an owner row so it doesn't flip to open.
      TemplateFolderPermission.find_or_create_by!(template_folder_id: child.id, user_id: owner.id)

      # Finding the subfolder again must NOT re-add the revoked permission.
      TemplateFolders.find_or_create_by_name(owner, 'Clients / Acme')

      expect(TemplateFolderPermission.where(template_folder_id: child.id, user_id: permitted.id).count).to eq(0)
    end
  end
end
