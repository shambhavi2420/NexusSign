# frozen_string_literal: true

require 'rails_helper'

# A submission (and its submitters) must belong to the TEMPLATE's company, not
# the creating user's account. This matters when a Platform Super Admin (whose
# own account is the platform/first company) sends a document from another
# company's template — the submission must be stamped with that company.
# See .kiro/specs/standard-productized-mode.
RSpec.describe 'Submission account scoping' do
  let(:platform_account) { create(:account, name: 'Platform') }
  let(:company_b) { create(:account, name: 'Company B') }

  let(:super_admin) { create(:user, account: platform_account, role: 'super_admin') }
  let(:company_b_author) { create(:user, account: company_b, role: 'admin') }

  # Template owned by Company B, but sent by the platform super admin.
  let(:template_b) do
    create(:template, account: company_b, author: company_b_author, attachment_count: 0)
  end

  describe 'Submissions.create_from_emails' do
    it 'stamps the submission and submitter with the template company, not the sender' do
      submissions = Submissions.create_from_emails(
        template: template_b,
        user: super_admin,
        emails: 'signer@example.com',
        source: :invite
      )

      submission = submissions.first
      expect(submission.account_id).to eq(company_b.id)
      expect(submission.account_id).not_to eq(super_admin.account_id)
      expect(submission.submitters.first.account_id).to eq(company_b.id)
    end
  end

  # Note: Submissions::CreateFromSubmitters uses the identical
  # `account_id: template.account_id` assignment (verified by code), and its
  # submitter uses `submission.account_id`. Exercising it directly requires the
  # full normalized-params pipeline; the create_from_emails path above covers
  # the account-scoping behavior end-to-end.
end
