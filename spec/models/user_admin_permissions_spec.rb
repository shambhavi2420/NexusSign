# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, 'default admin permissions' do
  let(:account) { create(:account) }

  it 'grants Users and Folder Permissions to a newly created admin' do
    user = create(:user, account:, role: User::ADMIN_ROLE)

    expect(user.admin_permissions).to contain_exactly('users', 'folder_permissions')
    expect(user.can_access_setting?('users')).to be(true)
    expect(user.can_access_setting?('folder_permissions')).to be(true)
  end

  it 'does not grant the defaults to non-admin roles' do
    editor = create(:user, account:, role: 'editor')
    viewer = create(:user, account:, role: 'viewer')

    expect(editor.admin_permissions).to be_empty
    expect(viewer.admin_permissions).to be_empty
  end

  it 'leaves super admins unrestricted without needing the stored list' do
    super_admin = create(:user, account:, role: User::SUPER_ADMIN_ROLE)

    # Super admins ignore the access list entirely.
    expect(super_admin.can_access_setting?('users')).to be(true)
    expect(super_admin.can_access_setting?('folder_permissions')).to be(true)
    expect(super_admin.can_access_setting?('webhooks')).to be(true)
  end

  it 'does not overwrite permissions on later non-role updates' do
    user = create(:user, account:, role: User::ADMIN_ROLE)
    user.admin_permissions = ['api']
    user.update!(first_name: 'Changed')

    expect(user.reload.admin_permissions).to contain_exactly('api')
  end

  it 'grants the defaults when an existing user is promoted to admin' do
    user = create(:user, account:, role: 'editor')
    expect(user.admin_permissions).to be_empty

    user.update!(role: User::ADMIN_ROLE)

    expect(user.reload.admin_permissions).to contain_exactly('users', 'folder_permissions')
    expect(user.can_access_setting?('users')).to be(true)
    expect(user.can_access_setting?('folder_permissions')).to be(true)
  end

  it 'does not overwrite an already-configured admin who is re-saved with the admin role' do
    user = create(:user, account:, role: User::ADMIN_ROLE)
    user.admin_permissions = ['api']

    # Simulate a role write that doesn't actually change the value away from admin.
    user.update!(role: User::ADMIN_ROLE, first_name: 'Kept')

    expect(user.reload.admin_permissions).to contain_exactly('api')
  end

  it 'does not grant defaults when a user is promoted to super_admin' do
    user = create(:user, account:, role: 'editor')
    user.update!(role: User::SUPER_ADMIN_ROLE)

    expect(user.reload.admin_permissions).to be_empty
    # Super admins are unrestricted regardless of the stored list.
    expect(user.can_access_setting?('users')).to be(true)
  end
end
