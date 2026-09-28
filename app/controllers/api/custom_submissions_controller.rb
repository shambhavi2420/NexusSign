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
        PdfSignatureBoxes.call(params[:pdf_base64], submitters_array)

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
        #    Per-submitter send_email/send_sms overrides the global flag
        #    (mirrors submissions#create behaviour).
        # ----------------------------------------------------------------
        global_send_email = params[:send_email] != false
        global_send_sms   = params[:send_sms] == true

        normalized_submitters = submitters_array.map do |s|
          submitter_send_email = if s.key?(:send_email)
                                   s[:send_email] != false && s[:send_email] != 'false'
                                 else
                                   global_send_email
                                 end

          submitter_send_sms = if s.key?(:send_sms)
                                 s[:send_sms] == true || s[:send_sms] == 'true'
                               else
                                 global_send_sms
                               end

          {
            'email'           => s[:email],
            'name'            => s[:name].presence,
            'role'            => s[:role],
            'phone'           => s[:phone].presence,
            'external_id'     => s[:external_id].presence,
            'application_key' => s[:application_key].presence,
            'metadata'        => s[:metadata].present? ? s[:metadata].to_h : {},
            'send_email'      => submitter_send_email,
            'send_sms'        => submitter_send_sms
          }.compact
        end

        create_params = ActionController::Parameters.new(
          template_id:      template.id,
          submitters:       normalized_submitters,
          submitters_order: params[:submitters_order] || 'preserved',
          send_email:       global_send_email,
          send_sms:         global_send_sms
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
    #
    # Signature-box drawing lives in the shared `PdfSignatureBoxes` service
    # (lib/pdf_signature_boxes.rb) so /api/submissions/from_pdf can reuse the
    # exact same layout when a tag-less PDF is submitted. See #create above,
    # which calls `PdfSignatureBoxes.call(params[:pdf_base64], submitters_array)`.

    # -------------------------------------------------------------------------
    # TEMPLATE CREATION
    # -------------------------------------------------------------------------

    # Creates a DocuSeal template with one submitter entry per signer and
    # places signature + date fields aligned to their respective boxes.
    def create_template_with_document(pdf_binary, filename, submitters_array, total_pages, box_layout)
      folder = TemplateFolder.create_with(author: current_user)
                             .find_or_create_by!(account_id: current_account.id, name: 'Custom Requests')

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
      # to that signer's box in box_layout (shared with from_pdf's tag-less path).
      fields = PdfSignatureBoxes.build_box_fields(box_layout, template_submitters, attachment_uuid)

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
