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

  it 'does not overwrite permissions on later updates' do
    user = create(:user, account:, role: User::ADMIN_ROLE)
    user.admin_permissions = ['api']
    user.update!(first_name: 'Changed')

    expect(user.reload.admin_permissions).to contain_exactly('api')
  end
end
