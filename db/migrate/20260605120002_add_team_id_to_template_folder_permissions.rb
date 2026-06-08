# frozen_string_literal: true

class AddTeamIdToTemplateFolderPermissions < ActiveRecord::Migration[8.0]
  def change
    add_reference :template_folder_permissions, :team, null: true, foreign_key: true

    # Allow folder permission to be granted to a team (without a specific user)
    change_column_null :template_folder_permissions, :user_id, true

    # Add unique index for team-folder combination
    add_index :template_folder_permissions, %i[template_folder_id team_id],
              unique: true,
              where: 'team_id IS NOT NULL',
              name: 'idx_tfp_on_folder_and_team'
  end
end
