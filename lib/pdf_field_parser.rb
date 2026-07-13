# frozen_string_literal: true

# lib/pdf_field_parser.rb
# Service to parse embedded PDF field tags and extract their actual positions
# with precise text positioning using transformation matrices

require 'pdf-reader'
require 'hexapdf'

class PdfFieldParser
  FIELD_TAG_REGEX = /\{\{([^}]+)\}\}/
  SERTIFI_TAG_REGEX = /\[\[([^\]]+)\]\]/

  # Maps Sertifi tag patterns to NexusSign field types.
  # Order matters - more specific patterns must come before generic ones.
  # Field `type` values reuse the exact same custom candidate/signer field type
  # strings used by the existing {{Tag;role=...;type=...}} API convention, so
  # these fields get autofilled the same way (e.g. via Submitters::MaybeUpdateDefaultValues).
  SERTIFI_TAG_MAPPINGS = {
    # Sertifi action tags
    /\ASertifiDate/i        => { type: 'date', name: 'Date Field 1' },
    /\ASertifiSStamp/i      => { type: 'signature', name: 'Signature' },
    /\ASertifiSignature/i   => { type: 'signature', name: 'Signature' },
    /\ASertifiInitials/i    => { type: 'initials', name: 'Initials' },
    /\ASertifiText/i        => { type: 'text', name: 'Text' },
    /\ASertifiCheckbox/i    => { type: 'checkbox', name: 'Checkbox' },
    # SFLD candidate/signer data fields - matches the field tray types used in
    # app/javascript/template_builder/field_type.vue. Per business rule:
    # FirstName, LastName, FullName, Primary Phone, and Email map to "Signer"
    # fields; all other candidate data (address, city, state, zip, ssn,
    # profession, specialty, availability) maps to "Candidate" fields.
    /\ASFLD:FullName/i          => { type: 'signerfullname', name: 'Signer Full Name' },
    /\ASFLD:LastName/i          => { type: 'signerlastname', name: 'Signer Last Name' },
    /\ASFLD:FirstName/i         => { type: 'signerfirstname', name: 'Signer First Name' },
    /\ASFLD:Email/i             => { type: 'signeremail', name: 'Signer Email' },
    /\ASFLD:PrimaryPhone/i      => { type: 'signerprimaryphone', name: 'Signer Primary Phone' },
    /\ASFLD:Address/i           => { type: 'candidatepermanentaddress1', name: 'Candidate Permanent Address 1' },
    /\ASFLD:City/i              => { type: 'candidatepermanentcity', name: 'Candidate Permanent City' },
    /\ASFLD:State/i             => { type: 'candidatepermanentstate', name: 'Candidate Permanent State' },
    /\ASFLD:ZipCode/i           => { type: 'candidatepermanentzip', name: 'Candidate Permanent Zip' },
    /\ASFLD:FullSSN/i           => { type: 'candidatessn', name: 'Candidate SSN', preferences: { 'mask' => true } },
    /\ASFLD:AvailabilityDate/i  => { type: 'candidateavailablefrom', name: 'Candidate Available From' },
    /\ASFLD:PrimaryProfession/i => { type: 'candidateprimaryprofession', name: 'Candidate Primary Profession' },
    /\ASFLD:PrimarySpecialty/i  => { type: 'candidateprimaryspecialty', name: 'Candidate Primary Specialty' },
    /\ASFLD:Company/i       => { type: 'text', name: 'Company' },
    /\ASFLD:Title/i         => { type: 'text', name: 'Title' },
    /\ASFLD:Name/i          => { type: 'signerfullname', name: 'Signer Full Name' },
    /\ASFLD:/i              => { type: 'text', name: nil } # Generic SFLD fallback
  }.freeze

  # Default dimensions for SFLD fields (in PDF points)
  SFLD_DEFAULT_WIDTH = 100
  SFLD_DEFAULT_HEIGHT = 15

  attr_reader :pdf_path, :parsed_fields, :submitters, :tag_positions

  def initialize(pdf_path)
    @pdf_path = pdf_path
    @parsed_fields = []
    @submitters = {}
    @tag_positions = []
  end

  def self.call(pdf_path)
    new(pdf_path).parse
  end

  # Class-level accessor for parsing Sertifi tag attributes from external callers
  def self.parse_sertifi_attributes(tag_content)
    new('').send(:parse_sertifi_tag_attributes, tag_content)
  end

  def parse
    reader = PDF::Reader.new(pdf_path)

    # Extract tags with positions using text analysis
    reader.pages.each_with_index do |page, page_index|
      extract_tags_from_page(page, page_index)
    end

    {
      fields: @parsed_fields,
      submitters: @submitters.values,
      tag_positions: @tag_positions,
      document_path: @pdf_path
    }
  rescue PDF::Reader::MalformedPDFError => e
    raise ParseError, "Invalid PDF format: #{e.message}"
  rescue StandardError => e
    raise ParseError, "Failed to parse PDF: #{e.message}"
  end

  def self.remove_tags_and_add_fields(input_pdf_path, output_pdf_path, parsed_data)
    doc = HexaPDF::Document.open(input_pdf_path)

    puts "\n=== DEBUG: Removing tags ==="
    puts "Total tag positions: #{parsed_data[:tag_positions].size}"

    parsed_data[:tag_positions].each do |tag_pos|
      page = doc.pages[tag_pos[:page]]
      canvas = page.canvas(type: :overlay)

      puts "  Tag: '#{tag_pos[:text]}' at (#{tag_pos[:x].round(2)}, #{tag_pos[:y].round(2)}) size: #{tag_pos[:width].round(2)}x#{tag_pos[:height].round(2)}"

      # Draw white rectangle over the tag using the working color method
      canvas.save_graphics_state
      
      # Use the same color method that worked for grey, but with white (1, 1, 1)
      canvas.fill_color(1.0, 1.0, 1.0)  # White in RGB (same syntax as 0.5, 0.5, 0.5 grey)
      
      # Add padding for better coverage
      padding = 3
      x = tag_pos[:x] - padding
      y = tag_pos[:y] - padding
      width = tag_pos[:width] + (padding * 2)
      height = tag_pos[:height] + (padding * 2)
      
      canvas.rectangle(x, y, width, height).fill
      canvas.restore_graphics_state
      
      puts "    ✓ Drew white rectangle"
    end

    puts "\n=== Writing output PDF ===\n"
    doc.write(output_pdf_path)
    puts "Done!"
    doc
  end

  private

  # Use PDF::Reader's own PageTextReceiver for text extraction. It correctly
  # decodes text through the font's ToUnicode CMap (including CID/Type0 fonts
  # like embedded Calibri subsets), which our previous hand-rolled receiver did
  # not do - that caused tags rendered with certain embedded fonts to come
  # through as garbled glyph bytes instead of readable "[[SFLD:...]]" text.
  #
  # Runs are gathered at the CHARACTER level (merge: false) and grouped into
  # visual lines by baseline y-coordinate. Tags are then scanned for across
  # each line's full text, and also across line boundaries, because some
  # source documents word-wrap a tag mid-token (e.g. "[[SFLD:State:W=100,H=15,R="
  # on one line and "True]]" on the next).
  def extract_tags_from_page(page, page_index)
    receiver = PDF::Reader::PageTextReceiver.new
    receiver.page = page
    page.walk(receiver)

    page_width = page.width
    page_height = page.height

    chars = receiver.runs(skip_overlapping: false, skip_zero_width: false, merge: false)
    lines = group_chars_into_lines(chars)

    scan_lines_for_tags(lines, page_index, page_width, page_height, FIELD_TAG_REGEX, '{{', '}}') do |tag_content, position|
      field = parse_field_at_position(
        tag_content, page_index, position[:x], position[:y],
        position[:width], position[:height], page_width, page_height
      )

      if field
        @parsed_fields << field
        register_submitter(field[:role]) if field[:role]
      end
    end

    scan_lines_for_tags(lines, page_index, page_width, page_height, SERTIFI_TAG_REGEX, '[[', ']]') do |tag_content, position|
      field = parse_sertifi_field_at_position(
        tag_content, page_index, position[:x], position[:y],
        position[:width], position[:height], page_width, page_height
      )

      if field
        @parsed_fields << field
        register_submitter(field[:role]) if field[:role]
      end
    end
  end

  # Groups individual character TextRuns into visual lines based on rounded
  # baseline y-coordinate, sorted left-to-right within each line, then lines
  # sorted top-to-bottom (descending y, since PDF space has y increasing upward).
  def group_chars_into_lines(chars)
    chars
      .group_by { |c| c.y.round(1) }
      .sort_by { |y, _| -y }
      .map { |y, cs| { y: y, chars: cs.sort_by(&:x) } }
  end

  # Scans each line's concatenated text for the given tag regex.
  #
  # Some source documents word-wrap a tag mid-token (e.g. a narrow text box
  # renders "[[SFLD:State:W=100,H=15,R=" on one line and "True]]" on the next),
  # while OTHER complete, unrelated tags may visually sit on lines in between
  # the two wrapped fragments (e.g. separate "[[SFLD:City:...]]" and
  # "[[SFLD:ZipCode]]" boxes positioned between the wrapped State fragments).
  #
  # To handle this correctly: when a line ends with a dangling unclosed
  # opening delimiter, subsequent lines that are themselves fully balanced
  # (self-contained tags) are processed normally and NOT merged into the
  # pending fragment. Only a line that supplies the missing closing
  # delimiter(s) (more closes than opens) is merged in to complete the tag.
  def scan_lines_for_tags(lines, page_index, _page_width, _page_height, regex, open_delim, close_delim)
    pending = nil

    lines.each do |line|
      text = line[:chars].map(&:text).join
      open_count = text.scan(open_delim).size
      close_count = text.scan(close_delim).size

      if pending
        combined_chars = pending[:chars] + line[:chars]
        combined_text = combined_chars.map(&:text).join

        if combined_text.scan(open_delim).size == combined_text.scan(close_delim).size
          # This line supplies the missing close - finalize the merged tag.
          emit_tags_in_chars(combined_chars, page_index, regex, open_delim, close_delim) { |c, p| yield c, p }
          pending = nil
          next
        elsif open_count == close_count
          # Self-contained line (0 or more complete tags) - process independently,
          # keep waiting for the real continuation on a later line.
          emit_tags_in_chars(line[:chars], page_index, regex, open_delim, close_delim) { |c, p| yield c, p }
          next
        else
          # Ambiguous continuation that still doesn't balance - give up on the
          # pending fragment rather than risk absorbing unrelated tags, then
          # fall through to process this line normally below.
          pending = nil
        end
      end

      if open_count > close_count
        # Dangling open at the end of this line - hold as pending and keep
        # searching forward for the line that closes it.
        pending = { chars: line[:chars].dup }
      else
        emit_tags_in_chars(line[:chars], page_index, regex, open_delim, close_delim) { |c, p| yield c, p }
      end
    end
  end

  # Runs the tag regex over a flat array of characters (their joined text),
  # records each match's position for white-box overlay, and yields
  # [tag_content, position] to the caller.
  def emit_tags_in_chars(chars, page_index, regex, open_delim, close_delim)
    text = chars.map(&:text).join
    pos_cursor = 0

    while (match = regex.match(text, pos_cursor))
      tag_content = match[1]
      full_tag = "#{open_delim}#{tag_content}#{close_delim}"

      position = tag_position_within_chars(chars, match.begin(0), match.end(0))
      pos_cursor = match.end(0)

      next unless position

      @tag_positions << {
        page: page_index,
        x: position[:x],
        y: position[:y],
        width: position[:width],
        height: position[:height],
        text: full_tag
      }

      yield tag_content, position
    end
  end

  # Computes the absolute (page-space) x/y/width/height spanning the
  # characters between match_start_index (inclusive) and match_end_index
  # (exclusive) within a flat array of PDF::Reader::TextRun characters.
  # Uses the first line's y/font_size for placement, and the actual x extent
  # of the matched characters for width (correctly handling multi-line spans
  # by using only the width of matched chars on the first line).
  def tag_position_within_chars(chars, match_start_index, match_end_index)
    matched_chars = chars[match_start_index...match_end_index]
    return nil if matched_chars.blank?

    first_char = matched_chars.first
    # Only use characters on the same baseline as the first matched character
    # for width calculation, so multi-line tags report the first line's span.
    same_line_chars = matched_chars.take_while { |c| c.y.round(1) == first_char.y.round(1) }
    same_line_chars = matched_chars if same_line_chars.empty?

    last_char = same_line_chars.last
    x = first_char.x
    width = (last_char.x + last_char.width) - first_char.x
    font_size = first_char.font_size.to_f
    height = font_size * 1.3
    y_adjusted = first_char.y - (font_size * 0.25)

    { x: x, y: y_adjusted, width: width, height: height }
  rescue StandardError => e
    Rails.logger.error("Error calculating tag position: #{e.message}") if defined?(Rails)
    nil
  end

  # Parse a Sertifi [[...]] tag and create field definition
  # Format: [[TagType:Attributes]] where attributes are colon-separated key=value pairs
  # Examples:
  #   [[SFLD:FullName:W=100,H=15,R=True]]
  #   [[SertifiSignature:S=1]]
  #   [[SFLD:Email:W=100,H=15,R=True]]
  def parse_sertifi_field_at_position(tag_content, page_index, x, y, tag_width, tag_height, page_width, page_height)
    # Parse Sertifi tag attributes (colon-separated, with comma-separated key=value pairs)
    sertifi_attrs = parse_sertifi_tag_attributes(tag_content)

    # Look up field type/name from SERTIFI_TAG_MAPPINGS
    mapping = SERTIFI_TAG_MAPPINGS.find { |pattern, _| tag_content.match?(pattern) }
    return nil unless mapping

    mapped = mapping[1]
    field_type = mapped[:type]
    field_name = mapped[:name] || sertifi_attrs[:field_name] || tag_content.split(':')[1]

    # Use W/H from tag attributes if present, otherwise use defaults
    field_width = sertifi_attrs[:width] || SFLD_DEFAULT_WIDTH
    field_height = sertifi_attrs[:height] || SFLD_DEFAULT_HEIGHT

    # Convert to relative coordinates (0-1 range)
    rel_x = x / page_width
    rel_y = 1.0 - ((y + field_height) / page_height)
    rel_w = field_width / page_width
    rel_h = field_height / page_height

    # Clamp to valid ranges
    rel_x = [[rel_x, 0].max, 0.95].min
    rel_y = [[rel_y, 0].max, 0.95].min
    rel_w = [[rel_w, 0.02].max, 1 - rel_x].min
    rel_h = [[rel_h, 0.01].max, 1 - rel_y].min

    # Build field
    field = {
      uuid: SecureRandom.uuid,
      name: field_name,
      type: field_type,
      required: sertifi_attrs[:required],
      readonly: false,
      areas: [{
        x: rel_x,
        y: rel_y,
        w: rel_w,
        h: rel_h,
        page: page_index
      }]
    }

    # Apply mapped preferences (e.g., mask for SSN)
    field[:preferences] = mapped[:preferences].dup if mapped[:preferences].present?

    # Add signer index as role if present (S=1 means signer 1)
    if sertifi_attrs[:signer]
      field[:role] = "Signer #{sertifi_attrs[:signer]}"
    end

    field
  end

  # Parse Sertifi tag format: "SFLD:FieldName:W=100,H=15,R=True"
  # Returns hash with extracted attributes
  def parse_sertifi_tag_attributes(tag_content)
    parts = tag_content.split(':')
    attrs = {
      tag_type: parts[0],
      field_name: parts[1],
      width: SFLD_DEFAULT_WIDTH.to_f,
      height: SFLD_DEFAULT_HEIGHT.to_f,
      required: false,
      signer: nil
    }

    # Parse remaining parts which contain comma-separated key=value pairs
    # e.g., "W=100,H=15,R=True" or individual parts like "W=100" "H=15"
    remaining = parts[2..] || []
    kv_string = remaining.join(',')

    kv_string.split(',').each do |pair|
      key, value = pair.strip.split('=', 2)
      next unless key && value

      case key.upcase
      when 'W'
        attrs[:width] = value.to_f
      when 'H'
        attrs[:height] = value.to_f
      when 'R'
        attrs[:required] = value.casecmp('true').zero?
      when 'S'
        attrs[:signer] = value.to_i
      end
    end

    attrs
  end

  def parse_field_at_position(tag_content, page_index, x, y, tag_width, tag_height, page_width, page_height)
    parts = tag_content.split(';').map(&:strip)

    # First part is the field name
    name = parts.shift
    return nil if name.blank?

    # Parse attributes
    attributes = parse_attributes(parts)
    field_type = attributes['type'] || 'text'

    # Calculate field dimensions
    field_width = if attributes['width']
      attributes['width'].to_f
    else
      # Use tag width as minimum, but expand for field type
      [tag_width, estimate_field_width(field_type, page_width)].max
    end

    field_height = if attributes['height']
      attributes['height'].to_f
    else
      estimate_field_height(field_type, page_height)
    end

    # Convert to relative coordinates (0-1 range)
    # PDF uses bottom-left origin, maintain it for accuracy
    rel_x = x / page_width
    rel_y = 1.0 - ((y + field_height) / page_height)  # Convert to top-left origin
    rel_w = field_width / page_width
    rel_h = field_height / page_height

    # Clamp values to valid ranges
    rel_x = [[rel_x, 0].max, 0.95].min
    rel_y = [[rel_y, 0].max, 0.95].min
    rel_w = [[rel_w, 0.05].max, 1 - rel_x].min
    rel_h = [[rel_h, 0.02].max, 1 - rel_y].min

    # Build field structure
    field = {
      uuid: SecureRandom.uuid,
      name: name,
      type: field_type,
      required: attributes['required'] != 'false',
      readonly: attributes['readonly'] == 'true',
      areas: [{
        x: rel_x,
        y: rel_y,
        w: rel_w,
        h: rel_h,
        page: page_index
      }]
    }

    # Add optional attributes
    field[:role] = attributes['role'] if attributes['role'].present?
    field[:default_value] = attributes['default'] if attributes['default'].present?
    field[:options] = parse_options(attributes['options']) if attributes['options'].present?
    field[:condition] = parse_condition(attributes['condition']) if attributes['condition'].present?
    field[:preferences] = build_preferences(attributes)

    field
  end

  def estimate_field_width(field_type, page_width)
    case field_type
    when 'signature', 'initials'
      page_width * 0.25
    when 'date', 'datenow'
      page_width * 0.15
    when 'checkbox'
      20
    when 'image', 'file'
      page_width * 0.2
    when 'select', 'radio'
      page_width * 0.2
    else
      page_width * 0.25
    end
  end

  def estimate_field_height(field_type, page_height)
    case field_type
    when 'signature'
      page_height * 0.06
    when 'initials'
      page_height * 0.04
    when 'checkbox'
      20
    when 'image'
      page_height * 0.1
    else
      page_height * 0.025
    end
  end

  def parse_attributes(parts)
    attributes = {}

    parts.each do |part|
      key, value = part.split('=', 2).map(&:strip)
      attributes[key] = value if key.present?
    end

    attributes
  end

  def parse_options(options_str)
    options_str.split(',').map(&:strip).map do |opt|
      { uuid: SecureRandom.uuid, value: opt }
    end
  end

  def parse_condition(condition_str)
    if condition_str.include?(':')
      field_name, value = condition_str.split(':', 2)
      { field: field_name.strip, value: value.strip }
    else
      { field: condition_str.strip, value: 'non_empty' }
    end
  end

  def build_preferences(attributes)
    prefs = {}

    prefs['format'] = attributes['format'] if attributes['format']
    prefs['min'] = attributes['min'] if attributes['min']
    prefs['max'] = attributes['max'] if attributes['max']
    prefs['font'] = attributes['font'] if attributes['font']
    prefs['font_size'] = attributes['font_size'].to_i if attributes['font_size']
    prefs['font_type'] = attributes['font_type'] if attributes['font_type']
    prefs['color'] = attributes['color'] if attributes['color']
    prefs['align'] = attributes['align'] if attributes['align']
    prefs['valign'] = attributes['valign'] if attributes['valign']
    prefs['mask'] = true if attributes['mask'] == 'true'
    prefs['method'] = attributes['method'] if attributes['method']

    prefs.compact
  end

  def register_submitter(role_name)
    return if @submitters[role_name]

    @submitters[role_name] = {
      name: role_name,
      uuid: SecureRandom.uuid
    }
  end

  class ParseError < StandardError; end
end
