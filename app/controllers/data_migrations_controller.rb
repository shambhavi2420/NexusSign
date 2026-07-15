# frozen_string_literal: true

class DataMigrationsController < ApplicationController
  skip_authorization_check

  before_action :authorize_admin!

  def show; end

  SYNC_FILE_LIMIT = 5

  def create
    files = params[:files]

    if files.blank?
      redirect_to data_migration_path, alert: I18n.t('no_files_selected')
      return
    end

    folder_name = params[:folder_name].presence
    folder = TemplateFolders.find_or_create_by_name(current_user, folder_name)

    if files.size <= SYNC_FILE_LIMIT
      # Small batch: process synchronously (fast enough to stay within timeout)
      results = DataMigrations::BulkCreateTemplates.call(
        files:,
        folder:,
        author: current_user,
        account: current_account
      )

      session[:data_migration_results] = {
        results: results,
        completed_at: Time.current.iso8601
      }.to_json

      redirect_to data_migration_path, notice: I18n.t('bulk_upload_completed',
                                                       success: results.count { |r| r[:status] == 'success' },
                                                       failed: results.count { |r| r[:status] == 'failed' })
    else
      # Large batch: upload blobs immediately, process in background
      blob_ids = files.map do |file|
        blob = ActiveStorage::Blob.create_and_upload!(
          io: file.tempfile,
          filename: file.original_filename,
          content_type: file.content_type
        )
        blob.id
      end

      session_id = session.id.to_s.presence || SecureRandom.hex(16)

      BulkCreateTemplatesJob.perform_later(
        blob_ids: blob_ids,
        folder_id: folder&.id,
        author_id: current_user.id,
        account_id: current_account.id,
        session_id: session_id
      )

      session[:data_migration_job_session_id] = session_id

      redirect_to data_migration_path, notice: I18n.t('bulk_upload_queued',
                                                       default: "#{files.size} files queued for processing. Results will appear shortly — refresh this page in a minute.")
    end
  end

  def status
    session_id = session[:data_migration_job_session_id]
    cache_key = "data_migration_results:#{current_user.id}:#{session_id}"
    cached = Rails.cache.read(cache_key)

    if cached.present?
      session[:data_migration_results] = cached
      session.delete(:data_migration_job_session_id)
      Rails.cache.delete(cache_key)
      redirect_to data_migration_path, notice: I18n.t('bulk_upload_completed_background',
                                                       default: 'Background processing completed. See results below.')
    else
      redirect_to data_migration_path, notice: I18n.t('bulk_upload_still_processing',
                                                       default: 'Still processing... please refresh again in a moment.')
    end
  end

  def export
    results = session[:data_migration_results]

    if results.blank?
      redirect_to data_migration_path, alert: I18n.t('no_results_to_export')
      return
    end

    parsed_data = JSON.parse(results)
    parsed_results = if parsed_data.is_a?(Array)
                       parsed_data
                     else
                       parsed_data['results'] || []
                     end
    parsed_results = parsed_results.select { |r| r['status'] == 'success' }

    if parsed_results.empty?
      redirect_to data_migration_path, alert: I18n.t('no_successful_templates_to_export')
      return
    end

    xlsx_data = DataMigrations::GenerateExportFile.call(parsed_results)

    send_data xlsx_data,
              filename: "data_migration_export_#{Time.current.strftime('%Y%m%d_%H%M%S')}.xlsx",
              type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  end

  private

  def authorize_admin!
    return if current_user.role == User::ADMIN_ROLE

    redirect_to root_path, alert: I18n.t('not_authorized')
  end
end
