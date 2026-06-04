# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TemplateFolderPermission, type: :model do
  describe 'validations' do
    it 'is valid when user and folder share the same account' do
      permission = build(:template_folder_permission)

      expect(permission).to be_valid
    end

    it 'rejects duplicate (user_id, template_folder_id) pairs' do
      existing = create(:template_folder_permission)
      duplicate = build(:template_folder_permission,
                        user: existing.user,
                        template_folder: existing.template_folder)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it 'adds an error on :user when user and folder belong to different accounts' do
      account_a = create(:account)
      account_b = create(:account)
      user = create(:user, account: account_a)
      folder = create(:template_folder, account: account_b)
      permission = build(:template_folder_permission, user: user, template_folder: folder)

      expect(permission).not_to be_valid
      expect(permission.errors[:user]).to include('must belong to the same account as the folder')
    end
  end
end
