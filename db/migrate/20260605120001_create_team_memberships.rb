# frozen_string_literal: true

class CreateTeamMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :team_memberships do |t|
      t.references :team, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :team_memberships, %i[team_id user_id], unique: true
  end
end
