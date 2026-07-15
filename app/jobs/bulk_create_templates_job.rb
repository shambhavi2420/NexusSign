# frozen_string_literal: true

class BulkCreateTemplatesJob < ApplicationJob
  queue_as :default

  def perform(blob_ids:, folder_id:, author_id:, account_id:, session_id: nil)
    author = User.find(author_id)
    account = Account.find(account_id)
    folder = TemplateFolder.find_by(id: folder_id)

    results = blob_ids.map do |blob_id|
      blob = ActiveStorage::Blob.find(blob_id)
      tempfile = Tempfile.new(['migration', File.extname(blob.filename.to_s)])
      tempfile.binmode
      blob.download { |chunk| tempfile.write(chunk) }
      tempfile.rewind

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: blob.filename.to_s,
        type: blob.content_type
      )

      result = DataMigrations::BulkCreateTemplates.process_file(
        file: file,
        folder: folder,
        author: author,
        account: account
      )

      tempfile.close
      tempfile.unlink
      blob.purge

      result
    end

    # Store results in a cache key so the controller can retrieve them
    cache_key = "data_migration_results:#{author_id}:#{session_id}"
    Rails.cache.write(cache_key, {
      results: results,
      completed_at: Time.current.iso8601,
      status: 'completed'
    }.to_json, expires_in: 1.hour)
  end
end
