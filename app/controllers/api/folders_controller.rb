# frozen_string_literal: true

module Api
  class FoldersController < ApiBaseController
    load_and_authorize_resource :template_folder, parent: false

    def index
      folders = @template_folders.active
                                 .api_visible
                                 .preload(:parent_folder)
                                 .order(name: :asc)

      # Hide blank folders (no active templates directly or in subfolders) so the
      # API matches the portal UI, but always keep the Default folder visible.
      non_empty_folders = TemplateFolders.filter_active_folders(folders, current_account.templates)
      default_folder    = folders.where(name: TemplateFolder::DEFAULT_NAME)

      folders = folders.where(id: non_empty_folders.select(:id))
                       .or(folders.where(id: default_folder.select(:id)))

      folders = folders.where('name ILIKE ?', "%#{params[:q]}%") if params[:q].present?

      render json: {
        data: folders.map do |folder|
          {
            id: folder.id,
            name: folder.name,
            full_name: folder.full_name,
            parent_folder_id: folder.parent_folder_id
          }
        end
      }
    end
  end
end
