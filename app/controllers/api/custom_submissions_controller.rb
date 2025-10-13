require 'hexapdf'

module Api
  class CustomSubmissionsController < ApiBaseController
    skip_authorization_check only: [:create]

    def create
      # 1. Validate required parameters
      required_params = %i[pdf_base64 submitter_email submitter_role]
      missing_params = required_params.select { |p| params[p].blank? }
      unless missing_params.empty?
        return render json: { error: "Missing required parameters: #{missing_params.join(', ')}" }, status: :bad_request
      end

      # 2. Authentication check
      unless current_account&.id && current_user&.id
        return render json: { error: 'Authentication failed: No valid account found' }, status: :unauthorized
      end

      # 3. Process PDF
      modified_pdf_binary = add_signature_labels(params[:pdf_base64], params[:submitter_email])

      ActiveRecord::Base.transaction do
        # 4. Create template
        template = create_template_with_document(modified_pdf_binary, params[:filename], params[:submitter_email])

        # 5. Create submission
        submissions = Submissions.create_from_emails(
          template: template,
          user: current_user,
          source: :api,
          mark_as_sent: false,
          emails: params[:submitter_email],
          params: ActionController::Parameters.new(send_email: false, send_sms: false)
        )

        submission = submissions.first
        submitter = submission.submitters.first

        # 6. Update submitter preferences and sent status
        submitter.update!(
          preferences: { 'role' => params[:submitter_role] },
          sent_at: Time.current
        )

        # 7. Send signature email if not suppressed
        send_signature_email(submitter) if params[:send_email] != false

        # 8. Success response
        render json: {
          id: submission.id,
          slug: submission.slug,
          submitters: [{
            id: submitter.id,
            email: submitter.email,
            slug: submitter.slug,
            role: params[:submitter_role],
            url: build_submitter_url(submitter),
            status: submitter.completed_at? ? 'completed' : 'pending'
          }],
          expire_at: submission.expire_at,
          created_at: submission.created_at
        }, status: :created
      end

    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error("Validation Error: #{e.message}\nErrors: #{e.record.errors.full_messages}")
      render json: { error: "Validation failed: #{e.record.errors.full_messages.join(', ')}" }, status: :unprocessable_entity
    rescue => e
      Rails.logger.error("Error in CustomSubmissionsController#create: #{e.message}\nBacktrace: #{e.backtrace.first(10).join("\n")}")
      render json: { error: "Internal Server Error: #{e.message}" }, status: :internal_server_error
    end

    private

    def add_signature_labels(input_pdf_base64, submitter_email)
      pdf_binary = Base64.decode64(input_pdf_base64)

      Tempfile.create(['labeled', '.pdf'], encoding: 'ascii-8bit') do |input_file|
        input_file.binmode
        input_file.write(pdf_binary)
        input_file.rewind

        doc = HexaPDF::Document.open(input_file.path)
        last_page = doc.pages[-1]
        canvas = last_page.canvas(type: :overlay)
        page_box = last_page.box(:media)

        # Box dimensions - compact width
        box_width = page_box.width * 0.35
        box_height = page_box.height * 0.12
        margin_x = page_box.width * 0.05
        margin_y = page_box.height * 0.03
        box_x = margin_x
        box_y = margin_y

        # Inner padding
        padding = 8
        line_height = 10

        # Draw filled box with softer color
        canvas.save_graphics_state
        canvas.fill_color(0.94, 0.96, 0.98)  # Very light blue-gray
        canvas.rectangle(box_x, box_y, box_width, box_height).fill
        canvas.restore_graphics_state

        # Draw subtle border
        canvas.save_graphics_state
        canvas.stroke_color(0.4, 0.5, 0.6)  # Muted blue-gray
        canvas.line_width(0.6)
        canvas.rectangle(box_x, box_y, box_width, box_height).stroke
        canvas.restore_graphics_state

        # Add metadata text at bottom in smaller, lighter font
        text_x = box_x + padding
        text_y_line1 = box_y + padding + line_height
        text_y_line2 = box_y + padding

        canvas.fill_color(0.35, 0.35, 0.35)  # Medium gray
        canvas.font('Helvetica', size: 7)

        # First line: Digitally signed by email
        canvas.text("Digitally signed by #{submitter_email}", at: [text_x, text_y_line1])

        # Second line: Date label (actual date will be filled in by the date field)
        canvas.text("Date:", at: [text_x, text_y_line2])

        # Output PDF
        Tempfile.create(['output_labeled', '.pdf'], encoding: 'ascii-8bit') do |output_file|
          output_file.binmode
          doc.write(output_file.path)
          output_file.rewind
          output_file.read
        end
      end
    end

    def create_template_with_document(pdf_binary, filename, submitter_email)
      submitter_uuid = SecureRandom.uuid
      signature_uuid = SecureRandom.uuid
      date_uuid = SecureRandom.uuid

      template = Template.create!(
        account_id: current_account.id,
        author_id: current_user.id,
        name: filename || 'Signed Document',
        submitters: [{ 'name' => 'Signer', 'uuid' => submitter_uuid }]
      )

      tempfile = Tempfile.new(['upload', '.pdf'], encoding: 'ascii-8bit')
      tempfile.binmode
      tempfile.write(pdf_binary)
      tempfile.rewind

      uploaded_file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename || 'document.pdf',
        type: 'application/pdf'
      )

      documents = Templates::CreateAttachments.call(template, { files: [uploaded_file] }, extract_fields: true)
      attachment_uuid = documents.first.uuid
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }

      # Coordinates for compact signature box
      sig_box_x_start = 0.05
      sig_box_y_start = 0.83

      # Get the last page index
      last_page_index = documents.first.metadata['pdf']&.dig('page_count').to_i - 1
      last_page_index = [last_page_index, 0].max

      template.update!(
        schema: schema,
        fields: [
          {
            'uuid' => signature_uuid,
            'submitter_uuid' => submitter_uuid,
            'name' => 'signature',
            'type' => 'signature',
            'required' => true,
            'areas' => [{
              'x' => sig_box_x_start + 0.015,
              'y' => sig_box_y_start + 0.05,  # Position above the text lines
              'w' => 0.28,  # Nearly full width of box minus padding
              'h' => 0.05,
              'page' => last_page_index,
              'attachment_uuid' => attachment_uuid
            }]
          },
          {
            'uuid' => date_uuid,
            'submitter_uuid' => submitter_uuid,
            'name' => 'signed_date',
            'type' => 'date',
            'required' => false,
            'readonly' => true,
            'default_value' => '{{date}}',
            'areas' => [{
              'x' => sig_box_x_start + 0.045,  # Position after "Date:" label
              'y' => sig_box_y_start + 0.12,  # Align with "Date:" text line
              'w' => 0.12,
              'h' => 0.015,  # Small height for inline date
              'page' => last_page_index,
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
      Rails.logger.error("Failed to send email for submitter #{submitter.id}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      raise
    end

    def build_submitter_url(submitter)
      "#{request.base_url}/s/#{submitter.slug}"
    end
  end
end