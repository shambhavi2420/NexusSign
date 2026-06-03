# frozen_string_literal: true

# lib/pdf_field_parser.rb
# Service to parse embedded PDF field tags and extract their actual positions
# with precise text positioning using transformation matrices

require 'pdf-reader'
require 'hexapdf'

class PdfFieldParser
  FIELD_TAG_REGEX = /\{\{([^}]+)\}\}/

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

  def extract_tags_from_page(page, page_index)
  receiver = PreciseTextReceiver.new(page)
  page.walk(receiver)

  puts "Page #{page_index}: #{receiver.text_runs.size} text runs"
  receiver.text_runs.each do |run|
  puts "  RUN[#{page_index}]: #{run[:text].inspect}"
  end

  page_width = page.width
  page_height = page.height

  receiver.text_runs.each do |text_run|
    text = text_run[:text]
    next unless text.match?(FIELD_TAG_REGEX)
    process_tags_in_text_run(text_run, page_index, page_width, page_height)
  end
end
  def process_tags_in_text_run(text_run, page_index, page_width, page_height)
    text = text_run[:text]
    
    text.scan(FIELD_TAG_REGEX).each do |match|
      tag_content = match[0]
      full_tag = "{{#{tag_content}}}"

      # Find position of tag in this text run
      tag_start_index = text.index(full_tag)
      next unless tag_start_index

      # Calculate precise position using character-level metrics
      position = calculate_precise_tag_position(
        text_run,
        tag_start_index,
        full_tag.length,
        page_width,
        page_height
      )

      next unless position

      # Store tag position for overlay removal - use EXACT tag width only
      @tag_positions << {
        page: page_index,
        x: position[:x],
        y: position[:y],
        width: position[:tag_width],  # Exact tag text width
        height: position[:height],
        text: full_tag
      }

      # Parse and create field at this position
      field = parse_field_at_position(
        tag_content,
        page_index,
        position[:x],
        position[:y],
        position[:width],  # Use full width for field sizing
        position[:height],
        page_width,
        page_height
      )

      if field
        @parsed_fields << field
        register_submitter(field[:role]) if field[:role]
      end
    end
  end

  def calculate_precise_tag_position(text_run, tag_start_index, tag_length, page_width, page_height)
    font = text_run[:font]
    font_size = text_run[:font_size]
    text = text_run[:text]
    tm = text_run[:text_matrix]
    
    # Calculate width of text before the tag
    text_before = text[0...tag_start_index]
    offset_before = calculate_text_width(text_before, font, font_size)
    
    # Calculate width of the tag itself
    tag_text = text[tag_start_index, tag_length]
    tag_width = calculate_text_width(tag_text, font, font_size)
    
    # Apply text matrix transformation to get actual position
    # Text matrix is [a, b, c, d, e, f] where e,f are translation
    scale_x = Math.sqrt(tm[0]**2 + tm[1]**2)
    scale_y = Math.sqrt(tm[2]**2 + tm[3]**2)
    
    # Calculate transformed position
    base_x = tm[4]
    base_y = tm[5]
    
    # Apply horizontal offset for text before tag
    tag_x = base_x + (offset_before * scale_x)
    tag_y = base_y
    
    # Calculate dimensions with scaling
    actual_tag_width = tag_width * scale_x
    actual_tag_height = font_size * scale_y
    
    # Adjust for baseline (text is positioned at baseline, not top-left)
    # Most fonts have descent of about 20-25% of font size
    descent_ratio = 0.25
    tag_y_adjusted = tag_y - (actual_tag_height * descent_ratio)
    
    {
      x: tag_x,
      y: tag_y_adjusted,
      width: actual_tag_width,  # For field width estimation
      tag_width: actual_tag_width,  # Exact tag width for covering
      height: actual_tag_height * 1.3  # Add some vertical padding
    }
  rescue => e
    Rails.logger.error("Error calculating tag position: #{e.message}") if defined?(Rails)
    nil
  end

  def calculate_text_width(text, font, font_size)
    return 0 if text.nil? || text.empty? || font.nil?
    
    total_width = 0
    
    text.each_char do |char|
      # Get character width from font metrics
      char_width = get_char_width(font, char)
      total_width += char_width
    end
    
    # Convert from glyph space (1000 units = 1em) to user space
    total_width * font_size / 1000.0
  end

  def get_char_width(font, char)
    # Try multiple methods to get character width
    return font.glyph_width(char) if font.respond_to?(:glyph_width) && font.glyph_width(char)
    
    # Try to get from font metrics
    if font.respond_to?(:widths)
      char_code = char.ord
      return font.widths[char_code] if font.widths && font.widths[char_code]
    end
    
    # Fallback: estimate based on character type
    case char
    when 'i', 'l', 'I', '!', '|', '.', ',', ':', ';'
      300  # Narrow characters
    when 'm', 'w', 'M', 'W'
      900  # Wide characters
    when ' '
      250  # Space
    when '{'
      400
    when '}'
      400
    else
      500  # Average character width
    end
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

  # Enhanced text receiver with precise positioning using transformation matrices
  class PreciseTextReceiver
    attr_reader :text_runs

    def initialize(page)
      @page = page
      @text_runs = []
      @current_font = nil
      @current_font_size = 12
      @text_matrix = [1, 0, 0, 1, 0, 0]
      @text_line_matrix = [1, 0, 0, 1, 0, 0]
      @character_spacing = 0
      @word_spacing = 0
      @horizontal_scaling = 100
      @text_rise = 0
    end

    def show_text(string, *params)
      return if string.nil? || string.empty?
      
      @text_runs << {
        text: string,
        font: @current_font,
        font_size: @current_font_size,
        text_matrix: @text_matrix.dup,
        character_spacing: @character_spacing,
        word_spacing: @word_spacing,
        horizontal_scaling: @horizontal_scaling,
        text_rise: @text_rise
      }
    end

    def show_text_with_positioning(array, *params)
      return if array.nil? || array.empty?
      
      # Combine text elements from positioning array
      text = array.select { |e| e.is_a?(String) }.join
      show_text(text) if text.present?
    end

    # Font and text state operators
    def set_text_font_and_size(name, size)
      @current_font_size = size
      # Try to get font object from page resources
      begin
        @current_font = @page.fonts[name] if @page.respond_to?(:fonts)
      rescue => e
        # Font not available, will use fallback metrics
        @current_font = nil
      end
    end

    def set_character_spacing(spacing)
      @character_spacing = spacing
    end

    def set_word_spacing(spacing)
      @word_spacing = spacing
    end

    def set_horizontal_text_scaling(scaling)
      @horizontal_scaling = scaling
    end

    def set_text_rise(rise)
      @text_rise = rise
    end

    # Text positioning operators
    def set_text_matrix_and_text_line_matrix(a, b, c, d, e, f)
      @text_matrix = [a, b, c, d, e, f]
      @text_line_matrix = [a, b, c, d, e, f]
    end

    def move_text_position(tx, ty)
      # Translate the text line matrix
      @text_line_matrix[4] += tx
      @text_line_matrix[5] += ty
      @text_matrix = @text_line_matrix.dup
    end

    def move_text_position_and_set_leading(tx, ty)
      move_text_position(tx, ty)
    end

    def move_to_start_of_next_line
      # This would need the text leading value
      # Simplified implementation
      @text_matrix = @text_line_matrix.dup
    end

    # Graphics state operators
    def save_graphics_state
      # Would need to implement state stack for full precision
    end

    def restore_graphics_state
      # Would need to implement state stack for full precision
    end

    # Catch-all for other PDF operators
    def method_missing(method, *args)
      # Silently ignore other PDF operations
    end

    def respond_to_missing?(method, include_private = false)
      true
    end
  end

  class ParseError < StandardError; end
end
