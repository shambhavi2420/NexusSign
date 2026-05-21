require 'hexapdf'

module Api
  class CustomSubmissionsController < ApiBaseController
    skip_authorization_check only: [:create]

    # =========================================================================
    # POST /api/custom_submissions
    #
    # Accepts a base64-encoded PDF and an array of submitters, draws per-signer
    # signature boxes on the PDF (side-by-side for ≤3 signers on the last page;
    # appended blank page for 4+ signers), creates a DocuSeal template with
    # matching signature/date fields, and kicks off the ordered signing flow.
    #
    # Required params:
    #   pdf_base64   – base64-encoded PDF binary
    #   submitters   – array of { email:, role:, name:, phone:, ... }
    #
    # Optional params (mirror submissions#create):
    #   filename, submitters_order, send_email, send_sms,
    #   metadata, external_id, application_key
    # =========================================================================
    def create
      # ------------------------------------------------------------------
      # 1. Validate required parameters
      # ------------------------------------------------------------------
      if params[:pdf_base64].blank?
        return render json: { error: 'Missing required parameter: pdf_base64' },
                      status: :bad_request
      end

      if params[:submitters].blank? || !params[:submitters].is_a?(Array) && !params[:submitters].respond_to?(:to_unsafe_h)
        return render json: { error: 'Missing required parameter: submitters (must be an array)' },
                      status: :bad_request
      end

      submitters_array = params[:submitters].map do |s|
        s.respond_to?(:to_unsafe_h) ? s.to_unsafe_h.with_indifferent_access : s.with_indifferent_access
      end

      if submitters_array.any? { |s| s[:email].blank? }
        return render json: { error: 'Each submitter must have an email' },
                      status: :bad_request
      end

      if submitters_array.any? { |s| s[:role].blank? }
        return render json: { error: 'Each submitter must have a role' },
                      status: :bad_request
      end

      # ------------------------------------------------------------------
      # 2. Authentication check
      # ------------------------------------------------------------------
      unless current_account&.id && current_user&.id
        return render json: { error: 'Authentication failed: No valid account found' },
                      status: :unauthorized
      end

      # ------------------------------------------------------------------
      # 3. Process PDF — draw per-signer signature boxes
      #    Returns [modified_pdf_binary, total_pages, box_layout]
      #    box_layout is an array of { x:, y:, w:, h:, page: } per signer
      #    (normalised DocuSeal coords) used for field placement.
      # ------------------------------------------------------------------
      modified_pdf_binary, total_pages, box_layout =
        add_signature_boxes(params[:pdf_base64], submitters_array)

      ActiveRecord::Base.transaction do
        # ----------------------------------------------------------------
        # 4. Create template with one submitter entry per signer
        # ----------------------------------------------------------------
        template = create_template_with_document(
          modified_pdf_binary,
          params[:filename],
          submitters_array,
          total_pages,
          box_layout
        )

        # ----------------------------------------------------------------
        # 5. Build params compatible with Submissions.create_from_submitters
        # ----------------------------------------------------------------
        normalized_submitters = submitters_array.map do |s|
          {
            'email'           => s[:email],
            'name'            => s[:name].presence,
            'role'            => s[:role],
            'phone'           => s[:phone].presence,
            'external_id'     => s[:external_id].presence,
            'application_key' => s[:application_key].presence,
            'metadata'        => s[:metadata].present? ? s[:metadata].to_h : {},
            'send_email'      => params[:send_email] != false,
            'send_sms'        => params[:send_sms] == true
          }.compact
        end

        create_params = ActionController::Parameters.new(
          template_id:      template.id,
          submitters:       normalized_submitters,
          submitters_order: params[:submitters_order] || 'preserved',
          send_email:       params[:send_email] != false,
          send_sms:         params[:send_sms] == true
        )

        # ----------------------------------------------------------------
        # 6. Create submissions via the shared service (handles ordering)
        # ----------------------------------------------------------------
        submissions_attrs, attachments =
          Submissions::NormalizeParamUtils.normalize_submissions_params!(
            submissions_params(create_params),
            template
          )

        submissions = Submissions.create_from_submitters(
          template:,
          user:             current_user,
          source:           :api,
          submitters_order: create_params[:submitters_order],
          submissions_attrs:,
          params:           create_params
        )
        maybe_enforce_order(submissions)
        submitters_records = submissions.flat_map(&:submitters)
        Submissions::NormalizeParamUtils.save_default_value_attachments!(attachments, submitters_records)

        submitters_records.each do |submitter|
          Submitters::MaybeUpdateDefaultValues.call(submitter, current_user, fill_now: true)
        end

        # ----------------------------------------------------------------
        # 7. Fire webhooks, send ordered signature emails, reindex
        #    (mirrors submissions#create exactly)
        # ----------------------------------------------------------------
        WebhookUrls.enqueue_events(submissions, 'submission.created')
        Submissions.send_signature_requests(submissions)

        submissions.each do |submission|
          submission.submitters.each do |submitter|
            next unless submitter.completed_at?

            ProcessSubmitterCompletionJob.perform_async(
              'submitter_id'         => submitter.id,
              'send_invitation_email' => false
            )
          end
        end

        SearchEntries.enqueue_reindex(submissions)

        # ----------------------------------------------------------------
        # 8. Respond in the same shape as submissions#create
        # ----------------------------------------------------------------
        render json: build_create_json(submissions, create_params), status: :created
      end

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Validation Error: #{e.message}\nErrors: #{e.record.errors.full_messages}")
      render json: { error: "Validation failed: #{e.record.errors.full_messages.join(', ')}" },
             status: :unprocessable_entity
    rescue Submitters::NormalizeValues::BaseError,
           Submissions::CreateFromSubmitters::BaseError,
           DownloadUtils::UnableToDownload => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error(
        "Error in CustomSubmissionsController#create: #{e.message}\n" \
        "Backtrace: #{e.backtrace.first(10).join("\n")}"
      )
      render json: { error: "Internal Server Error: #{e.message}" },
             status: :internal_server_error
    end

    # =========================================================================
    private
    # =========================================================================

    # -------------------------------------------------------------------------
    # PDF PROCESSING
    # -------------------------------------------------------------------------

    # Decodes the base64 PDF, draws one signature box per signer:
    #   - ≤ 3 signers → side-by-side row at the bottom of the LAST page
    #   - ≥ 4 signers → appended blank page (same dimensions as last page),
    #                    boxes in rows of 3 from the TOP of that page
    #
    # Returns [modified_pdf_binary, total_pages, box_layout]
    # box_layout: Array of { x:, y:, w:, h:, page: } in DocuSeal normalised coords
    def add_signature_boxes(input_pdf_base64, submitters_array)
      pdf_binary  = Base64.decode64(input_pdf_base64)
      n           = submitters_array.size
      result      = nil
      total_pages = nil
      box_layout  = []

      Tempfile.create(['labeled_input', '.pdf'], encoding: 'ascii-8bit') do |input_file|
        input_file.binmode
        input_file.write(pdf_binary)
        input_file.rewind

        doc             = HexaPDF::Document.open(input_file.path)
        original_pages  = doc.pages.count
        last_page       = doc.pages[-1]
        page_box        = last_page.box(:media)
        page_w          = page_box.width.to_f
        page_h          = page_box.height.to_f

        if n <= 3
          # ------------------------------------------------------------------
          # CASE A: ≤ 3 signers — single row at the bottom of the last page
          # ------------------------------------------------------------------
          box_layout = draw_signature_row(
            doc,
            last_page,
            page_w,
            page_h,
            submitters_array,
            row_index:    0,
            page_index:   original_pages - 1,
            anchor:       :bottom  # pin to bottom of page
          )
          total_pages = original_pages
        else
          # ------------------------------------------------------------------
          # CASE B: ≥ 4 signers — append a blank page, rows of 3 from the top
          # ------------------------------------------------------------------
          new_page = doc.pages.add
          new_page.box(:media, value: [0, 0, page_w, page_h])

          total_pages    = original_pages + 1   # the appended page
          new_page_index = total_pages - 1

          rows = submitters_array.each_slice(3).to_a
          rows.each_with_index do |row_signers, row_idx|
            row_layout = draw_signature_row(
              doc,
              new_page,
              page_w,
              page_h,
              row_signers,
              row_index:  row_idx,
              page_index: new_page_index,
              anchor:     :top   # stack rows downward from the top
            )
            box_layout.concat(row_layout)
          end
        end

        Tempfile.create(['labeled_output', '.pdf'], encoding: 'ascii-8bit') do |output_file|
          output_file.binmode
          doc.write(output_file.path)
          output_file.rewind
          result = output_file.read
        end
      end

      Rails.logger.info(
        "[CustomSubmissions] PDF pages after processing: #{total_pages}, " \
        "boxes drawn: #{box_layout.size}"
      )

      [result, total_pages, box_layout]
    end

    # Draws a horizontal row of signature boxes onto `page` for the given
    # `signers` sub-array and returns their DocuSeal-normalised coordinates.
    #
    # anchor: :bottom → boxes pinned to the page bottom (last-page case)
    #         :top    → boxes stacked from the top, offset by row_index (appended page)
def draw_signature_row(doc, page, page_w, page_h, signers, row_index:, page_index:, anchor:)
  n          = signers.size
  margin_x   = page_w * 0.03
  margin_y   = page_h * 0.03
  box_h      = page_h * 0.12
  row_gap    = page_h * 0.015
  total_w    = page_w - (2 * margin_x)
  gap        = page_w * 0.01

  # Use max 3-column sizing so single signer doesn't stretch
  reference_columns = [n, 3].max
  standard_box_w    = (total_w - (gap * (reference_columns - 1))) / reference_columns

  box_w = standard_box_w

  # Vertical position
  box_y = if anchor == :bottom
    margin_y * 0.4
  else
    page_h - margin_y - box_h - (row_index * (box_h + row_gap))
  end

  canvas = page.canvas(type: :overlay)

  box_layout = signers.each_with_index.map do |signer, i|
    # Left aligned positioning
    box_x = margin_x + i * (box_w + gap)

    email      = signer[:email]
    role_label = signer[:role].to_s

    draw_single_box(canvas, box_x, box_y, box_w, box_h, email, role_label)

    ds_x = box_x / page_w
    ds_y = 1.0 - (box_y + box_h) / page_h + 0.009
    ds_w = box_w / page_w
    ds_h = box_h / page_h

    {
      x:    ds_x,
      y:    ds_y,
      w:    ds_w,
      h:    ds_h,
      page: page_index
    }
  end

  box_layout
end
    # Renders a single box with background, border, and two text lines.
    def draw_single_box(canvas, box_x, box_y, box_w, box_h, email, role_label)
  padding = 6
  line_height = 9

  # Background + Border (same as before)
  canvas.save_graphics_state
  canvas.fill_color(0.94, 0.96, 0.98)
  canvas.rectangle(box_x, box_y, box_w, box_h).fill
  canvas.restore_graphics_state

  canvas.save_graphics_state
  canvas.stroke_color(0.4, 0.5, 0.6)
  canvas.line_width(0.6)
  canvas.rectangle(box_x, box_y, box_w, box_h).stroke
  canvas.restore_graphics_state

  # Role label (top)
  canvas.fill_color(0.35, 0.35, 0.35)
  canvas.font('Helvetica', size: 7)
  canvas.text(role_label, at: [box_x + padding, box_y + box_h - padding - 2])

  # "Digitally signed by" line (bottom)
  canvas.font('Helvetica', size: 6)
  canvas.text("Digitally signed by #{email}", at: [box_x + padding, box_y + padding + 1])
end
    # -------------------------------------------------------------------------
    # TEMPLATE CREATION
    # -------------------------------------------------------------------------

    # Creates a DocuSeal template with one submitter entry per signer and
    # places signature + date fields aligned to their respective boxes.
    def create_template_with_document(pdf_binary, filename, submitters_array, total_pages, box_layout)
      folder = TemplateFolder.find_or_create_by!(
        account_id: current_account.id,
        name:       'Custom Requests'
      )

      # One { uuid, name } entry per signer — role becomes the submitter name
      template_submitters = submitters_array.map do |s|
        { 'name' => s[:role], 'uuid' => SecureRandom.uuid }
      end

      template = Template.create!(
        account_id: current_account.id,
        author_id:  current_user.id,
        name:       filename.presence || 'Signed Document',
        submitters: template_submitters,
        folder_id:  folder.id,
        preferences: { 'submitters_order' => 'preserved' }
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
      # {{Signature}} / {{DateSigned}} tags in the PDF text, which would
      # create unwanted fields on earlier pages.
      documents       = Templates::CreateAttachments.call(
        template,
        { files: [uploaded_file] },
        extract_fields: false
      )
      attachment_uuid = documents.first.uuid
      schema          = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

      Rails.logger.info(
        "[CustomSubmissions] Creating template with #{submitters_array.size} submitters, " \
        "#{total_pages} pages, #{box_layout.size} field boxes"
      )

      # Build one signature field + one date field per signer, each anchored
      # to that signer's box in box_layout.
      fields = submitters_array.each_with_index.flat_map do |signer, i|
        submitter_uuid = template_submitters[i]['uuid']
        box            = box_layout[i]

        next [] unless box   # safety guard

        signature_uuid = SecureRandom.uuid
        date_uuid      = SecureRandom.uuid

        # Signature field — upper ~60% of the box interior
        sig_h    = box[:h] * 0.55
        sig_y    = box[:y] + box[:h] * 0.06   # just inside the top edge

        # Date field — bottom strip, aligned with the lower text label
        date_h   = box[:h] * 0.16
        date_y   = box[:y] + box[:h] * 0.60

        [
          {
            'uuid'           => signature_uuid,
            'submitter_uuid' => submitter_uuid,
            'name'           => "signature_#{i + 1}",
            'type'           => 'signature',
            'required'       => true,
            'areas'          => [{
              'x'               => box[:x] + box[:w] * 0.05,
              'y'               => sig_y,
              'w'               => box[:w] * 0.90,
              'h'               => sig_h,
              'page'            => box[:page],
              'attachment_uuid' => attachment_uuid
            }]
          },
          {
            'uuid'           => date_uuid,
            'submitter_uuid' => submitter_uuid,
            'name'           => "signed_date_#{i + 1}",
            'type'           => 'date',
            'required'       => false,
            'readonly'       => true,
            'default_value'  => '{{date}}',
            'areas'          => [{
              'x'               => box[:x] + box[:w] * 0.05,
              'y'               => date_y,
              'w'               => box[:w] * 0.55,
              'h'               => date_h,
              'page'            => box[:page],
              'attachment_uuid' => attachment_uuid
            }]
          }
        ]
      end.compact

      template.update!(schema: schema, fields: fields)

      tempfile.close
      tempfile.unlink
      template
    end

    # -------------------------------------------------------------------------
    # RESPONSE HELPERS (mirror submissions_controller exactly)
    # -------------------------------------------------------------------------

    def build_create_json(submissions, create_params)
      submissions.flat_map do |submission|
        submission.submitters.map do |s|
          Submitters::SerializeForApi.call(s, with_documents: false, with_urls: true, params: create_params)
        end
      end
    end

    # -------------------------------------------------------------------------
    # PARAMS HELPER (mirrors submissions_controller#submissions_params)
    # -------------------------------------------------------------------------

    def submissions_params(p)
      permitted_attrs = [
        :send_email, :send_sms, :submitters_order,
        {
          submitters: [
            :send_email, :send_sms, :uuid, :name, :email, :role,
            :completed, :phone, :application_key, :external_id, :order,
            { metadata: {}, values: {}, roles: [], readonly_fields: [] }
          ]
        }
      ]

      p.permit(*permitted_attrs)
    end
  end
end
