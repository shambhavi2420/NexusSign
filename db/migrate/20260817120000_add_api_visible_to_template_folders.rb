# frozen_string_literal: true

class AddApiVisibleToTemplateFolders < ActiveRecord::Migration[8.0]
  def change
    add_column :template_folders, :api_visible, :boolean, default: true, null: false
  end
end
