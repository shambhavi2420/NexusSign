require 'hexapdf'

module Api
  class CustomSubmissionsController < ApiBaseController
    skip_authorization_check only: [:create]

    def create
      # 1. Validate required parameters
      required_params = %i[pdf_base64 submitter_email submitter_role]
      missing_params = required_params.select { |p| params[p].blank? }

      unless missing_params.empty?
        return render json: { error: "Missing required parameters: #{missing_params.join(', ')}" },
                      status: :bad_request
      end

      # 2. Authentication check
      unless current_account&.id && current_user&.id
        return render json: { error: 'Authentication failed: No valid account found' },
                      status: :unauthorized
      end

      # 3. Process PDF — adds the blue signature box to the last page
      #    Also returns the actual page count of the resulting PDF
      modified_pdf_binary, total_pages = add_signature_labels(
        params[:pdf_base64],
        params[:submitter_email]
      )

      ActiveRecord::Base.transaction do
        # 4. Create template, passing the known page count so field placement is exact
        template = create_template_with_document(
          modified_pdf_binary,
          params[:filename],
          params[:submitter_email],
          total_pages
        )

        # 5. Create submission
        submissions = Submissions.create_from_emails(
          template:     template,
          user:         current_user,
          source:       :api,
          mark_as_sent: false,
          emails:       params[:submitter_email],
          params:       ActionController::Parameters.new(send_email: false, send_sms: false)
        )

        submission = submissions.first
        submitter  = submission.submitters.first

        # 6. Build submitter preferences
        preferences = {
          'role'       => params[:submitter_role],
          'send_email' => params[:send_email] != false,
          'send_sms'   => params[:send_sms] == true
        }

        application_key = params[:application_key].presence
        preferences['application_key'] = application_key if application_key.present?

        metadata    = params[:metadata].present? ? params[:metadata].to_unsafe_h : {}
        external_id = params[:external_id].presence
        name        = params[:name].presence || params[:submitter_name].presence
        phone       = params[:phone].presence

        submitter.update!(
          name:        name,
          phone:       phone,
          preferences: preferences,
          metadata:    metadata,
          external_id: external_id,
          sent_at:     Time.current
        )

        # 7. Send signature email unless suppressed
        send_signature_email(submitter) if params[:send_email] != false

        # 8. Respond in standard API format
        render json: [{
          id:            submitter.id,
          slug:          submitter.slug,
          uuid:          submitter.uuid,
          name:          submitter.name,
          email:         submitter.email,
          phone:         submitter.phone,
          completed_at:  submitter.completed_at,
          declined_at:   submitter.declined_at,
          external_id:   submitter.external_id,
          submission_id: submission.id,
          metadata:      submitter.metadata,
          opened_at:     submitter.opened_at,
          sent_at:       submitter.sent_at,
          created_at:    submitter.created_at,
          updated_at:    submitter.updated_at,
          status:        submitter.completed_at? ? 'completed' : 'sent',
          application_key: application_key,
          values:        submitter.values || [],
          preferences:   submitter.preferences,
          role:          params[:submitter_role],
          embed_src:     build_submitter_url(submitter)
        }], status: :created
      end

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Validation Error: #{e.message}\nErrors: #{e.record.errors.full_messages}")
      render json: { error: "Validation failed: #{e.record.errors.full_messages.join(', ')}" },
             status: :unprocessable_entity
    rescue => e
      Rails.logger.error(
        "Error in CustomSubmissionsController#create: #{e.message}\n" \
        "Backtrace: #{e.backtrace.first(10).join("\n")}"
      )
      render json: { error: "Internal Server Error: #{e.message}" },
             status: :internal_server_error
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    # Decodes the base64 PDF, draws a signature box on the last page,
    # and returns [modified_pdf_binary, total_page_count].
    def add_signature_labels(input_pdf_base64, submitter_email)
      pdf_binary = Base64.decode64(input_pdf_base64)

      result_binary = nil
      total_pages   = nil

      Tempfile.create(['labeled_input', '.pdf'], encoding: 'ascii-8bit') do |input_file|
        input_file.binmode
        input_file.write(pdf_binary)
        input_file.rewind

        doc       = HexaPDF::Document.open(input_file.path)
        total_pages = doc.pages.count          # ← count BEFORE we write

        last_page  = doc.pages[-1]
        canvas     = last_page.canvas(type: :overlay)
        page_box   = last_page.box(:media)

        # Box geometry
        box_width  = page_box.width  * 0.35
        box_height = page_box.height * 0.12
        margin_x   = page_box.width  * 0.05
        margin_y   = page_box.height * 0.03
        box_x      = margin_x
        box_y      = margin_y

        padding     = 8
        line_height = 10

        # Filled background
        canvas.save_graphics_state
        canvas.fill_color(0.94, 0.96, 0.98)
        canvas.rectangle(box_x, box_y, box_width, box_height).fill
        canvas.restore_graphics_state

        # Border
        canvas.save_graphics_state
        canvas.stroke_color(0.4, 0.5, 0.6)
        canvas.line_width(0.6)
        canvas.rectangle(box_x, box_y, box_width, box_height).stroke
        canvas.restore_graphics_state

        # Text labels
        text_y_line1 = box_y + padding + line_height
        text_y_line2 = box_y + padding

        canvas.fill_color(0.35, 0.35, 0.35)
        canvas.font('Helvetica', size: 7)
        canvas.text("Digitally signed by #{submitter_email}", at: [box_x + padding, text_y_line1])
        canvas.text("Date:",                                   at: [box_x + padding, text_y_line2])

        Tempfile.create(['labeled_output', '.pdf'], encoding: 'ascii-8bit') do |output_file|
          output_file.binmode
          doc.write(output_file.path)
          output_file.rewind
          result_binary = output_file.read
        end
      end

      Rails.logger.info("[CustomSubmissions] PDF page count after HexaPDF write: #{total_pages}")
      [result_binary, total_pages]
    end

    # Creates a DocuSeal template with the modified PDF and places the
    # signature + date fields precisely on the last page.
    def create_template_with_document(pdf_binary, filename, submitter_email, total_pages)
      submitter_uuid = SecureRandom.uuid
      signature_uuid = SecureRandom.uuid
      date_uuid      = SecureRandom.uuid
      folder = TemplateFolder.find_or_create_by!(account_id: current_account.id, name: 'Custom Requests')
      template = Template.create!(
        account_id:  current_account.id,
        author_id:   current_user.id,
        name:        filename.presence || 'Signed Document',
        submitters:  [{ 'name' => 'Signer', 'uuid' => submitter_uuid }],
        folder_id:   folder.id
      )

      tempfile = Tempfile.new(['upload', '.pdf'], encoding: 'ascii-8bit')
      tempfile.binmode
      tempfile.write(pdf_binary)
      tempfile.rewind

      uploaded_file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename.presence || 'document.pdf',
        type:     'application/pdf'
      )

      # extract_fields: false — prevents DocuSeal from auto-detecting
      # {{Signature}} / {{DateSigned}} tags already present in the PDF text,
      # which would create unwanted fields on earlier pages.
      documents       = Templates::CreateAttachments.call(
        template,
        { files: [uploaded_file] },
        extract_fields: false
      )
      attachment_uuid = documents.first.uuid
      schema          = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

      # Use the page count we measured directly from the HexaPDF-written binary.
      # This is the ground truth — DocuSeal attachment metadata may lag or differ.
      last_page_index = [total_pages - 1, 0].max

      Rails.logger.info(
        "[CustomSubmissions] Placing fields on page index #{last_page_index} " \
        "(1-based: page #{last_page_index + 1} of #{total_pages})"
      )

      # Coordinates mirror the blue box drawn by add_signature_labels.
      #
      # HexaPDF coordinate system: origin (0,0) is BOTTOM-LEFT of page.
      #   box_x      = page_width  * 0.05   → left edge
      #   box_y      = page_height * 0.03   → bottom edge
      #   box_width  = page_width  * 0.35
      #   box_height = page_height * 0.12
      #
      # DocuSeal coordinate system: origin (0,0) is TOP-LEFT, values 0..1 (normalised).
      #   docuseal_x = hexapdf_x / page_width
      #   docuseal_y = 1 - (hexapdf_y + element_height) / page_height
      #
      # Blue box in normalised HexaPDF coords:
      #   left   = 0.05,  right  = 0.05 + 0.35 = 0.40
      #   bottom = 0.03,  top    = 0.03 + 0.12  = 0.15
      #
      # Converted to DocuSeal (y flipped):
      #   box top    in DocuSeal = 1 - 0.15 = 0.85
      #   box bottom in DocuSeal = 1 - 0.03 = 0.97

      sig_box_left_ds  = 0.05          # same in both systems (x not flipped)
      sig_box_top_ds   = 1.0 - 0.15   # = 0.85  ← top of blue box in DocuSeal
      sig_box_bot_ds   = 1.0 - 0.03   # = 0.97  ← bottom of blue box in DocuSeal

      # Signature field — upper portion of the box, leaving room for the text labels
      # Occupies roughly the top 55% of the box interior
      sig_area_h  = 0.055
      sig_area_y  = sig_box_top_ds + 0.005   # just inside the top edge of the blue box

      # Date field — bottom strip, inline with the "Date:" label
      # The two text lines each occupy ~line_height/page_height ≈ 0.013 each.
      # "Date:" is the lower line, so it sits at box_bottom - padding - line_height in HexaPDF.
      # In DocuSeal that maps to near sig_box_bot_ds minus a small offset.
      date_area_h = 0.013
      date_area_y = sig_box_bot_ds - 0.018   # aligns with the "Date:" text line

      template.update!(
        schema: schema,
        fields: [
          {
            'uuid'           => signature_uuid,
            'submitter_uuid' => submitter_uuid,
            'name'           => 'signature',
            'type'           => 'signature',
            'required'       => true,
            'areas'          => [{
              'x'               => sig_box_left_ds + 0.015,
              'y'               => sig_area_y,
              'w'               => 0.28,
              'h'               => sig_area_h,
              'page'            => last_page_index,
              'attachment_uuid' => attachment_uuid
            }]
          },
          {
            'uuid'           => date_uuid,
            'submitter_uuid' => submitter_uuid,
            'name'           => 'signed_date',
            'type'           => 'date',
            'required'       => false,
            'readonly'       => true,
            'default_value'  => '{{date}}',
            'areas'          => [{
              'x'               => sig_box_left_ds + 0.045,
              'y'               => date_area_y,
              'w'               => 0.12,
              'h'               => date_area_h,
              'page'            => last_page_index,
              'attachment_uuid' => attachment_uuid
            }]
          }
        ]
      )

      tempfile.close
      tempfile.unlink
      template
    end

    def send_signature_email(submitter)
      SubmitterMailer.invitation_email(submitter).deliver_later!
    rescue => e
      Rails.logger.error(
        "Failed to send email for submitter #{submitter.id}: #{e.message}\n" \
        "#{e.backtrace.first(5).join("\n")}"
      )
      raise
    end

    def build_submitter_url(submitter)
      "#{request.base_url}/s/#{submitter.slug}"
    end
  end
end
