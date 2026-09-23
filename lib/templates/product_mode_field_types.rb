# frozen_string_literal: true

module Templates
  # Server-side enforcement of the productized (Standard) mode field rules:
  #   * Candidate healthcare field types are not created — they become plain text.
  #   * Signer name fields (full/first/last name) become plain text (no auto-fill).
  # In Healthcare mode nothing changes (no regression).
  # See .kiro/specs/standard-productized-mode (Requirements 6 and 7).
  module ProductModeFieldTypes
    module_function

    # Candidate healthcare-specific field types (Requirement 6).
    CANDIDATE_TYPES = %w[
      candidatepermanentaddress1 candidatepermanentcity candidatepermanentstate
      candidatepermanentzip candidatessn candidateprimaryprofession
      candidateprimaryspecialty candidateavailablefrom candidateavailablefromdate
      candidateprofession candidatespecialty candidateaddress candidatecity
      candidatestate candidatezip
    ].freeze

    # Signer fields that should become plain text boxes / be hidden in Standard
    # Mode (Requirement 7). Includes name fields plus email and primary phone.
    SIGNER_NAME_TYPES = %w[
      signerfullname signerfirstname signerlastname signeremail signerprimaryphone
    ].freeze

    # Types rewritten to 'text' when Standard Mode is active.
    STANDARDIZED_TYPES = (CANDIDATE_TYPES + SIGNER_NAME_TYPES).freeze

    # Returns the effective field type for the given company's product mode.
    def normalize_type(type, account = nil)
      return type unless Docuseal.standard_mode?(account)

      STANDARDIZED_TYPES.include?(type.to_s) ? 'text' : type
    end

    # Rewrites a field hash's type to text when required, clearing candidate/
    # signer-specific preferences (e.g. the SSN mask) so a downgraded field
    # behaves like a normal text box. Works with symbol- or string-keyed hashes.
    def normalize_field(field, account = nil)
      return field unless Docuseal.standard_mode?(account)
      return field if field.nil?

      type_key = field.key?(:type) ? :type : ('type' if field.key?('type'))
      return field unless type_key

      current_type = field[type_key].to_s
      return field unless STANDARDIZED_TYPES.include?(current_type)

      field = field.dup
      field[type_key] = 'text'

      # Drop the SSN mask (and any candidate preference) so the plain text box
      # has no leftover healthcare-specific formatting.
      pref_key = field.key?(:preferences) ? :preferences : ('preferences' if field.key?('preferences'))
      if pref_key && field[pref_key].is_a?(Hash)
        field[pref_key] = field[pref_key].except('mask', :mask)
      end

      field
    end

    # Applies normalize_field across an array of field hashes for the company.
    def normalize_fields(fields, account = nil)
      return fields unless Docuseal.standard_mode?(account)

      Array(fields).map { |f| normalize_field(f, account) }
    end
  end
end
