# frozen_string_literal: true

module Submitters
  module MaybeUpdateDefaultValues
    module_function

    # Field name mappings for candidate fields
    CANDIDATE_FIELD_MAPPINGS = {
      'candidatepermanentaddress1' => 'Candidate Permanent Address 1',
      'candidatepermanentcity' => 'Candidate Permanent City',
      'candidatepermanentstate' => 'Candidate Permanent State',
      'candidatepermanentzip' => 'Candidate Permanent Zip',
      'signaturedate' => 'Signature Date',
      'currentdate' => 'Current Date',
      'jobid' => 'Job ID',
      'datewithmonthname' => 'Date With Month Name',
      'dateofmonth' => 'Date Of Month',
      'month' => 'Month',
      'year' => 'Year',
      'recruiter' => 'Recruiter',
      'recruiterphone' => 'Recruiter Phone',
      'recruiteremail' => 'Recruiter Email',
      'startdate' => 'Start Date',
      'enddate' => 'End Date',
      'clientname' => 'Client Name',
      'recruitertitle' => 'Recruiter Title',
      'additionalinformationforexhibitandrider' => 'Additional Information For Exhibit And Rider',
      'salesrepresentative' => 'Sales Representative',
      'workauthorization' => 'Work Authorization',
      'signeremail' => 'Signer Email',
      'signerfirstname' => 'Signer First Name',
      'signerlastname' => 'Signer Last Name',
      'candidateprofession' => 'Candidate Profession',
      'candidateprimaryprofession' => 'Candidate Primary Profession',
      'candidatespecialty' => 'Candidate Specialty',
      'candidateprimaryspecialty' => 'Candidate Primary Specialty',
      'signerfullname' => 'Signer Full Name',
      'candidateaddress' => 'Candidate Address',
      'candidatecity' => 'Candidate City',
      'candidatestate' => 'Candidate State',
      'candidatezip' => 'Candidate Zipcode',
      'candidatessn' => 'Candidate SSN',
      'candidateavailablefrom' => 'Candidate Available From',
      'candidateavailablefromdate' => 'Candidate Available From Date',
      'signerprimaryphone' => 'Signer Primary Phone'
    }.freeze

    # API key aliases - maps API PascalCase keys to field types
    API_KEY_ALIASES = {
      'CandidateAddress'           => 'candidatepermanentaddress1',
      'CandidateCity'              => 'candidatepermanentcity',
      'CandidateState'             => 'candidatepermanentstate',
      'CandidateZip'               => 'candidatepermanentzip',
      'CandidateAvailableFrom'     => 'candidateavailablefrom',
      'CandidateSSN'               => 'candidatessn',
      'CandidatePrimaryProfession' => 'candidateprimaryprofession',
      'CandidatePrimarySpecialty'  => 'candidateprimaryspecialty',
      'SignerFullName'             => 'signerfullname',
      'SignerFirstName'            => 'signerfirstname',
      'SignerLastName'             => 'signerlastname',
      'SignerEmail'                => 'signeremail',
      'SignerPrimaryPhone'         => 'signerprimaryphone'
    }.freeze

    # Date field types that need format normalization
    DATE_FIELD_TYPES = %w[
      candidateavailablefrom
      candidateavailablefromdate
      startdate
      enddate
      signaturedate
      currentdate
    ].freeze

    def call(submitter, current_user, fill_now: false)
      puts "\n" + "="*50
      puts "DEBUG MaybeUpdateDefaultValues"
      puts "="*50
      puts "Submitter ID: #{submitter.id}"
      puts "Submitter UUID: #{submitter.uuid}"
      puts "Submitter Email: #{submitter.email}"
      puts "fill_now parameter: #{fill_now}"
      puts "Current submitter.values: #{submitter.values.inspect}"
      puts "Current submitter.preferences: #{submitter.preferences.inspect}"
      puts "Current user: #{current_user&.email}"

      user =
        if current_user && current_user.email == submitter.email
          current_user
        else
          submitter.account.users.find_by(email: submitter.email)
        end

      puts "Found user: #{user&.email || 'nil'}"

      fields = submitter.submission.template_fields || submitter.submission.template.fields
      puts "\nTemplate has #{fields.length} fields"

      values_updated = false

      fields.each do |field|
        next if field['submitter_uuid'] != submitter.uuid

        puts "\n--- Processing field ---"
        puts "Field: #{field.slice('name', 'type', 'uuid').inspect}"
        puts "Current value for #{field['uuid']}: #{submitter.values[field['uuid']].inspect}"

        if submitter.values[field['uuid']].present? && !fill_now
          puts "✗ Skipping - value already present and fill_now=false"
          next
        end

        default_value = get_default_value_for_field(field, user, submitter)
        puts "Default value result: #{default_value.inspect}"

        if default_value.present?
          puts "✓ Setting submitter.values[#{field['uuid']}] = #{default_value}"
          submitter.values[field['uuid']] = default_value
          values_updated = true
        else
          puts "✗ No default value to set"
        end
      end

      puts "\n--- FINAL RESULTS ---"
      puts "Final submitter.values: #{submitter.values.inspect}"
      puts "Values updated: #{values_updated}"
      puts "="*50 + "\n"

      if values_updated
        submitter.save!
        submitter.reload
      end

      submitter
    end

    def get_default_value_for_field(field, user, submitter)
      field_name = field['name'].to_s.downcase
      field_type = field['type']
      field_uuid = field['uuid']

      puts "    → field_name: '#{field_name}'"
      puts "    → field_type: '#{field_type}'"
      puts "    → field_uuid: '#{field_uuid}'"

      if CANDIDATE_FIELD_MAPPINGS.key?(field_type)
        puts "    → CANDIDATE FIELD DETECTED: #{field_type}"
        return get_candidate_field_value(field, field_type, submitter)
      end

      if field_name.include?('profession') || field_type == 'profession'
        puts "    → PROFESSION FIELD DETECTED"
        return get_candidate_field_value(field, 'profession', submitter)
      end

      case
      when field_name.in?(['full name', 'legal name'])
        user&.full_name
      when field_name == 'first name'
        user&.first_name
      when field_name == 'last name'
        user&.last_name
      when field_type == 'initials' && user && (initials = UserConfigs.load_initials(user))
        attachment = ActiveStorage::Attachment.find_or_create_by!(
          blob_id: initials.blob_id,
          name: 'attachments',
          record: submitter
        )
        attachment.uuid
      else
        field['default_value']
      end
    end

    def get_candidate_field_value(field, field_type, submitter)
      default_values = submitter.preferences['default_values'] || {}

      # Translate all PascalCase API keys → lowercase field type keys
      resolved_default_values = default_values.transform_keys do |k|
        API_KEY_ALIASES[k] || k.downcase.gsub(/[\s_-]/, '')
      end

      field_type_clean = field_type.to_s.strip.downcase

      puts "    → DEBUG field_type_clean: '#{field_type_clean}'"
      puts "    → DEBUG resolved keys: #{resolved_default_values.keys.inspect}"

      value = resolved_default_values[field_type_clean]


      value ||= field['default_value']

      puts "    → FINAL value for '#{field_type_clean}': #{value.inspect}"
      value
    end

    def normalize_date(value)
      return value if value.blank?

      # Already YYYY-MM-DD, return as-is
      return value if value.match?(/^\d{4}-\d{2}-\d{2}$/)

      # MM/DD/YYYY or MM-DD-YYYY → YYYY-MM-DD
      if value.match?(/^(\d{2})[-\/](\d{2})[-\/](\d{4})$/)
        parts = value.scan(/\d+/)
        return "#{parts[2]}-#{parts[0]}-#{parts[1]}"
      end

      value
    end

  end
end
