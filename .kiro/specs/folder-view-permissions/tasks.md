# Implementation Plan: Folder View Permissions

## Overview

Implement opt-in view-permission access control for `TemplateFolder` records. A new `template_folder_permissions` join table and `TemplateFolderPermission` model store explicit grants. A `TemplateFolderPermissions` service module centralises all permission logic (grant, revoke, can_view?, visible_to, permitted_users). Controllers are updated to filter folder listings through the service, and a new `TemplateFolderPermissionsController` exposes the grant/revoke API surface. Cascade cleanup is handled via `dependent: :destroy` on both `TemplateFolder` and `User`. Property-based tests use the `rantly` gem.

---

## Tasks

- [x] 1. Add `rantly` gem and create database migration
  - [x] 1.1 Add `rantly` gem to the test group in `Gemfile` and run `bundle install`
    - Add `gem 'rantly'` to the `group :test` block in `Gemfile`
    - Run `bundle install` to resolve and lock the gem
    - _Requirements: Testing infrastructure for Properties 1–16_

  - [x] 1.2 Generate and write the `CreateTemplateFolderPermissions` migration
    - Create `db/migrate/YYYYMMDDHHMMSS_create_template_folder_permissions.rb`
    - Table columns: `t.references :template_folder, null: false, foreign_key: true, index: false` and `t.references :user, null: false, foreign_key: false, index: false` plus `t.timestamps`
    - Add composite unique index: `t.index %i[template_folder_id user_id], unique: true, name: 'idx_tfp_on_folder_and_user'`
    - `foreign_key: false` on `user_id` mirrors the `template_accesses` pattern (app-layer cleanup, not DB cascade)
    - Run `rails db:migrate` to apply
    - _Requirements: 1.1, 1.2, 7.1, 8.1, 10.4, 10.5_

- [x] 2. Implement the `TemplateFolderPermission` model
  - [x] 2.1 Create `app/models/template_folder_permission.rb`
    - `belongs_to :template_folder` and `belongs_to :user`
    - `validates :user_id, uniqueness: { scope: :template_folder_id }` (no-duplicate invariant)
    - Custom validation `user_and_folder_same_account` that adds an error when `user.account_id != template_folder.account_id`
    - _Requirements: 1.2, 1.3, 10.3, 10.4, 10.5_

  - [x] 2.2 Write unit tests for `TemplateFolderPermission` model
    - File: `spec/models/template_folder_permission_spec.rb`
    - Test: uniqueness validation rejects duplicate `(user_id, template_folder_id)` pairs
    - Test: cross-account validation adds error when user and folder belong to different accounts
    - Test: valid record saves successfully when user and folder share the same account
    - _Requirements: 1.2, 1.3, 10.3_

- [x] 3. Add associations and `dependent: :destroy` to `TemplateFolder` and `User` models
  - [x] 3.1 Update `app/models/template_folder.rb`
    - Add `has_many :template_folder_permissions, dependent: :destroy`
    - Add `has_many :permitted_users, through: :template_folder_permissions, source: :user`
    - _Requirements: 8.1, 8.4_

  - [x] 3.2 Update `app/models/user.rb`
    - Add `has_many :template_folder_permissions, dependent: :destroy`
    - _Requirements: 7.1_

  - [x] 3.3 Write property test for cascade deletion on user destroy (Property 12)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 12: User deletion cascades all permission records**
    - **Validates: Requirements 7.1**
    - Use `property_of` to generate a user with N permission records across M folders; destroy the user; assert zero `TemplateFolderPermission` records remain for that `user_id`

  - [x] 3.4 Write property test for cascade deletion on folder destroy (Property 14)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 14: Folder deletion cascades all permission records**
    - **Validates: Requirements 8.1, 8.4**
    - Use `property_of` to generate a folder hierarchy with permission records at multiple levels; destroy the root folder; assert zero `TemplateFolderPermission` records remain for any folder in the subtree

- [x] 4. Create the `TemplateFolderPermissions` service module
  - [x] 4.1 Create `lib/template_folder_permissions.rb` with `module_function` interface
    - Implement `restricted?(folder)` — returns `folder.template_folder_permissions.exists?`
    - Implement private `node_accessible?(user, folder)` — owner bypass, unrestricted bypass, explicit permission check
    - Implement private `ancestor_chain(folder)` — walks `parent_folder` chain root-to-leaf using a `Set` cycle guard
    - Implement `can_view?(user, folder)` — admin bypass, owner bypass, archived-user denial, ancestor walk, then `node_accessible?`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 5.1–5.5, 6.1–6.5, 7.2_

  - [x] 4.2 Implement `visible_to(folders_scope, user)` in the service module
    - Admin short-circuit returns full scope
    - Build `owned`, `unrestricted` (NOT EXISTS subquery), and `permitted` (joins) sub-relations
    - Union via `.or`, pluck candidate IDs, filter with `can_view?`, return `folders_scope.where(id: accessible_ids)`
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

  - [x] 4.3 Implement `grant(user, folder)` and `revoke(user, folder)` in the service module
    - `grant`: `TemplateFolderPermission.find_or_create_by!(user:, template_folder: folder)` — idempotent
    - `revoke`: `TemplateFolderPermission.where(user:, template_folder: folder).destroy_all` — no-op if absent
    - _Requirements: 1.1, 1.2, 2.1, 2.4_

  - [x] 4.4 Implement `permitted_users(folder)` in the service module
    - For unrestricted folders: return `account.users.active`
    - For restricted folders: return active users matching explicit permission IDs, owner, or admin role
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 4.5 Write property test for `grant` idempotency (Property 1)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 1: Permission grant creates a record**
    - **Validates: Requirements 1.1, 1.2**
    - `property_of` generates N (1..5) grant calls for the same user-folder pair; assert exactly one `TemplateFolderPermission` record exists after all calls

  - [x] 4.6 Write property test for cross-account grant rejection (Property 2)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 2: Cross-account grant is rejected**
    - **Validates: Requirements 1.3, 10.3**
    - `property_of` generates user from account A and folder from account B (A ≠ B); assert `grant` raises `ActiveRecord::RecordInvalid` and no permission record is created

  - [x] 4.7 Write property test for `revoke` idempotency (Property 3)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 3: Permission revoke is idempotent**
    - **Validates: Requirements 2.1, 2.4**
    - `property_of` generates a user-folder pair with or without an existing permission; call `revoke` twice; assert zero records remain and no error is raised

  - [x] 4.8 Write property test for owner always has view access (Property 4)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 4: Owner always has view access**
    - **Validates: Requirements 3.1, 5.1**
    - `property_of` generates a folder (restricted or unrestricted); assert `can_view?(folder.author, folder)` is always `true`

  - [x] 4.9 Write property test for explicit permission grants access (Property 5)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 5: Explicit permission grants view access**
    - **Validates: Requirements 3.2, 5.5**
    - `property_of` generates a restricted folder and a user with an explicit permission record; assert `can_view?` returns `true`

  - [x] 4.10 Write property test for unrestricted folders visible to all (Property 6)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 6: Unrestricted folders are visible to all account members**
    - **Validates: Requirements 3.3, 5.3**
    - `property_of` generates an unrestricted folder and any active account user; assert `can_view?` returns `true`

  - [x] 4.11 Write property test for restricted folders deny unpermitted users (Property 7)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 7: Restricted folders deny unpermitted users**
    - **Validates: Requirements 3.4, 5.2**
    - `property_of` generates a restricted folder and a non-owner, non-admin user without an explicit permission; assert `can_view?` returns `false`

  - [x] 4.12 Write property test for admin always has view access (Property 8)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 8: Admin users always have view access**
    - **Validates: Requirements 3.5, 5.4**
    - `property_of` generates any folder and an admin user in the same account; assert `can_view?` returns `true`

  - [x] 4.13 Write property test for `visible_to` consistency with `can_view?` (Property 9)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 9: Folder listing returns only accessible folders**
    - **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.5**
    - `property_of` generates a mixed collection of restricted and unrestricted folders and a non-admin user; assert `visible_to` returns exactly the subset for which `can_view?` is `true`

  - [x] 4.14 Write property test for ancestor access grants descendant access (Property 10)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 10: Ancestor access grants descendant access**
    - **Validates: Requirements 6.1**
    - `property_of` generates a multi-level hierarchy where the user has access to the root; assert `can_view?` returns `true` for all descendants (assuming descendants are not independently restricted against the user)

  - [x] 4.15 Write property test for blocked ancestor denies all descendants (Property 11)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 11: Blocked ancestor denies all descendants**
    - **Validates: Requirements 6.2, 6.3, 6.5**
    - `property_of` generates a hierarchy where the user lacks access to an ancestor; assert `can_view?` returns `false` for all descendants regardless of any explicit permissions on the descendant

  - [x] 4.16 Write property test for archived users denied access (Property 13)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 13: Archived users are denied access to restricted folders**
    - **Validates: Requirements 7.2**
    - `property_of` generates a restricted folder and an archived user (non-nil `archived_at`) with an explicit permission record; assert `can_view?` returns `false`

  - [x] 4.17 Write property test for `permitted_users` round-trip (Property 15)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 15: Permitted users query round-trip**
    - **Validates: Requirements 9.1, 9.2, 9.3, 9.5**
    - `property_of` generates a restricted folder with N explicit permission records for active users; assert `permitted_users` includes exactly those N users plus owner and admins, and excludes archived users even if they hold a permission record

  - [x] 4.18 Write property test for unrestricted folder returns all active users (Property 16)
    - File: `spec/lib/template_folder_permissions_property_spec.rb`
    - **Property 16: Unrestricted folder returns all active account users**
    - **Validates: Requirements 9.4**
    - `property_of` generates an unrestricted folder in an account with M active users; assert `permitted_users` returns all M active users

- [x] 5. Checkpoint — Ensure service module tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Create the `TemplateFolderPermissionsController` and factory
  - [x] 6.1 Create `spec/factories/template_folder_permissions.rb`
    - Define `factory :template_folder_permission` with `template_folder` and `user` associations
    - _Requirements: Test infrastructure for 1.1, 2.1, 9.1_

  - [x] 6.2 Create `app/controllers/template_folder_permissions_controller.rb`
    - `before_action :load_folder` — `current_account.template_folders.find(params[:folder_id])`
    - `before_action :authorize_owner_or_admin` — raises `CanCan::AccessDenied` for non-owner, non-admin
    - `index` action — calls `TemplateFolderPermissions.permitted_users(@template_folder)`, renders JSON with `%i[id email first_name last_name role]`
    - `create` action — finds active user by `params[:user_id]`, calls `TemplateFolderPermissions.grant`, returns `head :created`; rescues `RecordNotFound` (404) and `RecordInvalid` (422)
    - `destroy` action — finds user by `params[:id]`, calls `TemplateFolderPermissions.revoke`, returns `head :no_content`
    - _Requirements: 1.1, 1.3, 2.1, 2.4, 9.1, 9.2, 9.3, 10.1, 10.2, 10.3_

  - [x] 6.3 Add routes for `TemplateFolderPermissionsController` in `config/routes.rb`
    - Nest permissions under folders: inside the `resources :folders` block (or alongside it), add:
      ```ruby
      resources :folders, only: %i[show edit update destroy], controller: 'template_folders' do
        resources :permissions, only: %i[index create destroy], controller: 'template_folder_permissions'
      end
      ```
    - This produces: `GET /folders/:folder_id/permissions`, `POST /folders/:folder_id/permissions`, `DELETE /folders/:folder_id/permissions/:id`
    - _Requirements: 1.1, 2.1, 9.1_

  - [x] 6.4 Write integration tests for `TemplateFolderPermissionsController`
    - File: `spec/requests/template_folder_permissions_spec.rb`
    - `GET /folders/:folder_id/permissions` — owner gets 200 with correct user list; non-owner/non-admin gets redirect (CanCan::AccessDenied)
    - `POST /folders/:folder_id/permissions` — creates permission record, returns 201; cross-account user returns 422; unknown user returns 404
    - `DELETE /folders/:folder_id/permissions/:id` — removes record, returns 204; no-op on missing user still returns 204
    - _Requirements: 1.1, 1.3, 2.1, 2.4, 9.1_

- [x] 7. Update `Ability` model for `TemplateFolderPermission` authorization
  - [x] 7.1 Update `app/models/ability.rb`
    - In the `editor` branch, add: `can :manage, TemplateFolderPermission, template_folder: { account_id: user.account_id, author_id: user.id }`
    - Admin already has `can :manage, :all` — no change needed
    - Viewer role does not receive permission management ability
    - _Requirements: 5.2, 5.4_

  - [x] 7.2 Write unit tests for `Ability` permission rules
    - File: `spec/models/ability_spec.rb` (create if absent)
    - Test: admin can manage any `TemplateFolderPermission`
    - Test: editor can manage `TemplateFolderPermission` for folders they own
    - Test: editor cannot manage `TemplateFolderPermission` for folders owned by another user
    - Test: viewer cannot manage `TemplateFolderPermission`
    - _Requirements: 5.2, 5.4_

- [x] 8. Update `TemplatesDashboardController` to filter folders through `visible_to`
  - [x] 8.1 Modify `app/controllers/templates_dashboard_controller.rb` `index` action
    - Replace the direct `@template_folders.where(parent_folder_id: nil)` call with:
      ```ruby
      permitted_folders = TemplateFolderPermissions.visible_to(
        @template_folders.where(parent_folder_id: nil),
        current_user
      )
      @template_folders = TemplateFolders.filter_active_folders(permitted_folders, @templates)
      ```
    - Ensure `require` or autoload for `TemplateFolderPermissions` is in place (add to `config/application.rb` eager load paths if needed)
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [x] 9. Update `TemplateFoldersController` to filter subfolders through `visible_to`
  - [x] 9.1 Modify `app/controllers/template_folders_controller.rb` `show` action
    - Replace the `@template_folders` assignment with:
      ```ruby
      raw_subfolders = @template_folder.subfolders
                                       .where(id: Template.accessible_by(current_ability).active.select(:folder_id))
      @template_folders = TemplateFolderPermissions.visible_to(raw_subfolders, current_user)
      ```
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 6.1–6.5_

  - [x] 9.2 Write unit tests for `TemplateFolderPermissions` service module (example-based)
    - File: `spec/lib/template_folder_permissions_spec.rb`
    - `can_view?`: owner returns true; admin returns true; archived user returns false; unrestricted folder returns true for any active user; restricted folder returns false for unpermitted user; explicit permission returns true
    - `visible_to`: returns only accessible folders for a non-admin user; returns all folders for admin
    - `permitted_users`: restricted folder returns owner + admins + explicit users, excludes archived; unrestricted folder returns all active account users
    - `grant` / `revoke`: grant is idempotent; revoke is a no-op when record absent
    - _Requirements: 3.1–3.5, 4.1–4.5, 9.1–9.5_

- [x] 10. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

---

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- Property tests use the `rantly` gem (`property_of { ... }.check(100) { ... }`) and are tagged `:property`
- The `rantly` gem must be added to `Gemfile` (task 1.1) before any property test files are created
- `TemplateFolderPermissions` module lives in `lib/` and follows the same `module_function` pattern as `TemplateFolders`
- Ensure `lib/` is in Rails' autoload/eager-load paths (check `config/application.rb`); if not, add `config.autoload_lib(ignore: %w[assets tasks])` or a targeted `config.eager_load_paths << Rails.root.join('lib')`
- The `foreign_key: false` on `user_id` in the migration is intentional — mirrors `template_accesses` and lets ActiveRecord `dependent: :destroy` handle cleanup
- Checkpoints at tasks 5 and 10 ensure incremental validation before wiring controllers

---

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2"] },
    { "id": 1, "tasks": ["2.1", "3.1", "3.2", "6.1"] },
    { "id": 2, "tasks": ["2.2", "3.3", "3.4", "4.1"] },
    { "id": 3, "tasks": ["4.2", "4.3", "4.4"] },
    { "id": 4, "tasks": ["4.5", "4.6", "4.7", "4.8", "4.9", "4.10", "4.11", "4.12", "4.13", "4.14", "4.15", "4.16", "4.17", "4.18"] },
    { "id": 5, "tasks": ["6.2", "7.1"] },
    { "id": 6, "tasks": ["6.3", "6.4", "7.2", "9.2"] },
    { "id": 7, "tasks": ["8.1", "9.1"] }
  ]
}
```
