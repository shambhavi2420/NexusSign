# frozen_string_literal: true

# == Schema Information
#
# Table name: template_folder_permissions
#
#  id                 :bigint           not null, primary key
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  template_folder_id :bigint           not null
#  user_id            :bigint           not null
#
# Indexes
#
#  idx_tfp_on_folder_and_user  (template_folder_id, user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (template_folder_id => template_folders.id)
#
class TemplateFolderPermission < ApplicationRecord
  belongs_to :template_folder
  belongs_to :user

  validates :user_id, uniqueness: { scope: :template_folder_id }
  validate :user_and_folder_same_account

  private

  def user_and_folder_same_account
    return if user.nil? || template_folder.nil?
    return if user.account_id == template_folder.account_id

    errors.add(:user, 'must belong to the same account as the folder')
  end
end
