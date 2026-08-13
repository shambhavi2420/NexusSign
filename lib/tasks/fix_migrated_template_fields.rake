# frozen_string_literal: true

# Fixes existing migrated templates where custom fields ended up as type 'text'
# instead of their correct custom type (signerfullname, candidatepermanentcity, etc.)
#
# This happened because FindAcroFields didn't recognize field names like
# "Signer Full Name" as custom types — it just saw a /Tx field and set type='text'.
# The auto-fill logic (MaybeUpdateDefaultValues) matches on field TYPE, not name,
# so those fields never got filled from the API values.
#
# Usage on EC2:
#   cd /path/to/app
#   bundle exec rake templates:fix_custom_fields                 # dry run
#   bundle exec rake templates:fix_custom_fields[apply]          # apply to all
#   bundle exec rake templates:fix_custom_fields[apply,123]      # fix template #123 only

namespace :templates do
  desc 'Fix migrated template custom fields: remap text fields to correct custom types so auto-fill works'
  task :fix_custom_fields, [:mode, :template_id] => :environment do |_t, args|
    mode = args[:mode] || 'dry_run'
    template_id = args[:template_id]
    dry_run = mode != 'apply'

    # Field name (downcased, stripped) → correct custom type
    # Must match what MaybeUpdateDefaultValues::CANDIDATE_FIELD_MAPPINGS expects.
    NAME_TO_TYPE = {
      'signer full name'               => 'signerfullname',
      'signer first name'              => 'signerfirstname',
      'signer last name'               => 'signerlastname',
      'signer primary phone'           => 'signerprimaryphone',
      'signer email'                   => 'signeremail',
      'candidate permanent address 1'  => 'candidatepermanentaddress1',
      'candidate permanent city'       => 'candidatepermanentcity',
      'candidate permanent state'      => 'candidatepermanentstate',
      'candidate permanent zip'        => 'candidatepermanentzip',
      'candidate ssn'                  => 'candidatessn',
      'candidate primary profession'   => 'candidateprimaryprofession',
      'candidate primary specialty'    => 'candidateprimaryspecialty',
      'candidate available from'       => 'candidateavailablefrom',
      'candidate available from date'  => 'candidateavailablefromdate',
      'candidate profession'           => 'candidateprofession',
      'candidate specialty'            => 'candidatespecialty',
      'candidate address'              => 'candidateaddress',
      'candidate city'                 => 'candidatecity',
      'candidate state'                => 'candidatestate',
      'candidate zipcode'              => 'candidatezip',
      'signature date'                 => 'signaturedate',
      'current date'                   => 'currentdate',
      'job id'                         => 'jobid',
      'date with month name'           => 'datewithmonthname',
      'date of month'                  => 'dateofmonth',
      'month'                          => 'month',
      'year'                           => 'year',
      'recruiter'                      => 'recruiter',
      'recruiter phone'                => 'recruiterphone',
      'recruiter email'                => 'recruiteremail',
      'start date'                     => 'startdate',
      'end date'                       => 'enddate',
      'client name'                    => 'clientname',
      'recruiter title'                => 'recruitertitle',
      'sales representative'           => 'salesrepresentative',
      'work authorization'             => 'workauthorization'
    }.freeze

    puts "=" * 60
    puts dry_run ? "DRY RUN — showing what would change (no DB writes)" : "APPLYING CHANGES TO DATABASE"
    puts "=" * 60
    puts ""

    templates = template_id ? Template.where(id: template_id) : Template.all
    fixed_templates = 0
    retyped_fields = 0

    templates.find_each do |template|
      next if template.fields.blank?

      changes = []

      template.fields.each do |field|
        next unless field['type'] == 'text'

        # Match by exact name or name without trailing number suffix
        field_name = field['name'].to_s.strip.downcase
        correct_type = NAME_TO_TYPE[field_name] || NAME_TO_TYPE[field_name.sub(/\s+\d+\z/, '')]
        next unless correct_type

        changes << { uuid: field['uuid'], name: field['name'], to: correct_type }
        field['type'] = correct_type unless dry_run
      end

      next if changes.empty?

      fixed_templates += 1
      puts "Template ##{template.id} — #{template.name}"

      changes.each do |c|
        retyped_fields += 1
        puts "  RETYPE: '#{c[:name]}' text → #{c[:to]}"
      end

      template.save! unless dry_run
    end

    puts ""
    puts "=" * 60
    puts "Results:"
    puts "  Templates affected: #{fixed_templates}"
    puts "  Fields retyped:     #{retyped_fields}"
    puts ""
    if dry_run
      puts "This was a DRY RUN. To apply changes:"
      puts "  bundle exec rake templates:fix_custom_fields[apply]"
    else
      puts "All changes applied successfully."
    end
    puts "=" * 60
  end
end
