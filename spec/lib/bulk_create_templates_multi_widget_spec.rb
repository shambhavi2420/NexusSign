# frozen_string_literal: true

require 'rails_helper'

# Regression: a single AcroForm field placed at multiple spots on the page
# (multiple widgets) must migrate as one template field PER widget, so none are
# dropped. (A HealthTrust form had one `SertifiDate_1` field with two widgets —
# top + next to the signature — and only the top one migrated.)
RSpec.describe DataMigrations::BulkCreateTemplates, 'multi-widget AcroForm fields' do
  # Builds a one-page PDF with a `SertifiDate_1` text field that has TWO widgets,
  # plus a single-widget `SertifiSignature_1`.
  def build_pdf
    require 'hexapdf'

    doc  = HexaPDF::Document.new
    page = doc.pages.add([0, 0, 600, 800])
    form = doc.acro_form(create: true)

    date_field = form.create_text_field('SertifiDate_1')
    date_field.set_default_appearance_string
    w1 = date_field.create_widget(page, Rect: [100, 700, 220, 718])
    w2 = date_field.create_widget(page, Rect: [340, 380, 440, 400])
    # Tooltip hints "Date" (matches the Sertifi mapping by field name anyway).
    date_field[:TU] = 'Date'

    sig_field = form.create_text_field('SertifiSignature_1')
    sig_field.create_widget(page, Rect: [120, 380, 280, 404])

    io = StringIO.new
    doc.write(io)
    io.string
  end

  it 'extracts one field per widget (both date boxes + the signature)' do
    blob = build_pdf

    rows = described_class.send(:extract_sertifi_fields_from_acroform, blob)

    dates = rows.select { |r| r[:type] == 'date' }
    sigs  = rows.select { |r| r[:type] == 'signature' }

    expect(dates.size).to eq(2)
    expect(sigs.size).to eq(1)

    # The two date widgets are at different vertical positions.
    expect(dates.map { |d| d[:rel_y].round(2) }.uniq.size).to eq(2)
  end
end
