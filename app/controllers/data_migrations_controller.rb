# frozen_string_literal: true

class DataMigrationsController < ApplicationController
  skip_authorization_check

  before_action :authorize_admin!

  def show
    # If a background job has completed, load results from cache (not session, to avoid cookie overflow)
    if session[:data_migration_job_session_id].present?
      cache_key = "data_migration_results:#{current_user.id}:#{session[:data_migration_job_session_id]}"
      cached = Rails.cache.read(cache_key)

      if cached.present?
        @bg_results_json = cached
        session.delete(:data_migration_job_session_id)
        Rails.cache.delete(cache_key)
      end
    end
  end

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

      # Store in cache instead of session to avoid CookieOverflow for large results
      sync_session_id = SecureRandom.hex(16)
      cache_key = "data_migration_results:#{current_user.id}:#{sync_session_id}"
      Rails.cache.write(cache_key, {
        results: results,
        completed_at: Time.current.iso8601,
        status: 'completed'
      }.to_json, expires_in: 1.hour)

      session[:data_migration_job_session_id] = sync_session_id

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
      # Don't store in session (too large for cookie). The show action reads from cache directly.
      redirect_to data_migration_path, notice: I18n.t('bulk_upload_completed_background',
                                                       default: 'Background processing completed. See results below.')
    else
      redirect_to data_migration_path, notice: I18n.t('bulk_upload_still_processing',
                                                       default: 'Still processing... please refresh again in a moment.')
    end
  end

  def export
    # Try cache first (background/new flow), fall back to session (legacy)
    results_json = nil

    if session[:data_migration_job_session_id].present?
      cache_key = "data_migration_results:#{current_user.id}:#{session[:data_migration_job_session_id]}"
      results_json = Rails.cache.read(cache_key)
    end

    results_json ||= session[:data_migration_results]

    if results_json.blank?
      redirect_to data_migration_path, alert: I18n.t('no_results_to_export')
      return
    end

    parsed_data = JSON.parse(results_json)
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
    return if current_user.super_admin?
    return if current_user.can_access_setting?('data_migration')

    redirect_to root_path, alert: I18n.t('not_authorized')
  end
end
