# Requirements Document

## Introduction

This document specifies requirements for a dedicated settings page in NexusSign that allows folder owners and admins to manage folder view permissions through a web-based interface. The backend API for folder view permissions already exists (implemented in the `folder-view-permissions` spec). This feature provides the server-rendered UI (ERB templates with Turbo/Stimulus) that consumes those API endpoints, following the established settings page patterns in the application.

## Glossary

- **Permissions_Settings_Page**: The dedicated settings page where folder owners and admins manage view permissions for folders
- **Folder_Selector**: A UI component that allows the user to choose which folder's permissions to view and manage
- **User_List**: The rendered table of users who currently have view access to the selected folder
- **Grant_Form**: A UI component that allows the folder owner or admin to select a user from the account and grant view access
- **Revoke_Button**: A UI control that removes a user's view permission from the selected folder
- **Settings_Navigation**: The shared sidebar navigation menu rendered on all settings pages via the `_settings_nav` partial
- **Folder_Owner**: The user who created the folder (referenced by author_id in TemplateFolder)
- **Permission_System**: The existing backend subsystem responsible for managing and enforcing folder view permissions
- **Current_User**: The authenticated user accessing the settings page

## Requirements

### Requirement 1: Settings Page Navigation Entry

**User Story:** As a folder owner or admin, I want to find the folder permissions page in the settings navigation, so that I can access permission management without leaving the settings area.

#### Acceptance Criteria

1. IF the Current_User has admin role, THEN THE Settings_Navigation SHALL display a link labeled "Folder Permissions" that navigates to the Permissions_Settings_Page
2. IF the Current_User has editor role AND owns at least one TemplateFolder, THEN THE Settings_Navigation SHALL display the "Folder Permissions" link
3. IF the Current_User has editor role AND does not own any TemplateFolder, THEN THE Settings_Navigation SHALL hide the "Folder Permissions" link
4. IF the Current_User has viewer role, THEN THE Settings_Navigation SHALL hide the "Folder Permissions" link
5. THE "Folder Permissions" link SHALL be placed immediately after the "Users" link in the Settings_Navigation sidebar

### Requirement 2: Settings Page Layout and Structure

**User Story:** As a folder owner or admin, I want the permissions page to follow the same layout as other settings pages, so that the interface feels consistent and familiar.

#### Acceptance Criteria

1. THE Permissions_Settings_Page SHALL render the Settings_Navigation sidebar as the first element in the page layout container
2. THE Permissions_Settings_Page SHALL display a page title "Folder Permissions" in the main content area
3. THE Permissions_Settings_Page SHALL display the Folder_Selector below the page title
4. WHEN a folder is selected, THE Permissions_Settings_Page SHALL display the User_List and Grant_Form below the Folder_Selector
5. IF no folder is selected, THEN THE Permissions_Settings_Page SHALL display only the page title and the Folder_Selector without rendering the User_List or Grant_Form
6. THE Permissions_Settings_Page SHALL use the same flex wrapper layout as existing settings pages, including a left-side navigation area, a centered content area with a maximum width constraint, and a right-side spacer for balanced centering
7. THE Permissions_Settings_Page SHALL stack the navigation above the content area on viewports narrower than the medium breakpoint

### Requirement 3: Folder Selector

**User Story:** As a folder owner or admin, I want to select a folder from my available folders, so that I can manage permissions for that specific folder.

#### Acceptance Criteria

1. THE Folder_Selector SHALL display a dropdown or list of TemplateFolders that the Current_User is authorized to manage permissions for
2. IF the Current_User has admin role, THEN THE Folder_Selector SHALL list all active TemplateFolders in the Account
3. IF the Current_User is not an admin, THEN THE Folder_Selector SHALL list only active TemplateFolders owned by the Current_User
4. THE Folder_Selector SHALL display each folder's name as the label, truncated to a maximum of 100 characters with an ellipsis if exceeded
5. WHEN a folder has a parent_folder_id, THE Folder_Selector SHALL display the folder path in "Parent / Child" format to distinguish folders with identical names
6. WHEN the Current_User selects a folder, THE Permissions_Settings_Page SHALL load and display the User_List for that folder within 3 seconds
7. IF the Current_User has no TemplateFolders eligible for permission management, THEN THE Folder_Selector SHALL display an empty state message indicating no folders are available
8. IF the folder list fails to load, THEN THE Folder_Selector SHALL display an error message indicating the failure and provide a retry option

### Requirement 4: Display Permitted Users List

**User Story:** As a folder owner or admin, I want to see which users have access to the selected folder, so that I can audit current permissions.

#### Acceptance Criteria

1. WHEN a folder is selected, THE User_List SHALL display all users who currently have view access to that folder, sorted alphabetically by last name then first name
2. THE User_List SHALL display each user's first name, last name, email address, and role
3. WHEN the selected folder is unrestricted (no explicit permissions configured), THE User_List SHALL display a message indicating all account members have access
4. THE User_List SHALL display a label of "Owner" next to the Folder_Owner entry to distinguish them from other permitted users
5. THE User_List SHALL display a label of "Admin" next to admin users who have access by role rather than by explicit permission
6. THE User_List SHALL exclude archived users from the displayed list
7. IF the Permission_System fails to retrieve the permitted users list, THEN THE User_List SHALL display an error message indicating the list could not be loaded and the previously displayed content SHALL be cleared
8. WHEN a restricted folder has more than 50 permitted users, THE User_List SHALL support scrolling to allow viewing all entries without truncation

### Requirement 5: Grant View Permission via UI

**User Story:** As a folder owner or admin, I want to grant view access to a user through the interface, so that I can share folder access without using the API directly.

#### Acceptance Criteria

1. WHILE the Current_User is the Folder_Owner or has admin role, THE Grant_Form SHALL display a mechanism to select a user from the Account's active users
2. THE Grant_Form SHALL exclude users who already have view access to the selected folder (including the Folder_Owner and admin users)
3. IF the Current_User submits the Grant_Form without selecting a user, THEN THE Grant_Form SHALL display a validation error indicating that a user must be selected and SHALL NOT call the Permission_System grant endpoint
4. WHEN the Current_User submits the Grant_Form with a selected user, THE Permissions_Settings_Page SHALL call the Permission_System grant endpoint
5. WHEN a grant operation succeeds, THE Permissions_Settings_Page SHALL update the User_List to include the newly permitted user and remove that user from the Grant_Form's selectable user list without a full page reload
6. IF the grant operation fails, THEN THE Permissions_Settings_Page SHALL display an error message indicating the reason for failure

### Requirement 6: Revoke View Permission via UI

**User Story:** As a folder owner or admin, I want to revoke view access from a user through the interface, so that I can remove access when it is no longer needed.

#### Acceptance Criteria

1. THE User_List SHALL display a Revoke_Button next to each user who has an explicit view permission
2. THE User_List SHALL hide the Revoke_Button for the Folder_Owner (owner access cannot be revoked)
3. THE User_List SHALL hide the Revoke_Button for admin users (admin access is granted by role)
4. WHEN the Current_User clicks the Revoke_Button, THE Permissions_Settings_Page SHALL display a confirmation prompt that identifies the user whose access will be revoked and presents a confirm action and a cancel action
5. WHEN the Current_User selects the cancel action on the confirmation prompt, THE Permissions_Settings_Page SHALL dismiss the prompt and leave the User_List unchanged
6. WHEN a revoke operation is confirmed, THE Permissions_Settings_Page SHALL call the Permission_System revoke endpoint
7. WHEN a revoke operation succeeds, THE Permissions_Settings_Page SHALL remove the user from the User_List without a full page reload
8. IF a revoke operation fails, THEN THE Permissions_Settings_Page SHALL display an error message indicating the revoke was unsuccessful and SHALL retain the user in the User_List
9. IF the Current_User is neither the Folder_Owner nor an admin, THEN THE Permissions_Settings_Page SHALL not display the Revoke_Button for any user

### Requirement 7: Authorization and Access Control

**User Story:** As the system, I want to restrict access to the permissions settings page, so that only authorized users can manage folder permissions.

#### Acceptance Criteria

1. WHEN an unauthenticated user requests the Permissions_Settings_Page, THE application SHALL redirect to the login page before processing the request
2. IF a user without folder ownership or admin role requests the Permissions_Settings_Page for a TemplateFolder, THEN THE application SHALL redirect the user to the application root with an authorization error message
3. IF a non-admin user attempts to grant or revoke permissions for a TemplateFolder they do not own, THEN THE application SHALL deny the operation and redirect to the application root with an authorization error message
4. THE Permissions_Settings_Page SHALL only display and allow managing permissions for TemplateFolders within the Current_User's Account
5. IF a user requests the Permissions_Settings_Page for a TemplateFolder that does not exist within their Account, THEN THE application SHALL respond with a not-found error
6. WHEN a user with admin role requests the Permissions_Settings_Page for any TemplateFolder in their Account, THE application SHALL grant access regardless of folder ownership

### Requirement 8: Responsive and Accessible Interface

**User Story:** As a user, I want the permissions page to be usable on different screen sizes and with assistive technology, so that all users can manage permissions effectively.

#### Acceptance Criteria

1. WHILE the viewport width is below 768px, THE Permissions_Settings_Page SHALL render all interactive controls without requiring horizontal scrolling and with touch targets of at least 44x44 CSS pixels
2. WHILE the viewport width is below 768px, THE Permissions_Settings_Page SHALL collapse the Settings_Navigation into a full-width stacked layout above the content area, using the flex-wrap pattern established by other settings pages
3. THE Folder_Selector SHALL be operable using keyboard navigation, allowing users to move focus via Tab key and confirm selection via Enter or Space key
4. THE Grant_Form SHALL be operable using keyboard navigation, allowing users to move focus between form controls via Tab key, open selection menus via Enter or Space key, and submit the form via Enter key
5. THE Revoke_Button SHALL have an accessible label that includes the name or email of the user being removed, such that screen readers announce which user's permission will be revoked
6. THE User_List table SHALL use semantic HTML table elements with column headers using th elements and row scope attributes for screen reader compatibility
7. WHEN a view permission is granted or revoked, THE Permissions_Settings_Page SHALL update the User_List and provide a visible status message within 1 second confirming the operation result

### Requirement 9: Empty and Loading States

**User Story:** As a user, I want clear feedback when the page is loading or when no data is available, so that I understand the current state of the interface.

#### Acceptance Criteria

1. WHEN the Permissions_Settings_Page first loads with no folder selected, THE page SHALL display instructional text prompting the user to select a folder from the folder list
2. WHEN the selected folder has no explicitly permitted users (unrestricted), THE page SHALL display an informational message explaining that all account users have access
3. WHEN the Account has only one user, THE Grant_Form SHALL display a message indicating no additional users are available to add
4. WHEN a grant or revoke operation is in progress, THE Permissions_Settings_Page SHALL disable the submit button and user selection controls until the operation completes or fails
5. WHEN the Permissions_Settings_Page is fetching the permitted users list for a selected folder, THE page SHALL display a loading indicator in the permissions list area until the data is returned
6. IF a grant or revoke operation fails, THEN THE Permissions_Settings_Page SHALL re-enable all disabled form controls and display an error message indicating the operation did not succeed
