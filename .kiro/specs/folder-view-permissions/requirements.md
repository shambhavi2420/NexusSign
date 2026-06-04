# Requirements Document

## Introduction

This document specifies requirements for adding view permissions to template folders in the NexusSign application. Currently, all users within an account can view all folders. This feature introduces access control to allow folder owners to restrict which users can view specific folders and their contents.

## Glossary

- **TemplateFolder**: A folder that organizes templates within an account, supporting nested hierarchies via parent_folder_id
- **Folder_Owner**: The user who created the folder (referenced by author_id in TemplateFolder)
- **Account**: An organization or workspace that contains users, folders, and templates
- **User**: An individual with access to an account, having one of three roles: admin, editor, or viewer
- **View_Permission**: An access control record that grants a specific user the ability to view a specific folder
- **Permission_System**: The subsystem responsible for managing and enforcing folder view permissions
- **Folder_Hierarchy**: The tree structure of folders created through parent-child relationships
- **Restricted_Folder**: A folder that has explicit view permissions configured, limiting access to specified users
- **Unrestricted_Folder**: A folder without explicit view permissions, accessible to all users in the account

## Requirements

### Requirement 1: Grant View Permissions

**User Story:** As a folder owner, I want to grant view permissions to specific users, so that I can control who has access to view my folders.

#### Acceptance Criteria

1. WHEN a Folder_Owner creates a view permission for a User and TemplateFolder, THE Permission_System SHALL create a View_Permission record linking the User to the TemplateFolder
2. THE Permission_System SHALL prevent duplicate View_Permission records for the same User and TemplateFolder combination
3. WHEN a Folder_Owner attempts to grant view permission to a User not in the same Account, THE Permission_System SHALL reject the operation with an error message
4. THE Permission_System SHALL allow granting view permissions to multiple Users for the same TemplateFolder
5. THE Permission_System SHALL allow granting view permissions for multiple TemplateFolders to the same User

### Requirement 2: Revoke View Permissions

**User Story:** As a folder owner, I want to revoke view permissions from specific users, so that I can remove access when it's no longer needed.

#### Acceptance Criteria

1. WHEN a Folder_Owner revokes a view permission, THE Permission_System SHALL delete the corresponding View_Permission record
2. WHEN a User's view permission is revoked, THE Permission_System SHALL immediately prevent that User from viewing the TemplateFolder
3. THE Permission_System SHALL allow revoking view permissions that were previously granted
4. WHEN a Folder_Owner attempts to revoke a non-existent view permission, THE Permission_System SHALL complete without error

### Requirement 3: Check View Access

**User Story:** As the system, I want to check if a user has view access to a folder, so that I can enforce access control throughout the application.

#### Acceptance Criteria

1. WHEN a User is the Folder_Owner of a TemplateFolder, THE Permission_System SHALL grant view access
2. WHEN a User has an explicit View_Permission for a TemplateFolder, THE Permission_System SHALL grant view access
3. WHEN a TemplateFolder has no View_Permission records, THE Permission_System SHALL grant view access to all Users in the Account
4. WHEN a TemplateFolder has one or more View_Permission records AND a User lacks both ownership and explicit permission, THE Permission_System SHALL deny view access
5. WHEN a User has admin role in the Account, THE Permission_System SHALL grant view access to all TemplateFolders in that Account

### Requirement 4: Enforce View Permissions in Folder Listing

**User Story:** As a user, I want to see only folders I have permission to view, so that I don't see folders I cannot access.

#### Acceptance Criteria

1. WHEN a User requests a list of TemplateFolders, THE Permission_System SHALL return only TemplateFolders where the User has view access
2. THE Permission_System SHALL exclude Restricted_Folders from the list when the User lacks view access
3. THE Permission_System SHALL include all Unrestricted_Folders in the list for any User in the Account
4. THE Permission_System SHALL include TemplateFolders owned by the User regardless of View_Permission records
5. WHEN a User has admin role, THE Permission_System SHALL include all TemplateFolders in the Account in the list

### Requirement 5: Enforce View Permissions for Individual Folder Access

**User Story:** As the system, I want to prevent unauthorized users from viewing folder details, so that access control is consistently enforced.

#### Acceptance Criteria

1. WHEN a User attempts to view a TemplateFolder they own, THE Permission_System SHALL allow the access
2. WHEN a User attempts to view a Restricted_Folder without view access, THE Permission_System SHALL deny the access with an authorization error
3. WHEN a User attempts to view an Unrestricted_Folder, THE Permission_System SHALL allow the access
4. WHEN a User with admin role attempts to view any TemplateFolder, THE Permission_System SHALL allow the access
5. WHEN a User attempts to view a TemplateFolder with an explicit View_Permission, THE Permission_System SHALL allow the access

### Requirement 6: Handle Permission Inheritance in Folder Hierarchy

**User Story:** As a folder owner, I want view permissions to apply to nested subfolders, so that access control is consistent throughout the folder hierarchy.

#### Acceptance Criteria

1. WHEN a User has view access to a parent TemplateFolder, THE Permission_System SHALL grant view access to all subfolders in the Folder_Hierarchy
2. WHEN a parent TemplateFolder is a Restricted_Folder AND a User lacks view access, THE Permission_System SHALL deny view access to all subfolders regardless of subfolder permissions
3. WHEN a User has explicit View_Permission for a subfolder BUT lacks view access to the parent folder, THE Permission_System SHALL deny view access to the subfolder
4. THE Permission_System SHALL evaluate parent folder permissions before evaluating subfolder permissions
5. WHEN a TemplateFolder has multiple levels of nesting, THE Permission_System SHALL verify view access at each level from root to target folder

### Requirement 7: Cascade Permission Deletion on User Removal

**User Story:** As the system, I want to automatically clean up permissions when users are removed, so that orphaned permission records don't accumulate.

#### Acceptance Criteria

1. WHEN a User is deleted from the system, THE Permission_System SHALL delete all View_Permission records associated with that User
2. WHEN a User is archived, THE Permission_System SHALL treat the User as having no view access to Restricted_Folders
3. THE Permission_System SHALL maintain referential integrity when deleting View_Permission records
4. WHEN a User is removed from an Account, THE Permission_System SHALL delete all View_Permission records for TemplateFolders in that Account

### Requirement 8: Cascade Permission Deletion on Folder Removal

**User Story:** As the system, I want to automatically clean up permissions when folders are deleted, so that orphaned permission records don't accumulate.

#### Acceptance Criteria

1. WHEN a TemplateFolder is deleted, THE Permission_System SHALL delete all View_Permission records associated with that TemplateFolder
2. WHEN a TemplateFolder is archived, THE Permission_System SHALL preserve View_Permission records but exclude the folder from view access checks
3. THE Permission_System SHALL maintain referential integrity when deleting View_Permission records
4. WHEN a parent TemplateFolder is deleted, THE Permission_System SHALL delete View_Permission records for all subfolders in the Folder_Hierarchy

### Requirement 9: Query Permitted Users for a Folder

**User Story:** As a folder owner, I want to see which users have view access to my folder, so that I can audit and manage permissions.

#### Acceptance Criteria

1. WHEN a Folder_Owner requests the list of Users with view access to a TemplateFolder, THE Permission_System SHALL return all Users with explicit View_Permission records
2. THE Permission_System SHALL include the Folder_Owner in the list of Users with view access
3. THE Permission_System SHALL include all admin Users in the Account in the list of Users with view access
4. WHEN a TemplateFolder is an Unrestricted_Folder, THE Permission_System SHALL return all active Users in the Account
5. THE Permission_System SHALL exclude archived Users from the list of Users with view access

### Requirement 10: Validate Permission Operations

**User Story:** As the system, I want to validate permission operations, so that data integrity is maintained.

#### Acceptance Criteria

1. WHEN creating a View_Permission, THE Permission_System SHALL verify that the TemplateFolder exists
2. WHEN creating a View_Permission, THE Permission_System SHALL verify that the User exists and is active
3. WHEN creating a View_Permission, THE Permission_System SHALL verify that the User and TemplateFolder belong to the same Account
4. THE Permission_System SHALL reject View_Permission creation with invalid foreign keys
5. THE Permission_System SHALL enforce database constraints on View_Permission records
