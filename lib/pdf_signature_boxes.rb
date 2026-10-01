# frozen_string_literal: true

require 'hexapdf'

# Draws one signature box per submitter onto a PDF and reports the DocuSeal
# normalised coordinates of each box, so callers can place signature + date
# fields aligned to them.
#
# Layout rules (shared by /api/custom_submissions and /api/submissions/from_pdf
# when the source PDF has no field tags):
#   - <= 3 signers -> a single row along the bottom of the LAST page
#   - >= 4 signers -> an appended blank page (same size as the last page),
#                     boxes laid out in rows of 3 from the TOP of that page
#
# Usage:
#   pdf_binary, total_pages, box_layout =
#     PdfSignatureBoxes.call(pdf_base64_or_binary, submitters_array)
#
#   submitters_array: Array of hashes responding to [:email] and [:role]
#   box_layout: Array of { x:, y:, w:, h:, page: } in DocuSeal normalised coords,
#               index-aligned with submitters_array.
module PdfSignatureBoxes
  # Shared visual identity for the electronic signature box, referenced both here
  # (creation-time placeholder) and from Submissions::GenerateResultAttachments
  # (final signed appearance) so the border/banner colour and label live in one
  # place.
  #
  # NAVY_COLOR is #00205B = RGB (0, 32, 91), expressed as HexaPDF-normalised
  # fill/stroke components (component / 255.0).
  NAVY_COLOR = [0.0, 0.1255, 0.3569].freeze
  # Same navy as NAVY_COLOR, as a CSS hex string, for the HTML stamp overlay in
  # the completed-submission portal view (keeps portal + PDF colour in sync).
  NAVY_COLOR_HEX = '#00205B'
  ELECTRONIC_SIGNATURE_LABEL = 'NexusSIGN Electronic Signature'

  module_function

  # Accepts either a base64 string or raw PDF binary and returns
  # [modified_pdf_binary, total_pages, box_layout].
  #
  # with_identity_text: defaults to true so the signing-time placeholder box shows
  # the role label and a "Digitally signed by {email}" line (otherwise the field
  # looks empty while signing). The final navy signature box replaces this at
  # result-generation time. Pass false to suppress the placeholder text.
  def call(pdf_input, submitters_array, with_identity_text: true)
    pdf_binary  = looks_like_base64?(pdf_input) ? Base64.decode64(pdf_input) : pdf_input
    n           = submitters_array.size
    result      = nil
    total_pages = nil
    box_layout  = []

    Tempfile.create(['labeled_input', '.pdf'], encoding: 'ascii-8bit') do |input_file|
      input_file.binmode
      input_file.write(pdf_binary)
      input_file.rewind

      doc            = HexaPDF::Document.open(input_file.path)
      original_pages = doc.pages.count
      last_page      = doc.pages[-1]
      page_box       = last_page.box(:media)
      page_w         = page_box.width.to_f
      page_h         = page_box.height.to_f

      if n <= 3
        # <= 3 signers: single row at the bottom of the last page.
        box_layout = draw_signature_row(
          doc, last_page, page_w, page_h, submitters_array,
          row_index: 0, page_index: original_pages - 1, anchor: :bottom,
          with_identity_text:
        )
        total_pages = original_pages
      else
        # >= 4 signers: append a blank page, rows of 3 from the top.
        new_page = doc.pages.add
        new_page.box(:media, value: [0, 0, page_w, page_h])

        total_pages    = original_pages + 1
        new_page_index = total_pages - 1

        submitters_array.each_slice(3).each_with_index do |row_signers, row_idx|
          row_layout = draw_signature_row(
            doc, new_page, page_w, page_h, row_signers,
            row_index: row_idx, page_index: new_page_index, anchor: :top,
            with_identity_text:
          )
          box_layout.concat(row_layout)
        end
      end

      Tempfile.create(['labeled_output', '.pdf'], encoding: 'ascii-8bit') do |output_file|
        output_file.binmode
        doc.write(output_file.path)
        output_file.rewind
        result = output_file.read
      end
    end

    Rails.logger.info(
      "[PdfSignatureBoxes] pages after processing: #{total_pages}, boxes drawn: #{box_layout.size}"
    ) if defined?(Rails)

    [result, total_pages, box_layout]
  end

  # Draws a horizontal row of signature boxes onto `page` for the given
  # `signers` sub-array and returns their DocuSeal-normalised coordinates.
  #
  # anchor: :bottom -> boxes pinned to the page bottom (last-page case)
  #         :top    -> boxes stacked from the top, offset by row_index (appended page)
  def draw_signature_row(doc, page, page_w, page_h, signers, row_index:, page_index:, anchor:,
                         with_identity_text: true)
    n        = signers.size
    margin_x = page_w * 0.03
    margin_y = page_h * 0.03
    box_h    = page_h * 0.12
    row_gap  = page_h * 0.015
    total_w  = page_w - (2 * margin_x)
    gap      = page_w * 0.01

    # Use max 3-column sizing so a single signer doesn't stretch full width.
    reference_columns = [n, 3].max
    box_w             = (total_w - (gap * (reference_columns - 1))) / reference_columns

    box_y = if anchor == :bottom
              margin_y * 0.4
            else
              page_h - margin_y - box_h - (row_index * (box_h + row_gap))
            end

    canvas = page.canvas(type: :overlay)

    signers.each_with_index.map do |signer, i|
      box_x      = margin_x + (i * (box_w + gap))
      email      = signer[:email]
      role_label = signer[:role].to_s

      draw_single_box(canvas, box_x, box_y, box_w, box_h, email, role_label, with_identity_text:)

      {
        x:    box_x / page_w,
        y:    1.0 - ((box_y + box_h) / page_h) + 0.009,
        w:    box_w / page_w,
        h:    box_h / page_h,
        page: page_index
      }
    end
  end

  # Renders a single box with background, border, and (optionally) identity text.
  #
  # with_identity_text: defaults to true, so the role label and "Digitally signed
  # by {email}" line are drawn — this keeps the signing-time placeholder box
  # informative instead of empty. Pass false to suppress them.
  def draw_single_box(canvas, box_x, box_y, box_w, box_h, email, role_label, with_identity_text: true)
    padding = 6

    canvas.save_graphics_state
    canvas.fill_color(0.94, 0.96, 0.98)
    canvas.rectangle(box_x, box_y, box_w, box_h).fill
    canvas.restore_graphics_state

    canvas.save_graphics_state
    canvas.stroke_color(*NAVY_COLOR)
    canvas.line_width(0.8)
    canvas.rectangle(box_x, box_y, box_w, box_h).stroke
    canvas.restore_graphics_state

    return unless with_identity_text

    # Role label (top)
    canvas.fill_color(0.35, 0.35, 0.35)
    canvas.font('Helvetica', size: 7)
    canvas.text(role_label, at: [box_x + padding, box_y + box_h - padding - 2])

    # "Digitally signed by" line (bottom)
    canvas.font('Helvetica', size: 6)
    canvas.text("Digitally signed by #{email}", at: [box_x + padding, box_y + padding + 1])
  end

  # Builds the signature + date field hashes for each drawn box, index-aligned
  # with template_submitters (an array of { 'uuid' => ..., 'name' => role }).
  # Mirrors the field geometry used by CustomSubmissionsController.
  #
  # with_date_field: defaults to true so a readonly "signed_date_N" date field is
  # placed below each signature and filled during signing (the field is visible
  # while signing). Pass false to omit it.
  def build_box_fields(box_layout, template_submitters, attachment_uuid, with_date_field: true)
    template_submitters.each_with_index.flat_map do |submitter, i|
      box = box_layout[i]
      next [] unless box

      submitter_uuid = submitter['uuid']

      sig_h  = box[:h] * 0.55
      sig_y  = box[:y] + (box[:h] * 0.06)
      date_h = box[:h] * 0.16
      date_y = box[:y] + (box[:h] * 0.60)

      fields = [
        {
          'uuid'           => SecureRandom.uuid,
          'submitter_uuid' => submitter_uuid,
          'name'           => "signature_#{i + 1}",
          'type'           => 'signature',
          'required'       => true,
          'areas'          => [{
            'x'               => box[:x] + (box[:w] * 0.05),
            'y'               => sig_y,
            'w'               => box[:w] * 0.90,
            'h'               => sig_h,
            'page'            => box[:page],
            'attachment_uuid' => attachment_uuid
          }]
        }
      ]

      if with_date_field
        fields << {
          'uuid'           => SecureRandom.uuid,
          'submitter_uuid' => submitter_uuid,
          'name'           => "signed_date_#{i + 1}",
          'type'           => 'date',
          'required'       => false,
          'readonly'       => true,
          'default_value'  => '{{date}}',
          'areas'          => [{
            'x'               => box[:x] + (box[:w] * 0.05),
            'y'               => date_y,
            'w'               => box[:w] * 0.55,
            'h'               => date_h,
            'page'            => box[:page],
            'attachment_uuid' => attachment_uuid
          }]
        }
      end

      fields
    end.compact
  end

  # Heuristic: a base64 PDF payload is ASCII and does not start with the raw
  # "%PDF" magic bytes. Raw binary starts with "%PDF".
  def looks_like_base64?(input)
    return false unless input.is_a?(String)

    !input.start_with?('%PDF')
  end
end
