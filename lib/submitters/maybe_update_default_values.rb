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
      'candidateemail' => 'Candidate Email',
      'candidatefirstname' => 'Candidate First Name',
      'candidatelastname' => 'Candidate Last Name',
      'candidateprofession' => 'Candidate Profession',
      'candidateprimaryprofession' => 'Candidate Primary Profession',
      'candidatespecialty' => 'Candidate Specialty',
      'candidateprimaryspecialty' => 'Candidate Primary Specialty',
      'candidatefullname' => 'Candidate Full Name',
      'candidateaddress' => 'Candidate Address',
      'candidatecity' => 'Candidate City',
      'candidatestate' => 'Candidate State',
      'candidatezip' => 'Candidate Zipcode',
      'candidatessn' => 'Candidate SSN',
      'candidateavailablefrom' => 'Candidate Available From',
      'candidateavailablefromdate' => 'Candidate Available From Date',
      'candidateprimaryphone' => 'Candidate Primary Phone'
    }.freeze

    # API key aliases - maps API PascalCase keys to field types
    API_KEY_ALIASES = {
      'CandidateAddress' => 'candidatepermanentaddress1',
      'CandidateCity' => 'candidatepermanentcity',
      'CandidateState' => 'candidatepermanentstate',
      'CandidateZip' => 'candidatepermanentzip',
      'CandidateAvailableFrom' => 'candidateavailablefrom'
    }.freeze

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

      # Track if any values were updated
      values_updated = false

      fields.each do |field|
        next if field['submitter_uuid'] != submitter.uuid

        puts "\n--- Processing field ---"
        puts "Field: #{field.slice('name', 'type', 'uuid').inspect}"
        puts "Current value for #{field['uuid']}: #{submitter.values[field['uuid']].inspect}"

        # Skip if value already exists and we're not force-filling
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

      # Only save if values were actually updated
      if values_updated
        submitter.save!
        # Reload to ensure fresh data
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

      # Check if this is a candidate field type
      if CANDIDATE_FIELD_MAPPINGS.key?(field_type)
        puts "    → CANDIDATE FIELD DETECTED: #{field_type}"
        return get_candidate_field_value(field, field_type, submitter)
      end

      # Legacy handling for profession field name/type
      if field_name.include?('profession') || field_type == 'profession'
        puts "    → PROFESSION FIELD DETECTED"
        return get_candidate_field_value(field, 'profession', submitter)
      end

      # Handle other standard field types
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
        # Check if field has a default_value defined
        field['default_value']
      end
    end

    def get_candidate_field_value(field, field_type, submitter)
      # Get the display name for this field type
      display_name = CANDIDATE_FIELD_MAPPINGS[field_type] || field['name']

      puts "    → Looking for candidate field value"
      puts "       - Field type: #{field_type}"
      puts "       - Display name: #{display_name}"

      # Priority order for candidate field values:
      # 1. Check preferences default_values by field type (e.g., 'candidatefirstname')
      # 2. Check preferences default_values by display name (e.g., 'Candidate First Name')
      # 3. Check preferences default_values by PascalCase (e.g., 'CandidateFirstName')
      # 4. Check preferences default_values by exact field name from template
      # 5. Check preferences default_values with case-insensitive search
      # 6. Check field default_value from template

      default_values = submitter.preferences['default_values'] || {}

      # Try exact matches first
      value = default_values[field_type] ||
              default_values[display_name] ||
              default_values[field['name']]

      # If no exact match, try PascalCase version (e.g., CandidateFirstName)
      if value.nil? && display_name
        pascal_case_key = display_name.gsub(/\s+/, '')
        value = default_values[pascal_case_key]
        puts "       - default_values['#{pascal_case_key}'] (PascalCase): #{value.inspect}"
      end

      # Try API key aliases (e.g., CandidateAddress → candidatepermanentaddress1)
      if value.nil?
        API_KEY_ALIASES.each do |api_key, field_type_alias|
          if field_type == field_type_alias && default_values.key?(api_key)
            value = default_values[api_key]
            puts "       - default_values['#{api_key}'] (API alias): #{value.inspect}"
            break
          end
        end
      end

      # If still no match, try case-insensitive search
      if value.nil? && display_name
        match_key = default_values.keys.find do |k|
          k.to_s.downcase.gsub(/[\s_-]/, '') == display_name.downcase.gsub(/[\s_-]/, '')
        end
        value = default_values[match_key] if match_key
        puts "       - default_values['#{match_key}'] (case-insensitive): #{value.inspect}" if match_key
      end

      # Fallback to field's default_value
      value ||= field['default_value']

      puts "    → Candidate field sources checked:"
      puts "       - default_values['#{field_type}']: #{default_values[field_type].inspect}"
      puts "       - default_values['#{display_name}']: #{default_values[display_name].inspect}"
      puts "       - default_values['#{field['name']}']: #{default_values[field['name']].inspect}"
      puts "       - field['default_value']: #{field['default_value'].inspect}"
      puts "    → Final value: #{value.inspect}"

      value
    end
  end
end
