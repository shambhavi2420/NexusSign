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
  belongs_to :user, optional: true
  belongs_to :team, optional: true

  validates :user_id, uniqueness: { scope: :template_folder_id }, allow_nil: true
  validates :team_id, uniqueness: { scope: :template_folder_id }, allow_nil: true
  validate :user_and_folder_same_account
  validate :team_and_folder_same_account
  validate :user_or_team_present

  private

  def user_or_team_present
    return if user_id.present? || team_id.present?

    errors.add(:base, 'must have either a user or a team')
  end

  def user_and_folder_same_account
    return if user.nil? || template_folder.nil?
    return if user.account_id == template_folder.account_id

    errors.add(:user, 'must belong to the same account as the folder')
  end

  def team_and_folder_same_account
    return if team.nil? || template_folder.nil?
    return if team.account_id == template_folder.account_id

    errors.add(:team, 'must belong to the same account as the folder')
  end
end
