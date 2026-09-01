export default class extends HTMLElement {
  connectedCallback () {
    this.folderSelect = this.querySelector('#folder_select')
    this.permissionsPanel = this.querySelector('#permissions_panel')
    this.usersList = this.querySelector('#users_list')
    this.userSelect = this.querySelector('#user_select')
    this.grantButton = this.querySelector('#grant_button')
    this.loadingIndicator = this.querySelector('#loading_indicator')
    this.errorMessage = this.querySelector('#error_message')
    this.unrestrictedMessage = this.querySelector('#unrestricted_message')
    this.noUsersMessage = this.querySelector('#no_users_message')
    this.grantFormContainer = this.querySelector('#grant_form_container')
    this.grantError = this.querySelector('#grant_error')
    this.statusMessage = this.querySelector('#status_message')
    this.usersTableContainer = this.querySelector('#users_table_container')

    this.allUsers = JSON.parse(this.dataset.users || '[]')
    this.allTeams = JSON.parse(this.dataset.teams || '[]')
    this.currentUserId = null
    this.selectedFolderId = null
    this.selectedFolderOwnerId = null
    this.permittedUsers = []
    this.permittedTeams = []
    this.isUnrestricted = false

    this.folderSelect.addEventListener('change', this.onFolderChange)
    this.grantButton.addEventListener('click', this.onGrant)
    this.userSelect.addEventListener('change', this.onUserSelectChange)
  }

  disconnectedCallback () {
    this.folderSelect.removeEventListener('change', this.onFolderChange)
    this.grantButton.removeEventListener('click', this.onGrant)
    this.userSelect.removeEventListener('change', this.onUserSelectChange)
  }

  onFolderChange = async () => {
    const option = this.folderSelect.selectedOptions[0]
    this.selectedFolderId = option.value
    this.selectedFolderOwnerId = parseInt(option.dataset.ownerId)

    this.permissionsPanel.classList.remove('hidden')
    await this.loadPermissions()
  }

  loadPermissions = async () => {
    this.showLoading(true)
    this.hideError()
    this.usersList.innerHTML = ''
    this.unrestrictedMessage.classList.add('hidden')

    try {
      const resp = await fetch(`/folders/${this.selectedFolderId}/permissions`, {
        headers: { Accept: 'application/json' }
      })

      if (!resp.ok) throw new Error('Failed to load permissions')

      const data = await resp.json()

      // Handle both old format (array) and new format ({ users, teams })
      if (Array.isArray(data)) {
        this.permittedUsers = data
        this.permittedTeams = []
      } else {
        this.permittedUsers = data.users || []
        this.permittedTeams = data.teams || []
      }

      this.renderUserList(this.permittedUsers)
      this.renderTeamList(this.permittedTeams)
      this.updateGrantForm(this.permittedUsers)
    } catch (e) {
      this.showError(e.message)
    } finally {
      this.showLoading(false)
    }
  }

  renderTeamList = (teams) => {
    // Remove existing team rows
    this.querySelectorAll('.team-row').forEach(el => el.remove())

    if (teams.length === 0) return

    // Add a team header row
    const headerTr = document.createElement('tr')
    headerTr.className = 'team-row bg-base-200'
    headerTr.innerHTML = `
      <td colspan="4" class="font-semibold text-sm uppercase tracking-wide">Teams</td>
    `
    this.usersList.insertBefore(headerTr, this.usersList.firstChild)

    teams.forEach(team => {
      const tr = document.createElement('tr')
      tr.className = 'team-row'
      tr.id = `team_row_${team.id}`
      tr.innerHTML = `
        <td colspan="2">
          <span class="badge badge-sm badge-primary badge-outline mr-1">Team</span>
          ${this.escapeHtml(team.name)}
        </td>
        <td></td>
        <td>
          <button type="button" class="btn btn-xs btn-error btn-outline min-h-[44px] min-w-[44px]"
            aria-label="Revoke access for team ${this.escapeHtml(team.name)}"
            data-team-id="${team.id}"
            data-team-name="${this.escapeHtml(team.name)}">
            Revoke
          </button>
        </td>
      `

      const revokeBtn = tr.querySelector('[data-team-id]')
      if (revokeBtn) {
        revokeBtn.addEventListener('click', () => this.onRevokeTeamClick(team))
      }

      // Insert after the header row
      headerTr.insertAdjacentElement('afterend', tr)
    })
  }

  renderUserList = (users) => {
    if (users.length === this.allUsers.length && !this.hasExplicitPermissions()) {
      this.unrestrictedMessage.classList.remove('hidden')
      this.usersTableContainer.classList.add('hidden')
    } else {
      this.unrestrictedMessage.classList.add('hidden')
      this.usersTableContainer.classList.remove('hidden')
    }

    // Clear only non-team rows
    this.querySelectorAll('#users_list tr:not(.team-row)').forEach(el => el.remove())

    const sorted = [...users].sort((a, b) =>
      (a.last_name || '').localeCompare(b.last_name || '') ||
      (a.first_name || '').localeCompare(b.first_name || '')
    )

    sorted.forEach(user => {
      const tr = document.createElement('tr')
      const isOwner = user.id === this.selectedFolderOwnerId
      const isSuperAdmin = user.role === 'super_admin'
      const isAdmin = user.role === 'admin'
      // Admins are revocable; only the folder owner and super admins are not.
      // Super admins are the highest level of control and can never be revoked.
      const canRevoke = !isOwner && !isSuperAdmin

      tr.id = `user_row_${user.id}`
      tr.innerHTML = `
        <td>
          ${this.escapeHtml(user.first_name || '')} ${this.escapeHtml(user.last_name || '')}
          ${isOwner ? '<span class="badge badge-sm badge-outline ml-1">Owner</span>' : ''}
          ${isSuperAdmin ? '<span class="badge badge-sm badge-outline ml-1">Super Admin</span>' : ''}
          ${isAdmin ? '<span class="badge badge-sm badge-outline ml-1">Admin</span>' : ''}
        </td>
        <td>${this.escapeHtml(user.email)}</td>
        <td>${this.escapeHtml(this.roleLabel(user.role))}</td>
        <td>
          ${canRevoke ? `<button type="button" class="btn btn-xs btn-error btn-outline min-h-[44px] min-w-[44px]"
            aria-label="Revoke access for ${this.escapeHtml(user.email)}"
            data-user-id="${user.id}"
            data-user-name="${this.escapeHtml(user.first_name || '')} ${this.escapeHtml(user.last_name || '')}">
            Revoke
          </button>` : ''}
        </td>
      `

      const revokeBtn = tr.querySelector('[data-user-id]')
      if (revokeBtn) {
        revokeBtn.addEventListener('click', () => this.onRevokeClick(user))
      }

      this.usersList.appendChild(tr)
    })
  }

  onRevokeClick = (user) => {
    const name = `${user.first_name || ''} ${user.last_name || ''}`.trim() || user.email
    if (!confirm(`Are you sure you want to revoke access for ${name}?`)) return

    this.revokeAccess(user)
  }

  onRevokeTeamClick = (team) => {
    // Show a custom dialog: first confirm revoke, then ask about members
    if (!confirm(`Are you sure you want to revoke access for team "${team.name}"?`)) return

    const revokeMembers = confirm(
      `Also revoke folder access for all individual members of "${team.name}"?\n\n` +
      'Click OK to revoke access for all members.\n' +
      'Click Cancel to keep individual member access.'
    )

    this.revokeTeamAccess(team, revokeMembers)
  }

  revokeAccess = async (user) => {
    this.setFormDisabled(true)

    try {
      const resp = await fetch(`/folders/${this.selectedFolderId}/permissions/${user.id}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': this.dataset.csrf,
          Accept: 'application/json'
        }
      })

      if (!resp.ok) throw new Error('Failed to revoke access')

      const row = this.querySelector(`#user_row_${user.id}`)
      if (row) row.remove()

      this.permittedUsers = this.permittedUsers.filter(u => u.id !== user.id)
      this.updateGrantForm(this.permittedUsers)
      this.showStatus('Access revoked successfully')
    } catch (e) {
      this.showStatus('Failed to revoke access', true)
    } finally {
      this.setFormDisabled(false)
    }
  }

  revokeTeamAccess = async (team, revokeMembers = false) => {
    this.setFormDisabled(true)

    try {
      const params = new URLSearchParams({ type: 'team' })
      if (revokeMembers) params.append('revoke_members', 'true')

      const resp = await fetch(`/folders/${this.selectedFolderId}/permissions/${team.id}?${params}`, {
        method: 'DELETE',
        headers: {
          'X-CSRF-Token': this.dataset.csrf,
          Accept: 'application/json'
        }
      })

      if (!resp.ok) throw new Error('Failed to revoke team access')

      // Reload permissions to reflect the updated state
      await this.loadPermissions()
      this.showStatus('Team access revoked successfully')
    } catch (e) {
      this.showStatus('Failed to revoke team access', true)
    } finally {
      this.setFormDisabled(false)
    }
  }

  onUserSelectChange = () => {
    this.grantButton.disabled = !this.userSelect.value
  }

  onGrant = async () => {
    const selectedValue = this.userSelect.value
    if (!selectedValue) {
      this.grantError.textContent = 'Please select a user or team'
      this.grantError.classList.remove('hidden')
      return
    }

    this.grantError.classList.add('hidden')
    this.setFormDisabled(true)

    const isTeam = selectedValue.startsWith('team_')
    const body = isTeam
      ? { team_id: selectedValue.replace('team_', '') }
      : { user_id: selectedValue }

    try {
      const resp = await fetch(`/folders/${this.selectedFolderId}/permissions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': this.dataset.csrf,
          Accept: 'application/json'
        },
        body: JSON.stringify(body)
      })

      if (!resp.ok) {
        const data = await resp.json().catch(() => ({}))
        throw new Error(data.error || 'Failed to grant access')
      }

      await this.loadPermissions()
      this.showStatus('Access granted successfully')
    } catch (e) {
      this.grantError.textContent = e.message
      this.grantError.classList.remove('hidden')
      this.showStatus('Failed to grant access', true)
    } finally {
      this.setFormDisabled(false)
    }
  }

  updateGrantForm = (permittedUsers) => {
    const permittedUserIds = new Set(permittedUsers.map(u => u.id))
    const permittedTeamIds = new Set(this.permittedTeams.map(t => t.id))

    const availableUsers = this.allUsers.filter(u => !permittedUserIds.has(u.id))
    const availableTeams = this.allTeams.filter(t => !permittedTeamIds.has(t.id))

    if (availableUsers.length === 0 && availableTeams.length === 0) {
      this.noUsersMessage.classList.remove('hidden')
      this.grantFormContainer.classList.add('hidden')
    } else {
      this.noUsersMessage.classList.add('hidden')
      this.grantFormContainer.classList.remove('hidden')

      this.userSelect.innerHTML = '<option value="" disabled selected>Choose a user or team</option>'

      if (availableTeams.length > 0) {
        const teamGroup = document.createElement('optgroup')
        teamGroup.label = 'Teams'
        availableTeams.forEach(team => {
          const opt = document.createElement('option')
          opt.value = `team_${team.id}`
          opt.textContent = team.name
          teamGroup.appendChild(opt)
        })
        this.userSelect.appendChild(teamGroup)
      }

      if (availableUsers.length > 0) {
        const userGroup = document.createElement('optgroup')
        userGroup.label = 'Users'
        availableUsers.forEach(user => {
          const opt = document.createElement('option')
          opt.value = user.id
          opt.textContent = `${user.first_name || ''} ${user.last_name || ''} (${user.email})`.trim()
          userGroup.appendChild(opt)
        })
        this.userSelect.appendChild(userGroup)
      }
    }

    this.grantButton.disabled = true
    this.userSelect.value = ''
  }

  showLoading = (show) => {
    this.loadingIndicator.classList.toggle('hidden', !show)
    this.usersTableContainer.classList.toggle('hidden', show)
  }

  showError = (message) => {
    this.errorMessage.querySelector('span').textContent = message
    this.errorMessage.classList.remove('hidden')
  }

  hideError = () => {
    this.errorMessage.classList.add('hidden')
  }

  showStatus = (message, isError = false) => {
    const alert = this.statusMessage.querySelector('.alert')
    alert.className = `alert ${isError ? 'alert-error' : 'alert-success'}`
    alert.querySelector('span').textContent = message
    this.statusMessage.classList.remove('hidden')

    clearTimeout(this.statusTimeout)
    this.statusTimeout = setTimeout(() => {
      this.statusMessage.classList.add('hidden')
    }, 3000)
  }

  setFormDisabled = (disabled) => {
    this.grantButton.disabled = disabled
    this.userSelect.disabled = disabled
    this.querySelectorAll('[data-user-id]').forEach(btn => {
      btn.disabled = disabled
    })
    this.querySelectorAll('[data-team-id]').forEach(btn => {
      btn.disabled = disabled
    })
  }

  hasExplicitPermissions = () => {
    return false
  }

  roleLabel = (role) => {
    const labels = {
      super_admin: 'Super Admin',
      admin: 'Admin',
      editor: 'Editor',
      viewer: 'Viewer'
    }
    return labels[role] || role
  }

  escapeHtml = (text) => {
    const div = document.createElement('div')
    div.textContent = text
    return div.innerHTML
  }
}
