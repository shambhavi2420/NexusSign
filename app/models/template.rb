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
    self.folder ||= account.default_template_folder
  end


# Replace the entire create_from_pdf_tags method in app/models/template.rb

def self.create_from_pdf_tags(account:, author:, name:, pdf_blob:, parsed_data:,folder: nil)
  fields = parsed_data[:fields]
  submitters = parsed_data[:submitters]
  tag_positions = parsed_data[:tag_positions]
  
  # Ensure we have at least one submitter
  if submitters.empty?
    submitters = [{ name: 'First Party', uuid: SecureRandom.uuid }]
  end
  
  # Build submitters array
  template_submitters = submitters.map { |s| { 'name' => s[:name], 'uuid' => s[:uuid] } }
  
folder = TemplateFolder.find_or_create_by!(account_id: account.id, name: 'Tag Based Requests')

template = create!(
  account: account,
  author: author,
  name: name,
  folder: folder,
  submitters: template_submitters,
  schema: [],
  fields: [],
  source: 'api'
)  
  # Process PDF: remove tags and create clean version
  input_tempfile = Tempfile.new(['input', '.pdf'], encoding: 'ascii-8bit')
  input_tempfile.binmode
  input_tempfile.write(pdf_blob)
  input_tempfile.rewind
  
  output_tempfile = Tempfile.new(['output', '.pdf'], encoding: 'ascii-8bit')
  output_tempfile.binmode
  
  # Remove tags by overlaying white rectangles
  if tag_positions.any?
    PdfFieldParser.remove_tags_and_add_fields(
      input_tempfile.path,
      output_tempfile.path,
      parsed_data
    )
    output_tempfile.rewind
    final_pdf_content = output_tempfile.read
  else
    final_pdf_content = pdf_blob
  end
  
  # Create uploaded file for attachment
  final_tempfile = Tempfile.new(['final', '.pdf'], encoding: 'ascii-8bit')
  final_tempfile.binmode
  final_tempfile.write(final_pdf_content)
  final_tempfile.rewind
  
  uploaded_file = ActionDispatch::Http::UploadedFile.new(
    tempfile: final_tempfile,
    filename: "#{name}.pdf",
    type: 'application/pdf'
  )
  
  # Use existing attachment creation logic
  documents = Templates::CreateAttachments.call(
    template, 
    { files: [uploaded_file] }, 
    extract_fields: false
  )
  
  attachment_uuid = documents.first.uuid
  
  # Build schema with actual attachment UUID
  schema = documents.map { |doc| { 'attachment_uuid' => doc.uuid, 'name' => doc.filename.base } }
  
  # Build template fields with actual attachment_uuid
  template_fields = fields.map do |field|
    # Find submitter UUID for this field
    submitter_uuid = if field[:role].present?
      submitters.find { |s| s[:name] == field[:role] }&.dig(:uuid)
    else
      submitters.first[:uuid]
    end
    
    # Build areas with the actual attachment_uuid
    areas = field[:areas].map do |area|
      {
        'x' => area[:x],
        'y' => area[:y],
        'w' => area[:w],
        'h' => area[:h],
        'page' => area[:page],
        'attachment_uuid' => attachment_uuid
      }
    end
    
    {
      'uuid' => field[:uuid],
      'name' => field[:name],
      'type' => field[:type],
      'required' => field[:required],
      'readonly' => field[:readonly],
      'submitter_uuid' => submitter_uuid,
      'default_value' => field[:default_value],
      'options' => field[:options],
      'preferences' => field[:preferences] || {},
      'areas' => areas
    }.compact
  end
  
  # Update template with schema and fields
  template.update!(
    schema: schema,
    fields: template_fields
  )
  
  # Cleanup
  input_tempfile.close
  input_tempfile.unlink
  output_tempfile.close
  output_tempfile.unlink
  final_tempfile.close
  final_tempfile.unlink
  
  template
end

end
