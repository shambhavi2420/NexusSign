# frozen_string_literal: true

module Api
  class FoldersController < ApiBaseController
    load_and_authorize_resource :template_folder, parent: false

    def index
      folders = @template_folders.active
                                 .preload(:parent_folder)
                                 .order(name: :asc)

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
