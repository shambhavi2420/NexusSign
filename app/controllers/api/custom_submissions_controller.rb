# /app/controllers/api/custom_submissions_controller.rb
require 'hexapdf'

module Api
  class CustomSubmissionsController < ApiBaseController
    skip_authorization_check only: [:create]

    def create
      unless params[:pdf_base64] && params[:submitter_email] && params[:submitter_role]
        return render json: { error: 'Missing required parameters' }, status: :bad_request
      end

      unless current_account&.id && current_user&.id
        return render json: { error: 'Authentication failed: No valid account found' }, status: :unauthorized
      end

      # Process PDF: Add {{signature}} at bottom of last page
      modified_pdf_data = process_pdf(params[:pdf_base64])
      modified_pdf_binary = Base64.decode64(modified_pdf_data)

      ActiveRecord::Base.transaction do
        # Create template properly using DocuSeal's service
        template = create_template_with_document(modified_pdf_binary, params[:filename])

        # Use the standard DocuSeal flow to create submission
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

        # Update submitter preferences
        submitter.update!(
          preferences: { 'role' => params[:submitter_role] },
          sent_at: Time.current
        )

        # Send signature request email
        begin
          send_signature_email(submitter) if params[:send_email] != false
        rescue => e
          Rails.logger.error("Failed to send email: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        end

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
      render json: {
        error: "Validation failed: #{e.record.errors.full_messages.join(', ')}"
      }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error("Error: #{e.message}\nBacktrace: #{e.backtrace.first(10).join("\n")}")
      render json: { error: e.message }, status: :internal_server_error
    end

    private

    def create_template_with_document(pdf_binary, filename)
      submitter_uuid = SecureRandom.uuid
      signature_uuid = SecureRandom.uuid

      # Create template
      template = Template.create!(
        account_id: current_account.id,
        author_id: current_user.id,
        name: filename,
        submitters: [
          {
            'name' => 'Signer',
            'uuid' => submitter_uuid
          }
        ]
      )

      # Create uploaded file from binary
      tempfile = Tempfile.new(['upload', '.pdf'], encoding: 'ascii-8bit')
      tempfile.binmode
      tempfile.write(pdf_binary)
      tempfile.rewind

      uploaded_file = ActionDispatch::Http::UploadedFile.new(
        tempfile: tempfile,
        filename: filename || 'document.pdf',
        type: 'application/pdf'
      )

      # Use DocuSeal's service to attach documents properly
      documents = Templates::CreateAttachments.call(
        template,
        { files: [uploaded_file] },
        extract_fields: true
      )

      # Create schema using actual attachment UUIDs
      schema = documents.map { |doc| { attachment_uuid: doc.uuid, name: doc.filename.base } }
      attachment_uuid = documents.first.uuid

      # Update template with schema and fields
      template.update!(
        schema: schema,
        fields: [
          {
            'uuid' => signature_uuid,
            'submitter_uuid' => submitter_uuid,
            'name' => 'signature',
            'type' => 'signature',
            'required' => true,
            'areas' => [
              {
                'x' => 0.75,
                'y' => 0.80,
                'w' => 0.25,
                'h' => 0.08,
                'page' => 0,
                'attachment_uuid' => attachment_uuid
              }
            ]
          }
        ]
      )

      tempfile.close
      tempfile.unlink

      template
    end

    def send_signature_email(submitter)
      SubmitterMailer.invitation_email(submitter).deliver_later!
    end

    def build_submitter_url(submitter)
      "#{request.base_url}/s/#{submitter.slug}"
    end

    def process_pdf(input_pdf_base64)
      input_pdf_data = Base64.decode64(input_pdf_base64)
      Tempfile.create(['input', '.pdf'], encoding: 'ascii-8bit') do |input_file|
        input_file.binmode
        input_file.write(input_pdf_data)
        input_file.rewind

        doc = HexaPDF::Document.open(input_file.path)
        last_page = doc.pages[-1]
        canvas = last_page.canvas(type: :overlay)
        canvas.font('Helvetica', size: 12)
        page_box = last_page.box(:media)
        x_pos = page_box.width * 0.5
        y_pos = page_box.height * 0.05
        #canvas.text('{{signature}}', at: [x_pos, y_pos])

        Tempfile.create(['output', '.pdf'], encoding: 'ascii-8bit') do |output_file|
          output_file.binmode
          doc.write(output_file.path)
          output_file.rewind
          Base64.strict_encode64(output_file.read)
        end
      end
    end
  end
end