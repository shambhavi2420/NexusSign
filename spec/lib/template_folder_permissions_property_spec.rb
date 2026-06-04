# frozen_string_literal: true

require 'rails_helper'
require 'rantly/rspec_extensions'

RSpec.describe 'TemplateFolderPermissions properties', :property do
  # Property 1: Permission grant creates a record (idempotency)
  # Validates: Requirements 1.1, 1.2
  it 'creates exactly one TemplateFolderPermission record regardless of how many times grant is called' do
    property_of {
      integer(1..5)
    }.check(100) do |n|
      account = create(:account)
      user    = create(:user, account:)
      folder  = create(:template_folder, account:, author: create(:user, account:))

      # Call grant N times for the same user-folder pair
      n.times { TemplateFolderPermissions.grant(user, folder) }

      # Exactly one permission record should exist — grant is idempotent
      expect(TemplateFolderPermission.where(user:, template_folder: folder).count).to eq(1)
    end
  end

  # Property 12: User deletion cascades all permission records
  # Validates: Requirements 7.1
  it 'destroys all TemplateFolderPermission records when the user is destroyed' do
    property_of {
      integer(1..5)
    }.check(100) do |n|
      account = create(:account)
      user    = create(:user, account:)

      # Create n folders owned by a different user in the same account so the
      # permission-target user is not the folder author (avoids author_id clash).
      folder_author = create(:user, account:)
      folders = Array.new(n) { create(:template_folder, account:, author: folder_author) }

      # Grant the target user a permission on each folder.
      folders.each do |folder|
        create(:template_folder_permission, user:, template_folder: folder)
      end

      user_id = user.id

      # Sanity check: n permission records exist before destroy.
      expect(TemplateFolderPermission.where(user_id:).count).to eq(n)

      user.destroy!

      # After destroy, zero permission records should remain for that user_id.
      expect(TemplateFolderPermission.where(user_id:).count).to eq(0)
    end
  end

  # Property 2: Cross-account grant is rejected
  # Validates: Requirements 1.3, 10.3
  it 'raises ActiveRecord::RecordInvalid and creates no record when granting across accounts' do
    property_of {
      guard(true)
    }.check(100) do
      account_a = create(:account)
      account_b = create(:account)
      user      = create(:user, account: account_a)
      folder    = create(:template_folder, account: account_b, author: create(:user, account: account_b))

      expect {
        TemplateFolderPermissions.grant(user, folder)
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(TemplateFolderPermission.where(user:, template_folder: folder).count).to eq(0)
    end
  end

  # Property 3: Permission revoke is idempotent
  # Validates: Requirements 2.1, 2.4
  it 'leaves zero permission records after revoke regardless of whether a record existed' do
    property_of {
      boolean
    }.check(100) do |with_permission|
      account = create(:account)
      author  = create(:user, account:)
      user    = create(:user, account:)
      folder  = create(:template_folder, account:, author:)

      create(:template_folder_permission, user:, template_folder: folder) if with_permission

      expect { TemplateFolderPermissions.revoke(user, folder) }.not_to raise_error
      expect { TemplateFolderPermissions.revoke(user, folder) }.not_to raise_error

      expect(TemplateFolderPermission.where(user:, template_folder: folder).count).to eq(0)
    end
  end

  # Property 4: Owner always has view access
  # Validates: Requirements 3.1, 5.1
  it 'returns true for can_view? when the user is the folder owner regardless of restriction' do
    property_of {
      boolean
    }.check(100) do |restricted|
      account = create(:account)
      owner   = create(:user, account:)
      folder  = create(:template_folder, account:, author: owner)

      if restricted
        other_user = create(:user, account:)
        create(:template_folder_permission, user: other_user, template_folder: folder)
      end

      expect(TemplateFolderPermissions.can_view?(owner, folder)).to be(true)
    end
  end

  # Property 5: Explicit permission grants view access
  # Validates: Requirements 3.2, 5.5
  it 'returns true for can_view? when the user has an explicit permission on a restricted folder' do
    property_of {
      guard(true)
    }.check(100) do
      account    = create(:account)
      owner      = create(:user, account:)
      folder     = create(:template_folder, account:, author: owner)
      other_user = create(:user, account:)

      # Creating a permission for other_user makes the folder restricted
      create(:template_folder_permission, user: other_user, template_folder: folder)

      expect(TemplateFolderPermissions.can_view?(other_user, folder)).to be(true)
    end
  end

  # Property 6: Unrestricted folders are visible to all account members
  # Validates: Requirements 3.3, 5.3
  it 'returns true for can_view? for any active account member when the folder is unrestricted' do
    property_of {
      guard(true)
    }.check(100) do
      account = create(:account)
      owner   = create(:user, account:)
      folder  = create(:template_folder, account:, author: owner)
      user    = create(:user, account:, role: 'editor')

      # No permission records — folder is unrestricted
      expect(TemplateFolderPermissions.can_view?(user, folder)).to be(true)
    end
  end

  # Property 7: Restricted folders deny unpermitted users
  # Validates: Requirements 3.4, 5.2
  it 'returns false for can_view? for a non-owner non-admin user without an explicit permission' do
    property_of {
      guard(true)
    }.check(100) do
      account          = create(:account)
      owner            = create(:user, account:)
      folder           = create(:template_folder, account:, author: owner)
      permitted_user   = create(:user, account:, role: 'editor')
      unpermitted_user = create(:user, account:, role: 'editor')

      # Grant permission to permitted_user only — makes folder restricted
      create(:template_folder_permission, user: permitted_user, template_folder: folder)

      expect(TemplateFolderPermissions.can_view?(unpermitted_user, folder)).to be(false)
    end
  end

  # Property 8: Admin users always have view access
  # Validates: Requirements 3.5, 5.4
  it 'returns true for can_view? for an admin user regardless of folder restriction' do
    property_of {
      boolean
    }.check(100) do |restricted|
      account    = create(:account)
      owner      = create(:user, account:)
      folder     = create(:template_folder, account:, author: owner)
      admin_user = create(:user, account:, role: 'admin')

      if restricted
        other_user = create(:user, account:)
        create(:template_folder_permission, user: other_user, template_folder: folder)
      end

      expect(TemplateFolderPermissions.can_view?(admin_user, folder)).to be(true)
    end
  end

  # Property 9: Folder listing returns only accessible folders
  # Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5
  it 'visible_to returns exactly the folders for which can_view? is true' do
    property_of {
      integer(2..5)
    }.check(100) do |n|
      account = create(:account)
      user    = create(:user, account:, role: 'editor')

      folders = Array.new(n) do
        create(:template_folder, account:, author: create(:user, account:))
      end

      # Randomly restrict some folders (grant permission to a different user, not our test user)
      folders.each_with_index do |folder, i|
        if i.odd?
          other = create(:user, account:)
          create(:template_folder_permission, user: other, template_folder: folder)
        end
      end

      scope = TemplateFolder.where(id: folders.map(&:id))
      visible_ids = TemplateFolderPermissions.visible_to(scope, user).pluck(:id).sort
      expected_ids = folders.select { |f| TemplateFolderPermissions.can_view?(user, f) }.map(&:id).sort

      expect(visible_ids).to eq(expected_ids)
    end
  end

  # Property 10: Ancestor access grants descendant access
  # Validates: Requirements 6.1
  it 'returns true for can_view? on all descendants when the user has access to the root' do
    property_of {
      integer(1..3)
    }.check(100) do |depth|
      account = create(:account)
      owner   = create(:user, account:)
      user    = create(:user, account:, role: 'editor')

      # Root folder is unrestricted — user has access
      root = create(:template_folder, account:, author: owner)

      # Build a chain of unrestricted subfolders
      chain = [root]
      depth.times do
        chain << create(:template_folder, account:, author: owner, parent_folder: chain.last)
      end

      # User should have access to every node in the chain
      chain.each do |folder|
        expect(TemplateFolderPermissions.can_view?(user, folder)).to be(true),
          "Expected can_view? to be true for folder #{folder.id} at depth #{chain.index(folder)}"
      end
    end
  end

  # Property 11: Blocked ancestor denies all descendants
  # Validates: Requirements 6.2, 6.3, 6.5
  it 'returns false for can_view? on all descendants when the user lacks access to the root' do
    property_of {
      integer(1..3)
    }.check(100) do |subfolder_count|
      account    = create(:account)
      owner      = create(:user, account:)
      user       = create(:user, account:, role: 'editor')
      other_user = create(:user, account:, role: 'editor')

      # Root is restricted — only other_user has permission, not our test user
      root = create(:template_folder, account:, author: owner)
      create(:template_folder_permission, user: other_user, template_folder: root)

      # Subfolders are unrestricted (no permission records)
      subfolders = Array.new(subfolder_count) do
        create(:template_folder, account:, author: owner, parent_folder: root)
      end

      subfolders.each do |subfolder|
        expect(TemplateFolderPermissions.can_view?(user, subfolder)).to be(false),
          "Expected can_view? to be false for subfolder #{subfolder.id} due to blocked ancestor"
      end
    end
  end

  # Property 13: Archived users are denied access to restricted folders
  # Validates: Requirements 7.2
  it 'returns false for can_view? for an archived user even with an explicit permission record' do
    property_of {
      guard(true)
    }.check(100) do
      account       = create(:account)
      owner         = create(:user, account:)
      folder        = create(:template_folder, account:, author: owner)
      archived_user = create(:user, account:, role: 'editor', archived_at: Time.current)

      # Give the archived user an explicit permission (makes folder restricted too)
      create(:template_folder_permission, user: archived_user, template_folder: folder)

      expect(TemplateFolderPermissions.can_view?(archived_user, folder)).to be(false)
    end
  end

  # Property 14: Folder deletion cascades all permission records
  # Validates: Requirements 8.1, 8.4
  it 'destroys all TemplateFolderPermission records for the entire subtree when the root folder is destroyed' do
    property_of {
      integer(1..3)
    }.check(100) do |subfolder_count|
      account = create(:account)
      author  = create(:user, account:)

      # Create root folder
      root = create(:template_folder, account:, author:)

      # Create 1..3 subfolders under root
      subfolders = Array.new(subfolder_count) do
        create(:template_folder, account:, author:, parent_folder: root)
      end

      all_folders = [root] + subfolders

      # Create at least one permission record per folder so there is something to cascade
      all_folders.each do |folder|
        permitted_user = create(:user, account:)
        create(:template_folder_permission, template_folder: folder, user: permitted_user)
      end

      all_folder_ids = all_folders.map(&:id)

      # Sanity check: permission records exist before destroy
      expect(TemplateFolderPermission.where(template_folder_id: all_folder_ids).count).to eq(all_folders.size)

      root.destroy!

      # After destroying the root, zero permission records should remain for any folder in the subtree
      remaining = TemplateFolderPermission.where(template_folder_id: all_folder_ids).count
      expect(remaining).to eq(0)
    end
  end

  # Property 15: Permitted users query round-trip
  # Validates: Requirements 9.1, 9.2, 9.3, 9.5
  it 'permitted_users includes explicit active users, owner, and admins but excludes archived users' do
    property_of {
      integer(1..4)
    }.check(100) do |n|
      account = create(:account)
      owner   = create(:user, account:, role: 'editor')
      folder  = create(:template_folder, account:, author: owner)

      # N active users with explicit permissions
      active_permitted = Array.new(n) do
        u = create(:user, account:, role: 'editor')
        create(:template_folder_permission, user: u, template_folder: folder)
        u
      end

      # 1 archived user with an explicit permission
      archived_user = create(:user, account:, role: 'editor', archived_at: Time.current)
      create(:template_folder_permission, user: archived_user, template_folder: folder)

      # 1 admin (no explicit permission needed)
      admin_user = create(:user, account:, role: 'admin')

      result_ids = TemplateFolderPermissions.permitted_users(folder).pluck(:id)

      # Must include all N active permitted users
      active_permitted.each do |u|
        expect(result_ids).to include(u.id)
      end

      # Must include the owner
      expect(result_ids).to include(owner.id)

      # Must include the admin
      expect(result_ids).to include(admin_user.id)

      # Must exclude the archived user
      expect(result_ids).not_to include(archived_user.id)
    end
  end

  # Property 16: Unrestricted folder returns all active account users
  # Validates: Requirements 9.4
  it 'permitted_users returns all active account users for an unrestricted folder' do
    property_of {
      integer(1..5)
    }.check(100) do |m|
      account = create(:account)
      owner   = create(:user, account:, role: 'editor')
      folder  = create(:template_folder, account:, author: owner)

      # M active users (including owner already created above)
      active_users = [owner] + Array.new(m - 1) { create(:user, account:, role: 'editor') }

      # 1 archived user
      archived_user = create(:user, account:, role: 'editor', archived_at: Time.current)

      # No permission records — folder is unrestricted
      result_ids = TemplateFolderPermissions.permitted_users(folder).pluck(:id)

      active_users.each do |u|
        expect(result_ids).to include(u.id)
      end

      expect(result_ids).not_to include(archived_user.id)
    end
  end
end
