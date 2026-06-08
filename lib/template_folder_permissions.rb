# frozen_string_literal: true

module TemplateFolderPermissions
  module_function

  # Returns true if the folder has at least one permission record (is restricted).
  def restricted?(folder)
    TemplateFolderPermission.where(template_folder_id: folder.id).exists?
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
    owned_ids = folders_scope.where(author_id: user.id).pluck(:id)

    # Unrestricted folders (no permission records) visible to all account members
    unrestricted_ids = folders_scope.where(account_id:).where(
      'NOT EXISTS (SELECT 1 FROM template_folder_permissions WHERE template_folder_id = template_folders.id)'
    ).pluck(:id)

    # Restricted folders where the user has an explicit individual permission
    permitted_ids = folders_scope.where(account_id:).joins(:template_folder_permissions)
                                 .where(template_folder_permissions: { user_id: user.id }).pluck(:id)

    # Restricted folders where the user belongs to a team that has permission
    user_team_ids = user.team_memberships.pluck(:team_id)
    team_permitted_ids = if user_team_ids.any?
                           folders_scope.where(account_id:).joins(:template_folder_permissions)
                                        .where(template_folder_permissions: { team_id: user_team_ids }).pluck(:id)
                         else
                           []
                         end

    # Union all sets, then filter out folders whose ancestors block access
    candidate_ids = (owned_ids | unrestricted_ids | permitted_ids | team_permitted_ids).uniq

    # Remove candidates blocked by an inaccessible ancestor
    accessible_ids = candidate_ids.select { |id| can_view?(user, TemplateFolder.find(id)) }

    folders_scope.where(id: accessible_ids)
  end

  # Grants view permission to an individual user. Idempotent.
  # When granting the first permission on a previously unrestricted folder,
  # also creates a permission for the owner to keep the folder restricted.
  def grant(user, folder)
    was_unrestricted = !restricted?(folder)

    permission = TemplateFolderPermission.find_or_create_by!(user:, template_folder: folder)

    # If this is the first permission on a previously unrestricted folder,
    # also grant the owner so the folder stays restricted when others are revoked.
    if was_unrestricted && folder.author_id != user.id
      TemplateFolderPermission.find_or_create_by!(user_id: folder.author_id, template_folder: folder)
    end

    permission
  end

  # Grants view permission to an entire team. Idempotent.
  # When granting the first permission on a previously unrestricted folder,
  # also creates a permission for the owner to keep the folder restricted.
  def grant_team(team, folder)
    was_unrestricted = !restricted?(folder)

    permission = TemplateFolderPermission.find_or_create_by!(team:, template_folder: folder)

    if was_unrestricted
      TemplateFolderPermission.find_or_create_by!(user_id: folder.author_id, template_folder: folder)
    end

    permission
  end

  # Revokes view permission from an individual user.
  def revoke(user, folder)
    # Don't revoke the owner's access
    return if user.id == folder.author_id

    is_restricted = TemplateFolderPermission.where(template_folder_id: folder.id).exists?

    if is_restricted
      # Folder is already restricted — remove the user's permission record
      TemplateFolderPermission.where(user_id: user.id, template_folder_id: folder.id).destroy_all

      # Ensure at least the owner record remains so folder stays restricted
      unless TemplateFolderPermission.where(template_folder_id: folder.id).exists?
        TemplateFolderPermission.create!(user_id: folder.author_id, template_folder_id: folder.id)
      end
    else
      # Folder is unrestricted — restrict it.
      # Create permission records for all active users EXCEPT the target user.
      folder.account.users.active.where.not(role: 'integration').where.not(id: user.id).pluck(:id).each do |uid|
        TemplateFolderPermission.create!(user_id: uid, template_folder_id: folder.id)
      rescue ActiveRecord::RecordNotUnique
        next
      end

      # Safety: ensure at least one record exists so folder is restricted
      unless TemplateFolderPermission.where(template_folder_id: folder.id).exists?
        TemplateFolderPermission.create!(user_id: folder.author_id, template_folder_id: folder.id)
      end
    end
  end

  # Revokes view permission from a team.
  def revoke_team(team, folder)
    TemplateFolderPermission.where(team_id: team.id, template_folder_id: folder.id).destroy_all

    # Ensure at least one record remains so folder stays restricted
    unless TemplateFolderPermission.where(template_folder_id: folder.id).exists?
      TemplateFolderPermission.create!(user_id: folder.author_id, template_folder_id: folder.id)
    end
  end

  # Returns the list of users who can view the folder.
  # For unrestricted folders, returns all active account users.
  # For restricted folders, returns owner + admins + explicitly permitted users + team members.
  def permitted_users(folder)
    account = folder.account
    active_users = account.users.active

    if restricted?(folder)
      explicit_user_ids = TemplateFolderPermission.where(template_folder_id: folder.id)
                                                  .where.not(user_id: nil)
                                                  .pluck(:user_id)

      team_ids = TemplateFolderPermission.where(template_folder_id: folder.id)
                                         .where.not(team_id: nil)
                                         .pluck(:team_id)

      team_user_ids = if team_ids.any?
                        TeamMembership.where(team_id: team_ids).pluck(:user_id)
                      else
                        []
                      end

      all_permitted_ids = (explicit_user_ids + team_user_ids).uniq

      active_users.where(
        'id IN (?) OR id = ? OR role = ?',
        all_permitted_ids,
        folder.author_id,
        User::ADMIN_ROLE
      )
    else
      active_users
    end
  end

  # Returns teams that have permission on this folder.
  def permitted_teams(folder)
    team_ids = TemplateFolderPermission.where(template_folder_id: folder.id)
                                       .where.not(team_id: nil)
                                       .pluck(:team_id)
    Team.where(id: team_ids)
  end

  # Checks access for a single node, ignoring hierarchy.
  # Owner bypass, unrestricted bypass, then explicit permission check (user or team).
  def node_accessible?(user, folder)
    return true if folder.author_id == user.id
    return true unless restricted?(folder)

    # Check direct user permission
    return true if TemplateFolderPermission.where(template_folder_id: folder.id, user_id: user.id).exists?

    # Check team-based permission
    user_team_ids = user.team_memberships.pluck(:team_id)
    return false if user_team_ids.empty?

    TemplateFolderPermission.where(template_folder_id: folder.id, team_id: user_team_ids).exists?
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
