# frozen_string_literal: true

describe 'Folder permissions repro', type: :request do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:, role: 'admin') }
  let(:folder) { create(:template_folder, account:, author: owner) }

  before { sign_in(owner) }

  it 'ISSUE1: revoke an editor from an unrestricted folder, then re-list' do
    editor = create(:user, account:, role: 'editor')
    # folder is unrestricted (no permission records)
    delete "/folders/#{folder.id}/permissions/#{editor.id}"
    expect(response).to have_http_status(:no_content)

    get "/folders/#{folder.id}/permissions"
    emails = response.parsed_body.map { |u| u['email'] }
    puts "AFTER REVOKE (unrestricted start), permitted emails: #{emails.inspect}"
    expect(emails).not_to include(editor.email)
  end

  it 'ISSUE1b: grant then revoke an editor, then re-list' do
    editor = create(:user, account:, role: 'editor')
    post "/folders/#{folder.id}/permissions", params: { user_id: editor.id }
    delete "/folders/#{folder.id}/permissions/#{editor.id}"
    get "/folders/#{folder.id}/permissions"
    emails = response.parsed_body.map { |u| u['email'] }
    puts "AFTER grant+revoke, permitted emails: #{emails.inspect}"
    expect(emails).not_to include(editor.email)
  end

  it 'ISSUE1c: revoke a default-role (admin) user' do
    user = create(:user, account:) # default role = admin
    puts "default role user role=#{user.role.inspect}"
    post "/folders/#{folder.id}/permissions", params: { user_id: user.id }
    delete "/folders/#{folder.id}/permissions/#{user.id}"
    get "/folders/#{folder.id}/permissions"
    emails = response.parsed_body.map { |u| u['email'] }
    puts "AFTER grant+revoke default-role user, permitted emails: #{emails.inspect}"
  end
end
