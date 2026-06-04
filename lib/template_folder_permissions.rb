# frozen_string_literal: true

module TemplateFolderPermissions
  module_function

  # Returns true if the folder has at least one permission record (is restricted).
  def restricted?(folder)
    folder.template_folder_permissions.exists?
  end

  # Returns true if the user may view this folder.
  # Rules (evaluated in order):
  #   1. Admin users always have access.
  #   2. The folder owner always has access.
  #   3. Archived users are denied access.
  #   4. Any ancestor in the hierarchy that is restricted and excludes the user blocks access.
  #   5. The user must pass the node-level access check for the folder itself.
  def can_view?(user, folder)
    return true if user.role == User::ADMIN_ROLE
    return true if folder.author_id == user.id
    return false if user.archived_at?

    # Walk ancestors from root down to (but not including) the folder itself;
    # deny if any ancestor is inaccessible to the user.
    ancestors = ancestor_chain(folder)
    ancestors.each do |ancestor|
      next if ancestor.id == folder.id

      return false unless node_accessible?(user, ancestor)
    end

    node_accessible?(user, folder)
  end

  # Returns an ActiveRecord relation of folders visible to the user.
  # Designed to be composed with other scopes (search, sort, pagination).
  def visible_to(folders_scope, user)
    return folders_scope if user.role == User::ADMIN_ROLE

    account_id = user.account_id

    # Folders owned by the user are always visible
    owned = folders_scope.where(author_id: user.id)

    # Unrestricted folders (no permission records) visible to all account members
    unrestricted = folders_scope.where(account_id:).where(
      'NOT EXISTS (SELECT 1 FROM template_folder_permissions WHERE template_folder_id = template_folders.id)'
    )

    # Restricted folders where the user has an explicit permission
    permitted = folders_scope.where(account_id:).joins(:template_folder_permissions)
                             .where(template_folder_permissions: { user_id: user.id })

    # Union the three sets, then filter out folders whose ancestors block access
    candidate_ids = TemplateFolder.from(
      owned.or(unrestricted).or(permitted).select(:id).distinct
    ).pluck(:id)

    # Remove candidates blocked by an inaccessible ancestor
    accessible_ids = candidate_ids.select { |id| can_view?(user, TemplateFolder.find(id)) }

    folders_scope.where(id: accessible_ids)
  end

  # Grants view permission. Idempotent — safe to call multiple times.
  # Raises ActiveRecord::RecordInvalid if the user is not in the same account.
  def grant(user, folder)
    TemplateFolderPermission.find_or_create_by!(user:, template_folder: folder)
  end

  # Revokes view permission. No-op if the record does not exist.
  def revoke(user, folder)
    TemplateFolderPermission.where(user:, template_folder: folder).destroy_all
  end

  # Returns the list of users who can view the folder.
  # For unrestricted folders, returns all active account users.
  # For restricted folders, returns owner + admins + explicitly permitted active users.
  def permitted_users(folder)
    account = folder.account
    active_users = account.users.active

    if restricted?(folder)
      explicit_user_ids = folder.template_folder_permissions.pluck(:user_id)
      active_users.where(
        'id IN (?) OR id = ? OR role = ?',
        explicit_user_ids,
        folder.author_id,
        User::ADMIN_ROLE
      )
    else
      active_users
    end
  end

  private

  # Checks access for a single node, ignoring hierarchy.
  # Owner bypass, unrestricted bypass, then explicit permission check.
  def node_accessible?(user, folder)
    return true if folder.author_id == user.id
    return true unless restricted?(folder)

    folder.template_folder_permissions.exists?(user_id: user.id)
  end

  # Returns the ancestor chain from root down to (and including) the folder.
  # Uses a Set as a cycle guard to handle any corrupt data gracefully.
  def ancestor_chain(folder)
    chain = [folder]
    current = folder
    visited = Set.new([folder.id])

    while current.parent_folder_id
      current = current.parent_folder
      break if visited.include?(current.id)

      visited.add(current.id)
      chain.unshift(current)
    end

    chain
  end
end
