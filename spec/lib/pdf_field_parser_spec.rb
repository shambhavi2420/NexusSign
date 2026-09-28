# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PdfFieldParser do
  describe '.parse_dollar_tag' do
    it 'maps ${Signature} to a signature field' do
      field = described_class.parse_dollar_tag('Signature')

      expect(field[:type]).to eq('signature')
      expect(field[:name]).to eq('Signature')
    end

    it 'maps ${Initials} to an initials field' do
      field = described_class.parse_dollar_tag('Initials')

      expect(field[:type]).to eq('initials')
      expect(field[:name]).to eq('Initials')
    end

    it 'maps ${SignatureDate} to a date field' do
      field = described_class.parse_dollar_tag('SignatureDate')

      expect(field[:type]).to eq('date')
    end

    it 'maps ${CandidateFullName} to the signer full name field' do
      field = described_class.parse_dollar_tag('CandidateFullName')

      expect(field[:type]).to eq('signerfullname')
      expect(field[:name]).to eq('Signer Full Name')
    end

    it 'maps ${CandidateFirstName} and ${CandidateLastName} to signer name fields' do
      first = described_class.parse_dollar_tag('CandidateFirstName')
      last  = described_class.parse_dollar_tag('CandidateLastName')

      expect(first[:type]).to eq('signerfirstname')
      expect(last[:type]).to eq('signerlastname')
    end

    it 'masks the candidate SSN field' do
      field = described_class.parse_dollar_tag('CandidateSSN')

      expect(field[:type]).to eq('candidatessn')
      expect(field[:preferences]).to eq('mask' => true)
    end

    it 'is case- and separator-insensitive' do
      %w[signature SIGNATURE Signature].each do |variant|
        expect(described_class.parse_dollar_tag(variant)[:type]).to eq('signature')
      end

      expect(described_class.parse_dollar_tag('signature_date')[:type]).to eq('date')
      expect(described_class.parse_dollar_tag('Signature Date')[:type]).to eq('date')
    end

    it 'falls back to a humanized custom text field for unknown tags' do
      field = described_class.parse_dollar_tag('CandidatePreferredLocation')

      expect(field[:type]).to eq('text')
      expect(field[:name]).to eq('Candidate Preferred Location')
    end

    it 'humanizes snake_case custom tags' do
      field = described_class.parse_dollar_tag('employer_reference_note')

      expect(field[:type]).to eq('text')
      expect(field[:name]).to eq('Employer Reference Note')
    end

    it 'supports an optional role suffix' do
      field = described_class.parse_dollar_tag('Signature;role=Signer 2')

      expect(field[:type]).to eq('signature')
      expect(field[:role]).to eq('Signer 2')
    end

    it 'produces a field with a normalized area within 0..1' do
      field = described_class.parse_dollar_tag('CandidateFullName')
      area  = field[:areas].first

      expect(area[:x]).to be_between(0, 1)
      expect(area[:y]).to be_between(0, 1)
      expect(area[:w]).to be_between(0, 1)
      expect(area[:h]).to be_between(0, 1)
      expect(area[:page]).to eq(0)
    end

    it 'defaults required to true and readonly to false' do
      field = described_class.parse_dollar_tag('CandidateFullName')

      expect(field[:required]).to be(true)
      expect(field[:readonly]).to be(false)
    end
  end

  describe '.call end-to-end with a generated PDF' do
    # Builds a one-page PDF containing the given lines of text and returns its path.
    def build_pdf(lines)
      require 'hexapdf'

      doc = HexaPDF::Document.new
      canvas = doc.pages.add.canvas
      canvas.font('Helvetica', size: 12)
      y = 720
      lines.each do |line|
        canvas.text(line, at: [72, y])
        y -= 40
      end

      file = Tempfile.new(['dollar_tags', '.pdf'])
      file.binmode
      doc.write(file.path)
      file
    end

    it 'detects all ${...} tags from a real PDF and maps them correctly' do
      file = build_pdf([
                         '${CandidateFirstName}',
                         '${CandidateLastName}',
                         '${Signature}',
                         '${Initials}',
                         '${SignatureDate}',
                         '${CandidateFullName}'
                       ])

      result = described_class.call(file.path)

      types = result[:fields].map { |f| f[:type] }

      expect(result[:fields].size).to eq(6)
      expect(types).to contain_exactly(
        'signerfirstname', 'signerlastname', 'signature',
        'initials', 'date', 'signerfullname'
      )
      # Every detected tag is also queued for removal from the clean PDF.
      expect(result[:tag_positions].size).to eq(6)
    ensure
      file&.close
      file&.unlink
    end

    it 'detects ${...}, {{...}} and [[...]] tags in the same document' do
      file = build_pdf([
                         '${CandidateFullName}',
                         '{{Employer Name;type=text;role=HR}}',
                         '[[SFLD:FullSSN:W=120,H=15,R=True]]'
                       ])

      result = described_class.call(file.path)
      types = result[:fields].map { |f| f[:type] }

      expect(types).to include('signerfullname') # ${...}
      expect(types).to include('text')           # {{...}}
      expect(types).to include('candidatessn')   # [[...]]
    ensure
      file&.close
      file&.unlink
    end
  end
end
