# frozen_string_literal: true

class StartFormController < ApplicationController
  layout 'form'

  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale, only: %i[show update completed]
  before_action :maybe_redirect_com, only: %i[show completed]
  before_action :load_resubmit_submitter, only: :update
  before_action :load_template
  before_action :authorize_start!, only: :update

  COOKIES_TTL = 12.hours
  COOKIES_DEFAULTS = { httponly: true, secure: Rails.env.production? }.freeze

  def show
    raise ActionController::RoutingError, I18n.t('not_found') if @template.preferences['require_phone_2fa']

    if @template.shared_link?
      @submitter = @template.submissions.new(account_id: @template.account_id)
                            .submitters.new(account_id: @template.account_id,
                                            uuid: (filter_undefined_submitters(@template).first ||
                                                  @template.submitters.first)['uuid'])
      render :email_verification if params[:email_verification]
    else
      Rollbar.warning("Not shared template: #{@template.id}") if defined?(Rollbar)

      return render :private if current_user && current_ability.can?(:read, @template)

      raise ActionController::RoutingError, I18n.t('not_found')
    end
  end

  def update
    @submitter = find_or_initialize_submitter(@template, submitter_params)

    if @submitter.completed_at?
      redirect_to start_form_completed_path(@template.slug, submitter_params.compact_blank)
    else
      if filter_undefined_submitters(@template).size > 1 && @submitter.new_record?
        @error_message = multiple_submitters_error_message

        return render :show, status: :unprocessable_content
      end

      if (is_new_record = @submitter.new_record?)
        assign_submission_attributes(@submitter, @template)

        Submissions::AssignDefinedSubmitters.call(@submitter.submission)
      else
        @submitter.assign_attributes(ip: request.remote_ip, ua: request.user_agent)
      end

      if @template.preferences['shared_link_2fa'] == true
        handle_require_2fa(@submitter, is_new_record:)
      elsif @submitter.errors.blank? && @submitter.save
        enqueue_new_submitter_jobs(@submitter) if is_new_record

        redirect_to submit_form_path(@submitter.slug)
      else
        render :show, status: :unprocessable_content
      end
    end
  end

  def completed
    return redirect_to start_form_path(@template.slug) if !@template.shared_link? || @template.archived_at?

    submitter_params = params.permit(:name, :email, :phone).tap do |attrs|
      attrs[:email] = Submissions.normalize_email(attrs[:email])
    end

    required_fields = @template.preferences.fetch('link_form_fields', ['email'])

    required_params = required_fields.index_with { |key| submitter_params[key] }

    raise ActionController::RoutingError, I18n.t('not_found') if required_params.any? { |_, v| v.blank? } ||
                                                                 required_params.except('name').compact_blank.blank?

    @submitter = Submitter.where(submission: @template.submissions)
                          .where.not(completed_at: nil)
                          .find_by!(required_params)
  end

  private

  def enqueue_new_submitter_jobs(submitter)
    WebhookUrls.enqueue_events(submitter.submission, 'submission.created')

    SearchEntries.enqueue_reindex(submitter)

    return unless submitter.submission.expire_at?

    ProcessSubmissionExpiredJob.perform_at(submitter.submission.expire_at, 'submission_id' => submitter.submission_id)
  end

  def load_resubmit_submitter
    @resubmit_submitter =
      if params[:resubmit].present? && !params[:resubmit].in?([true, 'true'])
        Submitter.find_by(slug: params[:resubmit])
      end
  end

  def authorize_start!
    return redirect_to start_form_path(@template.slug) if @template.archived_at?

    return if @resubmit_submitter
    return if @template.shared_link? || (current_user && current_ability.can?(:read, @template))

    Rollbar.warning("Not shared template: #{@template.id}") if defined?(Rollbar)

    redirect_to start_form_path(@template.slug)
  end

  def find_or_initialize_submitter(template, submitter_params)
    required_fields = template.preferences.fetch('link_form_fields', ['email'])

    required_params = required_fields.index_with { |key| submitter_params[key] }

    find_params = required_params.except('name')

    submitter = Submitter.new if find_params.compact_blank.blank?

    submitter ||=
      Submitter
      .where(submission: template.submissions.where(expire_at: Time.current..)
                                 .or(template.submissions.where(expire_at: nil)).where(archived_at: nil))
      .order(id: :desc)
      .where(declined_at: nil)
      .where(external_id: nil)
      .where(template.preferences['shared_link_2fa'] == true ? {} : { ip: [nil, request.remote_ip] })
      .then { |rel| params[:resubmit].present? || params[:selfsign].present? ? rel.where(completed_at: nil) : rel }
      .find_or_initialize_by(find_params)

    submitter.name = required_params['name'] if submitter.new_record?

    unless @resubmit_submitter
      required_params.each do |key, value|
        submitter.errors.add(key.to_sym, :blank) if value.blank?
      end
    end

    submitter
  end

  def assign_submission_attributes(submitter, template)
    submitter.assign_attributes(
      uuid: (filter_undefined_submitters(template).first || @template.submitters.first)['uuid'],
      ip: request.remote_ip,
      ua: request.user_agent,
      values: @resubmit_submitter&.preferences&.fetch('default_values', nil) || {},
      preferences: @resubmit_submitter&.preferences.presence || { 'send_email' => true },
      metadata: @resubmit_submitter&.metadata.presence || {}
    )

    submitter.assign_attributes(@resubmit_submitter.slice(:name, :email, :phone)) if @resubmit_submitter

    if submitter.values.present?
      @resubmit_submitter.attachments.each do |attachment|
        submitter.attachments << attachment.dup if submitter.values.value?(attachment.uuid)
      end
    end

    submitter.submission ||= Submission.new(template:,
                                            account_id: template.account_id,
                                            template_submitters: template.submitters,
                                            expire_at: Templates.build_default_expire_at(template),
                                            submitters: [submitter],
                                            source: :link)

    submitter.account_id = submitter.submission.account_id

    submitter
  end

  def filter_undefined_submitters(template)
    Templates.filter_undefined_submitters(template.submitters)
  end

  def submitter_params
    return { 'email' => current_user.email, 'name' => current_user.full_name } if params[:selfsign]
    return @resubmit_submitter.slice(:name, :phone, :email) if @resubmit_submitter.present?

    params.require(:submitter).permit(:email, :phone, :name).tap do |attrs|
      attrs[:email] = Submissions.normalize_email(attrs[:email])
    end
  end

  def load_template
    @template =
      if @resubmit_submitter
        @resubmit_submitter.template
      else
        Template.find_by!(slug: params[:slug] || params[:start_form_slug])
      end
  end

  def multiple_submitters_error_message
    if current_user&.account_id == @template.account_id
      helpers.t('this_submission_has_multiple_signers_which_prevents_the_use_of_a_sharing_link_html')
    else
      I18n.t('not_found')
    end
  end

  def handle_require_2fa(submitter, is_new_record:)
    return render :show, status: :unprocessable_content if submitter.errors.present?

    is_otp_verified = Submitters.verify_link_otp!(params[:one_time_code], submitter)

    if cookies.encrypted[:email_2fa_slug] == submitter.slug || is_otp_verified
      if submitter.save
        enqueue_new_submitter_jobs(submitter) if is_new_record

        if is_otp_verified
          SubmissionEvents.create_with_tracking_data(submitter, 'email_verified', request)

          cookies.encrypted[:email_2fa_slug] =
            { value: submitter.slug, expires: COOKIES_TTL.from_now, **COOKIES_DEFAULTS }
        end

        redirect_to submit_form_path(submitter.slug)
      else
        render :show, status: :unprocessable_content
      end
    else
      Submitters.send_shared_link_email_verification_code(submitter, request:)

      render :email_verification
    end
  rescue Submitters::UnableToSendCode, Submitters::InvalidOtp => e
    redirect_to start_form_path(submitter.submission.template.slug,
                                params: submitter_params.merge(email_verification: true)),
                alert: e.message
  rescue RateLimit::LimitApproached
    redirect_to start_form_path(submitter.submission.template.slug,
                                params: submitter_params.merge(email_verification: true)),
                alert: I18n.t(:too_many_attempts)
  end
end
