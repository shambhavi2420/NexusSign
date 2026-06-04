# frozen_string_literal: true

class CreateTemplateFolderPermissions < ActiveRecord::Migration[8.0]
  def change
    create_table :template_folder_permissions do |t|
      t.references :template_folder, null: false, foreign_key: true, index: false
      t.references :user,            null: false, foreign_key: false, index: false

      t.index %i[template_folder_id user_id], unique: true, name: 'idx_tfp_on_folder_and_user'

      t.timestamps
    end
  end
end
