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

      acroform_fields = []
      parsed_text_data = nil
      upload_file = file

      if file.content_type == 'application/pdf'
        file.tempfile.rewind
        pdf_blob = file.tempfile.read
        file.tempfile.rewind

        # 1. Extract Sertifi/SFLD tags stored as AcroForm fields (name, value, tooltip)
        acroform_fields = extract_sertifi_fields_from_acroform(pdf_blob)
        puts "  ACROFORM_SERTIFI_FIELDS: #{acroform_fields.size}"

        # Remove those AcroForm fields from the PDF so their rendered appearance
        # disappears entirely (deleting a real form field widget removes its
        # visual rendering - no white-box overlay needed for these).
        clean_pdf_blob = acroform_fields.any? ? remove_sertifi_fields_from_pdf(pdf_blob, acroform_fields) : pdf_blob

        # 2. Extract Sertifi/SFLD tags baked directly into the page text (not
        # AcroForm fields at all - e.g. typed into a Word doc and exported to PDF).
        # These need a white-box overlay drawn over the tag text plus a field
        # placed at the same spot, mirroring the from_pdf API tag-based flow.
        input_tempfile = Tempfile.new(['clean_input', '.pdf'])
        input_tempfile.binmode
        input_tempfile.write(clean_pdf_blob)
        input_tempfile.rewind

        begin
          parsed_text_data = PdfFieldParser.call(input_tempfile.path)
          puts "  TEXT_TAG_FIELDS: #{parsed_text_data[:fields].size} tag_positions=#{parsed_text_data[:tag_positions].size}"
        rescue PdfFieldParser::ParseError => e
          puts "  TEXT_TAG_PARSE_ERROR: #{e.message}"
          Rollbar.warning(e) if defined?(Rollbar)
          parsed_text_data = nil
        end

        final_pdf_blob =
          if parsed_text_data && parsed_text_data[:tag_positions].present?
            output_tempfile = Tempfile.new(['clean_output', '.pdf'])
            output_tempfile.binmode
            PdfFieldParser.remove_tags_and_add_fields(input_tempfile.path, output_tempfile.path, parsed_text_data)
            output_tempfile.rewind
            result = output_tempfile.read
            output_tempfile.close
            output_tempfile.unlink
            result
          else
            clean_pdf_blob
          end

        input_tempfile.close
        input_tempfile.unlink

        if acroform_fields.any? || parsed_text_data&.dig(:fields)&.any?
          final_tempfile = Tempfile.new(['final', '.pdf'])
          final_tempfile.binmode
          final_tempfile.write(final_pdf_blob)
          final_tempfile.rewind

          upload_file = ActionDispatch::Http::UploadedFile.new(
            tempfile: final_tempfile,
            filename: file_name,
            type: 'application/pdf'
          )
        end
      end

      template = Template.new(
        name: template_name,
        author:,
        account:,
        folder:
      )

      Templates.maybe_assign_access(template)
      template.save!

      documents = Templates::CreateAttachments.call(template, { files: [upload_file] }, extract_fields: true)
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

      if template.fields.blank?
        template.fields = Templates::ProcessDocument.normalize_attachment_fields(template, documents)
        schema.each { |item| item['pending_fields'] = true } if template.fields.present?
      end

      # Merge in the Sertifi/SFLD-derived fields from both extraction paths
      attachment_uuid = documents.first&.uuid
      merged_fields = []
      merged_fields += build_template_fields(acroform_fields, attachment_uuid, template) if acroform_fields.any?
      merged_fields += build_fields_from_parsed_text(parsed_text_data, attachment_uuid, template) if parsed_text_data&.dig(:fields)&.any?

      puts "  MERGED_FIELDS_TOTAL: #{merged_fields.size}"

      template.fields = (template.fields || []) + merged_fields if merged_fields.any?

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
      puts "  PROCESS_FILE_ERROR: #{e.class} #{e.message}\n#{e.backtrace.first(8).join("\n")}"

      {
        status: 'failed',
        file_name: file.original_filename,
        template_name: template_name || file.original_filename,
        template_id: nil,
        error: e.message
      }
    end

    # Convert raw AcroForm-derived sertifi field data (flat rel_x/rel_y/rel_w/rel_h)
    # into NexusSign template field format (relative 0-1 coordinates + attachment_uuid)
    def build_template_fields(sertifi_fields, attachment_uuid, template)
      submitter_uuid = template.submitters.first&.dig('uuid')

      sertifi_fields.map do |sf|
        {
          'uuid' => SecureRandom.uuid,
          'name' => sf[:name],
          'type' => sf[:type],
          'required' => sf[:required],
          'readonly' => false,
          'submitter_uuid' => submitter_uuid,
          'preferences' => sf[:preferences] || {},
          'areas' => [{
            'x' => sf[:rel_x],
            'y' => sf[:rel_y],
            'w' => sf[:rel_w],
            'h' => sf[:rel_h],
            'page' => sf[:page],
            'attachment_uuid' => attachment_uuid
          }]
        }.compact
      end
    end

    # Convert PdfFieldParser-derived fields (already built with `areas` arrays
    # of relative x/y/w/h/page) into NexusSign template field format by
    # injecting the attachment_uuid and submitter_uuid.
    def build_fields_from_parsed_text(parsed_text_data, attachment_uuid, template)
      submitter_uuid = template.submitters.first&.dig('uuid')

      parsed_text_data[:fields].map do |field|
        areas = Array.wrap(field[:areas]).map do |area|
          {
            'x' => area[:x],
            'y' => area[:y],
            'w' => area[:w],
            'h' => area[:h],
            'page' => area[:page],
            'attachment_uuid' => attachment_uuid
          }
        end

        {
          'uuid' => field[:uuid] || SecureRandom.uuid,
          'name' => field[:name],
          'type' => field[:type],
          'required' => field[:required],
          'readonly' => field[:readonly] || false,
          'submitter_uuid' => submitter_uuid,
          'preferences' => field[:preferences] || {},
          'default_value' => field[:default_value],
          'options' => field[:options],
          'areas' => areas
        }.compact
      end
    end

    # Extract Sertifi/SFLD tags from AcroForm fields using HexaPDF.
    # Checks field name, value (/V), default value (/DV), and tooltip (/TU) for tag patterns.
    # Returns an array of field data hashes with absolute PDF coordinates.
    def extract_sertifi_fields_from_acroform(pdf_blob)
      pdf = HexaPDF::Document.new(io: StringIO.new(pdf_blob))
      return [] if pdf.acro_form.blank?

      results = []

      pdf.acro_form.each_field do |field|
        field_name = field.full_field_name.to_s
        field_value = field.field_value.to_s
        default_value = field[:DV].to_s
        tooltip = field[:TU].to_s

        tag_content = find_sertifi_tag_in(field_name) ||
                      find_sertifi_tag_in(field_value) ||
                      find_sertifi_tag_in(default_value) ||
                      find_sertifi_tag_in(tooltip) ||
                      match_sertifi_field_name(field_name)

        next unless tag_content

        mapping = PdfFieldParser::SERTIFI_TAG_MAPPINGS.find { |pattern, _| tag_content.match?(pattern) }
        next unless mapping

        widget = field.respond_to?(:each_widget) ? field.each_widget.first : field
        next unless widget && widget[:Rect]

        page = find_page_for_field(pdf, widget)
        next unless page

        page_index = nil
        pdf.pages.each_with_index { |p, i| page_index = i if p == page }
        next unless page_index

        media_box = page[:CropBox] || page[:MediaBox]
        page_width = (media_box[2] - media_box[0]).to_f
        page_height = (media_box[3] - media_box[1]).to_f

        x0, y0, x1, y1 = widget[:Rect].map(&:to_f)
        x = x0 - media_box[0]
        y = y0 - media_box[1]
        w = x1 - x0
        h = y1 - y0

        mapped = mapping[1]
        attrs = PdfFieldParser.parse_sertifi_attributes(tag_content)

        rel_x = x / page_width
        rel_y = 1.0 - ((y + h) / page_height)
        rel_w = w / page_width
        rel_h = h / page_height

        if attrs[:width] > 0
          attr_rel_w = attrs[:width] / page_width
          rel_w = [rel_w, attr_rel_w].max
        end

        puts "  SFLD_MATCH: field=#{field_name.inspect} tag=#{tag_content.inspect} -> #{mapped[:name]} (#{mapped[:type]})"

        results << {
          field_name: field_name,
          name: mapped[:name] || attrs[:field_name] || field_name,
          type: mapped[:type] || 'text',
          required: attrs[:required],
          preferences: mapped[:preferences] || {},
          page: page_index,
          rel_x: [[rel_x, 0].max, 0.95].min,
          rel_y: [[rel_y, 0].max, 0.95].min,
          rel_w: [[rel_w, 0.02].max, 0.95].min,
          rel_h: [[rel_h, 0.01].max, 0.95].min
        }
      end

      results
    rescue StandardError => e
      puts "  SFLD_EXTRACT_ERROR: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      Rollbar.error(e) if defined?(Rollbar)
      []
    end

    # Find [[...]] tag content within a string
    def find_sertifi_tag_in(text)
      return nil if text.blank?

      match = text.match(PdfFieldParser::SERTIFI_TAG_REGEX)
      match[1] if match
    end

    # Match field names like "SertifiDate_1", "SertifiSStamp_1" directly
    def match_sertifi_field_name(name)
      return nil if name.blank?

      mapping = PdfFieldParser::SERTIFI_TAG_MAPPINGS.find { |pattern, _| name.match?(pattern) }
      name if mapping
    end

    # Find which page a field widget belongs to
    def find_page_for_field(pdf, widget)
      if widget[:P]
        p_obj = widget[:P]
        return p_obj if p_obj.is_a?(HexaPDF::Type::Page) || (p_obj.respond_to?(:[]) && p_obj[:Type] == :Page)
      end

      pdf.pages.each do |page|
        annots = page[:Annots]
        next unless annots

        annots.each do |annot|
          return page if annot == widget || (annot.respond_to?(:hash) && annot.hash == widget.hash)
        end
      end

      nil
    rescue StandardError
      nil
    end

    # Remove Sertifi-matched AcroForm fields from the PDF so their rendered
    # appearance (e.g., "SertifiSStamp_1" or "[[SFLD:FullName:...]]" as a field
    # name) disappears. Non-Sertifi fields (checkboxes, radios, other text
    # fields) are preserved.
    def remove_sertifi_fields_from_pdf(pdf_blob, sertifi_fields)
      doc = HexaPDF::Document.new(io: StringIO.new(pdf_blob))
      return pdf_blob unless doc.acro_form

      target_names = sertifi_fields.map { |sf| sf[:field_name] }.to_a

      fields_to_remove = []
      doc.acro_form.each_field do |field|
        fields_to_remove << field if target_names.include?(field.full_field_name.to_s)
      end

      return pdf_blob if fields_to_remove.empty?

      puts "  Removing #{fields_to_remove.size} Sertifi fields from PDF: #{fields_to_remove.map(&:full_field_name).join(', ')}"

      fields_to_remove.each do |field|
        if field.respond_to?(:each_widget)
          field.each_widget do |widget|
            page = (widget[:P] rescue nil)
            page[:Annots]&.delete(widget) if page.respond_to?(:[])
          end
        else
          page = (field[:P] rescue nil)
          page[:Annots]&.delete(field) if page.respond_to?(:[])
        end

        doc.acro_form.delete_field(field)
      rescue StandardError => e
        puts "    Warning: could not remove field #{field[:T]}: #{e.message}"
      end

      io = StringIO.new
      doc.write(io, validate: false)
      io.string
    rescue StandardError => e
      puts "  REMOVE_FIELDS_ERROR: #{e.message}"
      Rollbar.error(e) if defined?(Rollbar)
      pdf_blob
    end

    def template_name
      nil
    end
  end
end
