# frozen_string_literal: true

module DataMigrations
  module BulkCreateTemplates
    module_function

    def call(files:, folder:, author:, account:)
      Array.wrap(files).map do |file|
        process_file(file:, folder:, author:, account:)
      end
    end

    def process_file(file:, folder:, author:, account:)
      file_name = file.original_filename
      template_name = File.basename(file_name, '.*')

      template = Template.new(
        name: template_name,
        author:,
        account:,
        folder:
      )

      Templates.maybe_assign_access(template)
      template.save!

      documents = Templates::CreateAttachments.call(template, { files: [file] }, extract_fields: true)
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

      if template.fields.blank?
        template.fields = Templates::ProcessDocument.normalize_attachment_fields(template, documents)
        schema.each { |item| item['pending_fields'] = true } if template.fields.present?
      end

      template.update!(schema:)

      SearchEntries.enqueue_reindex(template)
      WebhookUrls.enqueue_events(template, 'template.created')

      {
        status: 'success',
        file_name:,
        template_name: template.name,
        template_id: template.id
      }
    rescue StandardError => e
      Rollbar.error(e) if defined?(Rollbar)

      {
        status: 'failed',
        file_name: file.original_filename,
        template_name: template_name || file.original_filename,
        template_id: nil,
        error: e.message
      }
    end

    def template_name
      # This is a helper used in rescue; variable is scoped in process_file
      nil
    end
  end
end
