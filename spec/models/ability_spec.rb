# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Ability, type: :model do
  describe 'TemplateFolderPermission authorization' do
    let(:account) { create(:account) }

    describe 'admin role' do
      let(:admin) { create(:user, account: account, role: 'admin') }
      let(:ability) { Ability.new(admin) }

      it 'can manage any TemplateFolderPermission' do
        other_user = create(:user, account: account, role: 'editor')
        folder = create(:template_folder, account: account, author: other_user)
        permission = create(:template_folder_permission, template_folder: folder, user: other_user)

        expect(ability.can?(:manage, permission)).to be true
      end
    end

    describe 'editor role' do
      let(:editor) { create(:user, account: account, role: 'editor') }
      let(:ability) { Ability.new(editor) }

      it 'can manage TemplateFolderPermission for folders they own' do
        folder = create(:template_folder, account: account, author: editor)
        other_user = create(:user, account: account, role: 'editor')
        permission = create(:template_folder_permission, template_folder: folder, user: other_user)

        expect(ability.can?(:manage, permission)).to be true
      end

      it 'cannot manage TemplateFolderPermission for folders owned by another user' do
        other_editor = create(:user, account: account, role: 'editor')
        folder = create(:template_folder, account: account, author: other_editor)
        viewer = create(:user, account: account, role: 'viewer')
        permission = create(:template_folder_permission, template_folder: folder, user: viewer)

        expect(ability.can?(:manage, permission)).to be false
      end
    end

    describe 'viewer role' do
      let(:viewer) { create(:user, account: account, role: 'viewer') }
      let(:ability) { Ability.new(viewer) }

      it 'cannot manage TemplateFolderPermission' do
        editor = create(:user, account: account, role: 'editor')
        folder = create(:template_folder, account: account, author: editor)
        permission = create(:template_folder_permission, template_folder: folder, user: viewer)

        expect(ability.can?(:manage, permission)).to be false
      end
    end
  end
end
