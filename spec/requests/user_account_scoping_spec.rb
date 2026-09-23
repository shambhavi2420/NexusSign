# frozen_string_literal: true

require 'rails_helper'

# Hardening for user create/edit account scoping (Requirements 2.6, 3.3, 3.4).
describe 'User account scoping', type: :request do
  let(:company_a) { create(:account, name: 'Company A') }
  let(:company_b) { create(:account, name: 'Company B') }

  # A Company A admin granted the 'users' settings section.
  let(:admin_a) do
    create(:user, account: company_a, role: 'admin').tap do |u|
      u.admin_permissions = ['users']
    end
  end

  before { sign_in(admin_a) }

  describe 'POST /users' do
    it 'creates the user in the admin\'s own company, ignoring an account_id param' do
      expect do
        post '/users', params: {
          user: { email: 'new.person@example.com', first_name: 'New', last_name: 'Person',
                  account_id: company_b.id }
        }
      end.to change { company_a.users.count }.by(1)

      created = User.find_by(email: 'new.person@example.com')
      expect(created.account_id).to eq(company_a.id)
      expect(created.account_id).not_to eq(company_b.id)
    end

    it 'does not allow a company admin to create a super admin' do
      post '/users', params: {
        user: { email: 'wannabe.super@example.com', first_name: 'W', last_name: 'S',
                role: 'super_admin' }
      }

      created = User.find_by(email: 'wannabe.super@example.com')
      expect(created).to be_present
      expect(created.role).not_to eq('super_admin')
    end
  end

  describe 'PATCH /users/:id' do
    it 'does not allow moving a user into another company' do
      target = create(:user, account: company_a, role: 'editor')

      patch "/users/#{target.id}", params: { user: { account_id: company_b.id } }

      expect(target.reload.account_id).to eq(company_a.id)
    end

    it 'does not allow promoting a user to super admin' do
      target = create(:user, account: company_a, role: 'editor')

      patch "/users/#{target.id}", params: { user: { role: 'super_admin' } }

      expect(target.reload.role).not_to eq('super_admin')
    end
  end
end
