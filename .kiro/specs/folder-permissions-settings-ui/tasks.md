# Implementation Plan: Folder Permissions Settings UI

## Overview

Implement a dedicated settings page for managing folder view permissions through a web-based interface. This is a presentation layer that consumes the existing `TemplateFolderPermissions` JSON API (implemented in the `folder-view-permissions` spec). The implementation includes a new `FolderPermissionsSettingsController`, an ERB view following the standard settings page layout, a `<folder-permissions-manager>` custom element for client-side interactions, a route entry, a settings navigation update, and the custom element registration in `application.js`.

---

## Tasks

- [x] 1. Create the controller and route
  - [x] 1.1 Create `FolderPermissionsSettingsController` at `app/controllers/folder_permissions_settings_controller.rb`
    - Implement `show` action that loads `@folders` (manageable folders) and `@users` (active non-integration account users sorted by last_name, first_name)
    - Add `before_action :authorize_access` that redirects non-admin users who don't own any folders to `root_path` with an alert
    - Implement `manageable_folders` private method: all active folders for admins, only owned active folders for non-admins
    - Use `skip_authorization_check` since access is handled by the custom before_action
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.6, 3.2, 3.3_

  - [x] 1.2 Add route for the settings page in `config/routes.rb`
    - Add `resource :folder_permissions, only: %i[show], controller: 'folder_permissions_settings'` inside the `scope '/settings'` block
    - This generates `GET /settings/folder_permissions` with helper `settings_folder_permissions_path`
    - _Requirements: 1.1, 2.1_

- [x] 2. Create the settings page view and update navigation
  - [x] 2.1 Create `app/views/folder_permissions_settings/show.html.erb`
    - Use the three-column flex wrapper layout: `_settings_nav` partial on left, `max-w-xl` centered content, spacer `div` on right
    - Include the `<folder-permissions-manager>` custom element wrapping the folder selector, permissions panel, user list table, grant form, and status message areas
    - Pass `@users` as JSON via `data-users` attribute on the custom element
    - Pass CSRF token via `data-csrf` attribute
    - Render folder `<select>` with all `@folders`, each option storing `data-owner-id`
    - Implement empty state when no folders are available
    - Use semantic HTML table with `<th scope="col">` for the user list
    - Include loading indicator, error message, unrestricted message, and grant form containers with appropriate IDs
    - Ensure touch targets are at least 44x44px for buttons, and `flex-wrap` for responsive stacking
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.1, 3.4, 3.5, 3.7, 4.8, 8.1, 8.2, 8.3, 8.4, 8.6, 9.1, 9.2_

  - [x] 2.2 Update `_settings_nav.html.erb` to include "Folder Permissions" link
    - Add the link immediately after the "Users" link
    - Conditionally display: show for admins OR for editors who own at least one active folder
    - Hide for viewers and editors without folders
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

- [x] 3. Implement the `<folder-permissions-manager>` custom element
  - [x] 3.1 Create `app/javascript/elements/folder_permissions_manager.js`
    - Implement `connectedCallback` to bind DOM references and event listeners
    - Implement `disconnectedCallback` to clean up event listeners
    - Implement `onFolderChange` handler: reads selected folder ID and owner ID, shows permissions panel, calls `loadPermissions()`
    - Implement `loadPermissions`: fetches `GET /folders/:id/permissions` with JSON accept header, renders user list on success, shows error on failure
    - Implement `renderUserList`: sorts users alphabetically by last_name then first_name, generates table rows with name, email, role columns, adds Owner/Admin badges, conditionally shows Revoke button (hidden for owner and admin users)
    - Implement `onRevokeClick`: shows `confirm()` dialog identifying the user, calls `revokeAccess` on confirmation
    - Implement `revokeAccess`: sends `DELETE /folders/:id/permissions/:user_id` with CSRF token, removes row from DOM on success, shows error toast on failure, re-enables controls
    - Implement `onGrant`: validates user selection, sends `POST /folders/:id/permissions` with user_id body and CSRF token, reloads permissions on success, shows error on failure
    - Implement `updateGrantForm`: filters `allUsers` to exclude currently permitted users, populates user select dropdown, shows "no users available" message when empty
    - Implement `showStatus`: displays success/error toast with auto-dismiss after 3 seconds, uses `aria-live="polite"` for screen reader announcements
    - Implement `setFormDisabled`: disables/enables grant button, user select, and all revoke buttons during operations
    - Implement `escapeHtml` utility for XSS prevention
    - Ensure Revoke button `aria-label` includes user name/email for screen reader identification
    - _Requirements: 3.6, 3.8, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 6.9, 8.5, 8.7, 9.3, 9.4, 9.5, 9.6_

  - [x] 3.2 Register the custom element in `app/javascript/application.js`
    - Import `FolderPermissionsManager` from `./elements/folder_permissions_manager`
    - Call `safeRegisterElement('folder-permissions-manager', FolderPermissionsManager)`
    - _Requirements: 3.6 (folder selection triggers load)_

- [x] 4. Add I18n translations
  - [x] 4.1 Add locale entries for the folder permissions settings page
    - Add keys to the appropriate locale file (e.g., `config/locales/en.yml` or the relevant locale YAML)
    - Keys needed: `folder_permissions`, `select_folder`, `choose_a_folder`, `permitted_users`, `all_account_members_have_access`, `grant_access`, `select_user`, `select_user_to_grant_access`, `choose_a_user`, `grant`, `no_additional_users_available`, `no_folders_available_for_permission_management`, `not_authorized` (if not already present)
    - _Requirements: 2.2, 3.7, 9.1, 9.2, 9.3_

- [x] 5. Checkpoint — Ensure page loads and navigation works
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 6. Write controller and view tests
  - [ ]* 6.1 Write request specs for `FolderPermissionsSettingsController`
    - File: `spec/requests/folder_permissions_settings_spec.rb`
    - Test: admin can access the settings page (200 response)
    - Test: folder owner (editor) can access the settings page (200 response)
    - Test: editor without folders is redirected with authorization error
    - Test: viewer role is redirected with authorization error
    - Test: unauthenticated user is redirected to login
    - Test: admin sees all active account folders in the response body
    - Test: editor sees only owned folders in the response body
    - Test: page renders user data JSON in the data-users attribute
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.6, 3.2, 3.3_

  - [ ]* 6.2 Write view specs for `show.html.erb`
    - File: `spec/views/folder_permissions_settings/show.html.erb_spec.rb`
    - Test: navigation link appears for admin users
    - Test: navigation link appears for editors who own folders
    - Test: navigation link hidden for editors without folders
    - Test: navigation link hidden for viewers
    - Test: folder names are truncated at 100 characters with ellipsis
    - Test: folder paths display in "Parent / Child" format for nested folders
    - Test: empty state message shown when no folders available
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 3.4, 3.5, 3.7_

  - [ ]* 6.3 Write system tests for permissions page interactions
    - File: `spec/system/folder_permissions_settings_spec.rb`
    - Test: selecting a folder loads and displays the permitted users list
    - Test: granting access updates the list without full page reload
    - Test: revoking access removes the user from the list without full page reload
    - Test: confirmation dialog appears before revoke; cancel leaves list unchanged
    - Test: Owner and Admin badges display correctly
    - Test: Revoke button hidden for owner and admin users
    - Test: empty state messages display when no folders available
    - Test: unrestricted folder shows informational message
    - Test: error states display when API calls fail
    - Test: grant form disables during in-progress operation
    - _Requirements: 4.1, 4.3, 4.4, 4.5, 5.2, 5.4, 5.5, 5.6, 6.1, 6.2, 6.3, 6.4, 6.5, 6.7, 6.8, 9.1, 9.2, 9.4, 9.5, 9.6_

- [x] 7. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

---

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- This feature is a UI presentation layer only — all permission business logic is in the existing `TemplateFolderPermissions` service module
- Property-based tests are not applicable here because the feature is server-rendered HTML with client-side DOM manipulation; the underlying permission logic is already covered by PBT in the `folder-view-permissions` spec
- The `<folder-permissions-manager>` custom element follows the same lightweight pattern as existing custom elements in `app/javascript/elements/`
- The route uses `resource` (singular) since there is only one settings page (not RESTful collection)
- The `data-users` attribute serializes all active account users at page load to avoid extra API calls for the grant form dropdown
- Checkpoints at tasks 5 and 7 ensure incremental validation

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2"] },
    { "id": 1, "tasks": ["2.1", "2.2", "4.1"] },
    { "id": 2, "tasks": ["3.1"] },
    { "id": 3, "tasks": ["3.2"] },
    { "id": 4, "tasks": ["6.1", "6.2", "6.3"] }
  ]
}
```
