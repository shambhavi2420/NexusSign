# frozen_string_literal: true

class TeamMembership < ApplicationRecord
  belongs_to :team
  belongs_to :user

  validates :user_id, uniqueness: { scope: :team_id }
  validate :user_and_team_same_account

  private

  def user_and_team_same_account
    return if user.nil? || team.nil?
    return if user.account_id == team.account_id

    errors.add(:user, 'must belong to the same account as the team')
  end
end
