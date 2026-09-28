# frozen_string_literal: true

# == Schema Information
#
# Table name: templates
#
#  id               :bigint           not null, primary key
#  archived_at      :datetime
#  fields           :text             not null
#  name             :string           not null
#  preferences      :text             not null
#  schema           :text             not null
#  shared_link      :boolean          default(FALSE), not null
#  slug             :string           not null
#  source           :text             not null
#  submitters       :text             not null
#  variables_schema :text
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  author_id        :bigint           not null
#  external_id      :string
#  folder_id        :bigint           not null
#
# Indexes
#
#  index_templates_on_account_id                       (account_id)
#  index_templates_on_account_id_and_folder_id_and_id  (account_id,folder_id,id) WHERE (archived_at IS NULL)
#  index_templates_on_account_id_and_id_archived       (account_id,id) WHERE (archived_at IS NOT NULL)
#  index_templates_on_author_id                        (author_id)
#  index_templates_on_external_id                      (external_id)
#  index_templates_on_folder_id                        (folder_id)
#  index_templates_on_slug                             (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (author_id => users.id)
#  fk_rails_...  (folder_id => template_folders.id)
#
class Template < ApplicationRecord
  DEFAULT_SUBMITTER_NAME = 'First Party'
  PAD_AMOUNT = 2
  belongs_to :author, class_name: 'User'
  belongs_to :account
  belongs_to :folder, class_name: 'TemplateFolder'

  has_one :search_entry, as: :record, inverse_of: :record, dependent: :destroy if SearchEntry.table_exists?

  before_validation :maybe_set_default_folder, on: :create

  attribute :preferences, :string, default: -> { {} }
  attribute :fields, :string, default: -> { [] }
  attribute :schema, :string, default: -> { [] }
  attribute :submitters, :string, default: -> { [{ name: I18n.t(:first_party), uuid: SecureRandom.uuid }] }
  attribute :slug, :string, default: -> { SecureRandom.base58(14) }
  attribute :source, :string, default: 'native'

  serialize :preferences, coder: JSON
  serialize :fields, coder: JSON
  serialize :variables_schema, coder: JSON
  serialize :schema, coder: JSON
  serialize :submitters, coder: JSON

  has_many_attached :documents

  has_many :schema_documents, ->(e) { where(uuid: e.schema.pluck('attachment_uuid')) },
           class_name: 'ActiveStorage::Attachment', dependent: :destroy, as: :record, inverse_of: :record

  has_many :submissions, dependent: :destroy
  has_many :template_sharings, dependent: :destroy
  has_many :template_accesses, dependent: :destroy

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  def application_key
    external_id
  end

  def folder_name
    folder.full_name
  end

  private

  def maybe_set_default_folder
    return if folder.present?

    default_folder = account.default_template_folder

    if author && TemplateFolderPermissions.restricted?(default_folder) &&
       !TemplateFolderPermissions.can_view?(author, default_folder)
      self.folder = account.template_folders.create_with(author:)
                           .find_or_create_by(name: author.full_name.presence || author.email, parent_folder_id: nil)
    else
      self.folder = default_folder
    end
  end
  # Builds a template from a tag-based PDF for the standardized /from_pdf API.
  #
  # `submitters_array` is the caller-provided list of real signers (each a hash
  # with at least :email and :role), matching the /custom_submissions contract.
  # The template's submitter entries are derived from these (role => name), and
  # parsed tag fields are bound to a submitter by matching the tag's :role to a
  # submitter :role. Roleless fields fall to the first submitter.
  #
  # When the PDF contains NO tags, we fall back to PdfSignatureBoxes: one
  # signature + date box per submitter is drawn and used as the fields (the same
  # behavior as /custom_submissions).
  #
  # Returns the persisted Template. The caller runs the shared submission flow.
  def self.create_from_pdf_tags(account:, author:, name:, pdf_blob:, parsed_data:, submitters_array:)
    parsed_fields = parsed_data[:fields] || []
    tag_positions = parsed_data[:tag_positions] || []
    has_tags      = parsed_fields.any?

    # One template-submitter entry per real signer; role becomes the name so it
    # matches how the standardized submission flow resolves submitters by role.
    template_submitters = submitters_array.map do |s|
      { 'name' => s[:role], 'uuid' => SecureRandom.uuid }
    end

    # Key submitters by a whitespace/case-normalized role so tag roles match
    # even when PDF text extraction mangles spacing (e.g. "Signer 1" -> "Signer1").
    role_to_uuid = template_submitters.index_by { |ts| normalize_role(ts['name']) }
    first_uuid   = template_submitters.first&.fetch('uuid')

    folder = TemplateFolder.create_with(author: author)
                           .find_or_create_by!(account_id: account.id, name: 'Tag Based Requests')

    template = create!(
      account:     account,
      author:      author,
      name:        name,
      folder:      folder,
      submitters:  template_submitters,
      schema:      [],
      fields:      [],
      source:      'api',
      preferences: { 'submitters_order' => 'preserved' }
    )

    # Produce the final PDF: erase tags when present, otherwise draw signature
    # boxes for a tag-less document.
    box_layout = []

    final_pdf_content =
      if has_tags || tag_positions.any?
        erase_pdf_tags(pdf_blob, parsed_data)
      else
        drawn_pdf, _total_pages, box_layout =
          PdfSignatureBoxes.call(pdf_blob, submitters_array)
        drawn_pdf
      end

    final_tempfile = Tempfile.new(['final', '.pdf'], encoding: 'ascii-8bit')
    final_tempfile.binmode
    final_tempfile.write(final_pdf_content)
    final_tempfile.rewind

    uploaded_file = ActionDispatch::Http::UploadedFile.new(
      tempfile: final_tempfile,
      filename: "#{name}.pdf",
      type:     'application/pdf'
    )

    documents = Templates::CreateAttachments.call(
      template, { files: [uploaded_file] }, extract_fields: false
    )

    attachment_uuid = documents.first.uuid
    schema          = documents.map { |doc| { 'attachment_uuid' => doc.uuid, 'name' => doc.filename.base } }

    template_fields =
      if has_tags
        build_tag_fields(parsed_fields, attachment_uuid, role_to_uuid, first_uuid)
      else
        PdfSignatureBoxes.build_box_fields(box_layout, template_submitters, attachment_uuid)
      end

    template.update!(schema: schema, fields: template_fields)

    template
  ensure
    final_tempfile&.close
    final_tempfile&.unlink
  end

  # Overlays white rectangles over detected tags and returns the cleaned PDF
  # binary. Kept private-ish (class method) so create_from_pdf_tags stays lean.
  def self.erase_pdf_tags(pdf_blob, parsed_data)
    input_tempfile  = Tempfile.new(['input', '.pdf'], encoding: 'ascii-8bit')
    output_tempfile = Tempfile.new(['output', '.pdf'], encoding: 'ascii-8bit')

    input_tempfile.binmode
    input_tempfile.write(pdf_blob)
    input_tempfile.rewind
    output_tempfile.binmode

    PdfFieldParser.remove_tags_and_add_fields(input_tempfile.path, output_tempfile.path, parsed_data)
    output_tempfile.rewind
    output_tempfile.read
  ensure
    input_tempfile&.close
    input_tempfile&.unlink
    output_tempfile&.close
    output_tempfile&.unlink
  end

  # Normalizes a role string for tolerant matching: lowercased, all whitespace
  # removed. So "Signer 1", "signer 1", and a space-stripped "Signer1" all match.
  def self.normalize_role(role)
    role.to_s.downcase.gsub(/\s+/, '')
  end

  # Maps parsed tag fields into template field hashes, binding each to a
  # submitter by role (roleless -> first submitter) and stamping the real
  # attachment_uuid onto every area.
  def self.build_tag_fields(parsed_fields, attachment_uuid, role_to_uuid, first_uuid)
    parsed_fields.map do |field|
      submitter_uuid =
        if field[:role].present?
          role_to_uuid[normalize_role(field[:role])]&.fetch('uuid') || first_uuid
        else
          first_uuid
        end

      areas = field[:areas].map do |area|
        {
          'x'               => area[:x],
          'y'               => area[:y],
          'w'               => area[:w],
          'h'               => area[:h],
          'page'            => area[:page],
          'attachment_uuid' => attachment_uuid
        }
      end

      {
        'uuid'           => field[:uuid],
        'name'           => field[:name],
        'type'           => field[:type],
        'required'       => field[:required],
        'readonly'       => field[:readonly],
        'submitter_uuid' => submitter_uuid,
        'default_value'  => field[:default_value],
        'options'        => field[:options],
        'preferences'    => field[:preferences] || {},
        'areas'          => areas
      }.compact
    end
  end
end
