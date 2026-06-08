# frozen_string_literal: true

class Team < ApplicationRecord
  belongs_to :account

  has_many :team_memberships, dependent: :destroy
  has_many :users, through: :team_memberships
  has_many :template_folder_permissions, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :account_id }
end
