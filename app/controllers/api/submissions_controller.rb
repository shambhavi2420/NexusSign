# frozen_string_literal: true

module Api
  class SubmissionsController < ApiBaseController
    load_and_authorize_resource :template, only: :create
    load_and_authorize_resource :submission, only: %i[show index destroy]

    before_action only: :create do
      authorize!(:create, Submission)
    end

    def index
      submissions = Submissions.search(current_user, @submissions, params[:q])
      submissions = filter_submissions(submissions, params)

      submissions = paginate(submissions.preload(:created_by_user, :submitters,
                                                 template: { folder: :parent_folder },
                                                 combined_document_attachment: :blob,
                                                 audit_trail_attachment: :blob))

      expires_at = Accounts.link_expires_at(current_account)

      render json: {
        data: submissions.map do |s|
          Submissions::SerializeForApi.call(s, s.submitters, params,
                                            with_events: false, with_documents: false, with_values: false, expires_at:)
        end,
        pagination: {
          count: submissions.size,
          next: submissions.last&.id,
          prev: submissions.first&.id
        }
      }
    end

    def show
      submitters = @submission.submitters.preload(documents_attachments: :blob, attachments_attachments: :blob)

      submitters.each do |submitter|
        if submitter.completed_at? && submitter.documents_attachments.blank?
          submitter.documents_attachments = Submissions::EnsureResultGenerated.call(submitter)
        end
      end

      if @submission.audit_trail_attachment.blank? && submitters.all?(&:completed_at?)
        @submission.audit_trail_attachment = Submissions::EnsureAuditGenerated.call(@submission)
      end

      render json: Submissions::SerializeForApi.call(@submission, submitters, params)
    end

    def create
      # Support flat body style (submitter_email / submitter_role at top level)
      # in addition to the standard nested submitters array.
      normalize_flat_submitter_params! if params[:submitter_email].present? && params[:submitters].blank?

      Params::SubmissionCreateValidator.call(params)

      @template = Template.find_by(id: params[:template_id])
      return render json: { error: 'Template not found' }, status: :unprocessable_content if @template.nil?

      if @template.fields.blank?
        Rollbar.warning("Template does not contain fields: #{@template.id}") if defined?(Rollbar)
        return render json: { error: 'Template does not contain fields' }, status: :unprocessable_content
      end

      params[:send_email] = true unless params.key?(:send_email)
      params[:send_sms] = false unless params.key?(:send_sms)

      submissions = create_submissions(@template, params)

      submissions.each do |submission|
        submission.submitters.each do |submitter|
          assign_submitter_preferences(submitter, params)
          Submitters::MaybeUpdateDefaultValues.call(submitter, current_user, fill_now: true)
        end
      end

      WebhookUrls.enqueue_events(submissions, 'submission.created')
      Submissions.send_signature_requests(submissions)

      submissions.each do |submission|
        submission.submitters.each do |submitter|
          next unless submitter.completed_at?

          ProcessSubmitterCompletionJob.perform_async('submitter_id' => submitter.id, 'send_invitation_email' => false)
        end
      end

      SearchEntries.enqueue_reindex(submissions)

      render json: build_create_json(submissions)
    rescue Submitters::NormalizeValues::BaseError, Submissions::CreateFromSubmitters::BaseError,
           DownloadUtils::UnableToDownload => e
      Rollbar.warning(e) if defined?(Rollbar)

      render json: { error: e.message }, status: :unprocessable_content
    end

    def destroy
      if params[:permanently].in?(['true', true])
        @submission.destroy!
      else
        @submission.update!(archived_at: Time.current)
        WebhookUrls.enqueue_events(@submission, 'submission.archived')
      end

      render json: @submission.as_json(only: %i[id archived_at])
    end

    def create_link_only
      Params::SubmissionCreateValidator.call(params)

      @template = Template.find_by(id: params[:template_id])
      return render json: { error: 'Template not found' }, status: :unprocessable_content if @template.nil?
      authorize!(:create, Submission)

      if @template.fields.blank?
        Rollbar.warning("Template does not contain fields: #{@template.id}") if defined?(Rollbar)
        return render json: { error: 'Template does not contain fields' }, status: :unprocessable_content
      end

      params[:send_email] = false
      params[:send_sms] = false

      submissions = create_submissions(@template, params)

      submissions.each do |submission|
        submission.submitters.each do |submitter|
          assign_submitter_preferences(submitter, params)
          Submitters::MaybeUpdateDefaultValues.call(submitter, current_user, fill_now: true)

          next unless submitter.completed_at?

          ProcessSubmitterCompletionJob.perform_async('submitter_id' => submitter.id, 'send_invitation_email' => false)
        end
      end

      SearchEntries.enqueue_reindex(submissions)

      render json: build_create_json(submissions)

    rescue Submitters::NormalizeValues::BaseError, Submissions::CreateFromSubmitters::BaseError,
           DownloadUtils::UnableToDownload => e
      Rollbar.warning(e) if defined?(Rollbar)
      render json: { error: e.message }, status: :unprocessable_content
    end

    def create_and_complete
      Params::SubmissionCreateValidator.call(params)

      @template = Template.find_by(id: params[:template_id])
      return render json: { error: 'Template not found' }, status: :unprocessable_content if @template.nil?
      authorize!(:create, Submission)

      if @template.fields.blank?
        Rollbar.warning("Template does not contain fields: #{@template.id}") if defined?(Rollbar)
        return render json: { error: 'Template does not contain fields' }, status: :unprocessable_content
      end

      modified_hash = params.to_unsafe_hash.deep_dup
      modified_hash[:send_email] = false
      modified_hash[:send_sms] = false

      if modified_hash[:submitters].present?
        modified_hash[:submitters] = modified_hash[:submitters].map { |s| s.to_h.merge(completed: true) }
      end
      if modified_hash[:submission].present? && modified_hash[:submission][:submitters].present?
        modified_hash[:submission][:submitters] = modified_hash[:submission][:submitters].map { |s| s.to_h.merge(completed: true) }
      end

      modified_params = ActionController::Parameters.new(modified_hash)

      ActiveRecord::Base.transaction do
        submissions = create_submissions(@template, modified_params)

        if submissions.empty?
          raise Submissions::CreateFromSubmitters::BaseError, 'Submission creation failed. Check template required fields/values.'
        end

        submissions.each do |submission|
          submission.submitters.each do |submitter|
            assign_submitter_preferences(submitter, params)
            Submitters::MaybeUpdateDefaultValues.call(submitter, current_user, fill_now: true)

            if submitter.completed_at?
              ProcessSubmitterCompletionJob.perform_async('submitter_id' => submitter.id, 'send_invitation_email' => false)
            end
          end
          SearchEntries.enqueue_reindex(submission)
        end

        render json: build_create_and_complete_json(submissions)
      end

    rescue Submitters::NormalizeValues::BaseError, Submissions::CreateFromSubmitters::BaseError,
           DownloadUtils::UnableToDownload => e
      Rollbar.warning(e) if defined?(Rollbar)
      render json: { error: e.message }, status: :unprocessable_content
    end

    def from_pdf
      authorize!(:create, Submission)
      authorize!(:create, Template)

      unless params[:file].present? || params[:documents]&.first&.dig(:file).present?
        return render json: { error: 'PDF file is required' }, status: :unprocessable_entity
      end

      file_data = if params[:file].present?
        params[:file]
      else
        params[:documents].first[:file]
      end

      pdf_content = if file_data.is_a?(String)
        Base64.decode64(file_data)
      else
        file_data.read
      end

      temp_file = Tempfile.new(['upload', '.pdf'])
      temp_file.binmode
      temp_file.write(pdf_content)
      temp_file.rewind

      parsed_data = PdfFieldParser.call(temp_file.path)

      if parsed_data[:fields].empty?
        temp_file.close
        temp_file.unlink
        return render json: { error: 'No field tags found in PDF' }, status: :unprocessable_entity
      end

      template_name = params[:name] || params[:documents]&.first&.dig(:name) || 'PDF Template'

      template = Template.create_from_pdf_tags(
        account:     current_account,
        author:      current_user,
        name:        template_name,
        pdf_blob:    pdf_content,
        parsed_data: parsed_data
      )

      temp_file.close
      temp_file.unlink

      # Support flat body style (submitter_email at top level) for from_pdf too
      normalize_flat_submitter_params! if params[:submitter_email].present? && params[:submitters].blank?

      if params[:submitters].present?
        params[:template_id] = template.id
        params[:send_email]  = true unless params.key?(:send_email)
        params[:send_sms]    = false unless params.key?(:send_sms)

        submissions = create_submissions(template, params)

        submissions.each do |submission|
          submission.submitters.each do |submitter|
            assign_submitter_preferences(submitter, params)
            Submitters::MaybeUpdateDefaultValues.call(submitter, current_user, fill_now: true)
          end
        end

        WebhookUrls.enqueue_events(submissions, 'submission.created')
        Submissions.send_signature_requests(submissions)
        SearchEntries.enqueue_reindex(submissions)

        render json: {
          template_id:   template.id,
          template_name: template.name,
          submissions:   build_create_json(submissions)
        }
      else
        render json: {
          template_id:   template.id,
          template_name: template.name,
          fields_count:  parsed_data[:fields].size,
          submitters:    parsed_data[:submitters].map { |s| s[:name] }
        }
      end

    rescue PdfFieldParser::ParseError => e
      Rollbar.warning(e) if defined?(Rollbar)
      Rails.logger.error("PDF Parser Error: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      temp_file&.close
      temp_file&.unlink
      render json: { error: e.message }, status: :unprocessable_entity

    rescue StandardError => e
      Rollbar.error(e) if defined?(Rollbar)
      Rails.logger.error("PDF Processing Error: #{e.class} - #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      temp_file&.close
      temp_file&.unlink
      render json: { error: "Failed to process PDF: #{e.message}" }, status: :internal_server_error
    end

    # -------------------------------------------------------------------------
    private
    # -------------------------------------------------------------------------

    # Converts flat top-level submitter params into the standard nested
    # submitters array so all downstream logic works unchanged.
    #
    # Flat keys supported (mirrors custom_submissions style):
    #   submitter_email, submitter_role, submitter_name,
    #   name, phone, external_id, application_key, metadata
    def normalize_flat_submitter_params!
      submitter_hash = {
        'email'           => params[:submitter_email],
        'name'            => params[:submitter_name].presence || params[:name].presence,
        'role'            => params[:submitter_role].presence,
        'phone'           => params[:phone].presence,
        'external_id'     => params[:external_id].presence,
        'application_key' => params[:application_key].presence,
        'metadata'        => params[:metadata].present? ? params[:metadata].to_unsafe_h : {}
      }.compact

      params.merge!(submitters: [submitter_hash])
    end

    def assign_submitter_preferences(submitter, params)
      submitter_attrs = find_submitter_params_for(submitter, params)

      return if submitter_attrs.nil?

      submitter.preferences ||= {}

      if submitter_attrs[:values].present?
        values_hash = submitter_attrs[:values].respond_to?(:to_unsafe_h) ? submitter_attrs[:values].to_unsafe_h : submitter_attrs[:values].to_h

        submitter.preferences['default_values'] = values_hash

        submitter.save!
        submitter.reload
      end
    end

    def find_submitter_params_for(submitter, params)
      submitters_array = if params[:submitters].present?
        params[:submitters]
      elsif params[:submission].present?
        Array.wrap(params[:submission][:submitters] || params[:submission])
      elsif params[:submissions].present?
        Array.wrap(params[:submissions]).flat_map { |s| s[:submitters] || [s] }
      else
        []
      end

      submitters_array.find { |s| s[:email] == submitter.email }
    end

    def filter_submissions(submissions, params)
      submissions = submissions.where(template_id: params[:template_id]) if params[:template_id].present?
      submissions = submissions.where(slug: params[:slug]) if params[:slug].present?

      if params[:template_folder].present?
        folders =
          TemplateFolders.filter_by_full_name(TemplateFolder.accessible_by(current_ability), params[:template_folder])

        submissions = submissions.joins(:template).where(template: { folder_id: folders.pluck(:id) })
      end

      if params.key?(:archived)
        submissions = params[:archived].in?(['true', true]) ? submissions.archived : submissions.active
      end

      Submissions::Filter.call(submissions, current_user, params)
    end

    def build_create_json(submissions)
      json = submissions.flat_map do |submission|
        submission.submitters.map do |s|
          Submitters::SerializeForApi.call(s, with_documents: false, with_urls: true, params:)
        end
      end

      if request.path.ends_with?('/init')
        json =
          if submissions.size == 1
            {
              id:         submissions.first.id,
              submitters: json,
              expire_at:  submissions.first.expire_at,
              created_at: submissions.first.created_at
            }
          else
            { submitters: json }
          end
      end

      json
    end

    def build_create_and_complete_json(submissions)
      expires_at = Accounts.link_expires_at(current_account)

      json = submissions.flat_map do |submission|
        submission.submitters.map do |submitter|
          serialized = Submitters::SerializeForApi.call(
            submitter,
            with_documents: true,
            with_urls:      true,
            expires_at:     expires_at,
            params:         params
          )

          document_urls = submitter.documents_attachments.map do |attachment|
            {
              filename: attachment.filename.to_s,
              url:      Rails.application.routes.url_helpers.rails_blob_url(
                          attachment,
                          host:       request.base_url,
                          expires_in: expires_at
                        )
            }
          end

          combined_url = if submission.combined_document_attachment.present?
            Rails.application.routes.url_helpers.rails_blob_url(
              submission.combined_document_attachment,
              host:       request.base_url,
              expires_in: expires_at
            )
          end

          audit_url = if submission.audit_trail_attachment.present?
            Rails.application.routes.url_helpers.rails_blob_url(
              submission.audit_trail_attachment,
              host:       request.base_url,
              expires_in: expires_at
            )
          end

          serialized.merge({
            documents:             document_urls,
            combined_document_url: combined_url,
            audit_trail_url:       audit_url,
            status:                'completed'
          }).compact
        end
      end

      if submissions.size == 1
        {
          id:           submissions.first.id,
          slug:         submissions.first.slug,
          submitters:   json,
          expire_at:    submissions.first.expire_at,
          created_at:   submissions.first.created_at,
          completed_at: submissions.first.submitters.first&.completed_at
        }
      else
        { submissions: json }
      end
    end

    def create_submissions(template, params)
      is_send_email = !params[:send_email].in?(['false', false])

      if (emails = (params[:emails] || params[:email]).presence) &&
         (params[:submission].blank? && params[:submitters].blank?)
        Submissions.create_from_emails(template:,
                                       user:         current_user,
                                       source:       :api,
                                       mark_as_sent: is_send_email,
                                       emails:,
                                       params:)
      else
        normalized_params = submissions_params(params)
        submissions_attrs, attachments =
          Submissions::NormalizeParamUtils.normalize_submissions_params!(normalized_params, template)

        submissions = Submissions.create_from_submitters(
          template:,
          user:             current_user,
          source:           :api,
          submitters_order: params[:submitters_order] || params[:order] || 'preserved',
          submissions_attrs:,
          params:
        )

        submitters = submissions.flat_map(&:submitters)

        Submissions::NormalizeParamUtils.save_default_value_attachments!(attachments, submitters)

        submissions
      end
    end

    def submissions_params(p = params)
      permitted_attrs = [
        :send_email, :send_sms, :bcc_completed, :completed_redirect_url, :reply_to, :go_to_last,
        :require_phone_2fa, :expire_at, :name,
        {
          variables: {},
          message:   %i[subject body],
          submitters: [:send_email, :send_sms, :completed_redirect_url, :uuid, :name, :email, :role,
                       :completed, :phone, :application_key, :external_id, :reply_to, :go_to_last,
                       :require_phone_2fa, :order,
                       { metadata: {}, values: {}, roles: [], readonly_fields: [], message: %i[subject body],
                         fields: [:name, :uuid, :default_value, :value, :title, :description,
                                  :readonly, :required, :validation_pattern, :invalid_message,
                                  { default_value: [], value: [], preferences: {}, validation: {} }] }]
        }
      ]

      if p.key?(:submitters)
        p.permit(*permitted_attrs)
      else
        key = p.key?(:submission) ? :submission : :submissions

        p.permit(
          { key => [permitted_attrs] }, { key => permitted_attrs }
        ).fetch(key, [])
      end
    end
  end
end
