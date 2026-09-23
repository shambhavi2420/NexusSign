# Standard (Productized) Mode — Operations & Deployment Guide

This guide explains how to run NexusSIGN as a productized, multi-company instance
("Standard Mode") and how it differs from the existing per-agency ("Healthcare /
Nexus") deployments. It is written for the Platform Super Admin and operators.

For the full specification see the sibling files: `requirements.md`, `design.md`,
`tasks.md`.

## Concepts

- **Product mode** is a global, runtime setting with two values:
  - `healthcare` (default) — the existing Nexus/ATS flow: Candidate field types,
    signer-name auto-mapping, the "Visible on Nexus" folder toggle, and
    linked/testing-account sharing are all available. Existing agencies are
    unaffected.
  - `standard` — the productized, non-healthcare flow: Candidate fields are hidden,
    signer name fields behave as plain text, the Nexus toggle is hidden, and
    cross-company sharing doors are disabled.
- **Company** = an `Account`. One instance can host many companies, each isolated
  to its own users, folders, templates, submissions, and folder permissions.
- **Platform Super Admin** = you. A user with role `super_admin`. Manages companies
  and can act inside any company. Distinct from a **Company Admin** (role `admin`),
  who is scoped to a single company.

## Enabling Standard Mode

1. Sign in as a Platform Super Admin.
2. Go to **Settings → Product Mode**.
3. Choose **Standard (Productized)** and save.

The change takes effect immediately (no redeploy). It is stored as a global
setting on the platform account and read via `Docuseal.product_mode`.

## No environment variable required

Standard Mode is a **pure UI switch** — there is no environment variable to set
and no redeploy needed.

Some configuration lookups (SMTP, timeserver, signing/trusted certs, webhook URLs,
account configs) historically fall back to "the first account" in single-tenant
deployments. That fallback is safe with one company per box, but on a shared
instance it could let one company inherit another company's settings. Those
fallbacks are gated by `Docuseal.per_company_config_isolation?`, which is **true
whenever Standard Mode is on** — so turning on Standard Mode in the UI is by itself
enough to fully isolate per-company configuration. (`MULTITENANT=true` also enables
isolation, but it is not required and brings unrelated hosted-SaaS behavior such as
rate limiting and HTTPS-only downloads, so it is not recommended for this product.)

## Onboarding a company

1. As Platform Super Admin, go to **Settings → Companies**.
2. Click **Add Company**. Provide the company name, language, and the first
   Company Admin's name and email.
3. On save, the system creates the company (`Account`), its first Company Admin
   (role `admin`, never `super_admin`), and the company's Default folder, then
   emails the admin an invitation to set their password.

Companies are **not** created through the public first-run setup flow.

## Working inside a company (acting context)

As Platform Super Admin you can operate inside any company:

- From **Settings → Companies**, click **Enter** on a company. You land on that
  company's home area, and a top-bar banner shows **Acting as: {Company}**.
- Use the switcher in that banner to jump to another company at any time.
- Click **Exit** to return to your own platform account.

While acting inside a company, your content actions (templates, folders, users,
submissions) are scoped to that company — you cannot accidentally edit another
company's data. Regular Company Admins and users never see the switcher; they
only ever see their own company.

## Archiving a company

From **Settings → Companies**, use **Archive**. Archiving:

- Sets the company's `archived_at` and immediately prevents its users from signing
  in (existing sessions aside).
- Hides the company's data from other companies.
- Is reversible via **Restore**. It is not a hard delete.

## What changes in Standard Mode (summary)

| Area | Healthcare (default) | Standard (productized) |
| --- | --- | --- |
| Candidate field types (SSN, address, etc.) | Available in the field tray and PDF import | Hidden; PDF-imported candidate fields become plain text |
| Signer First/Last/Full Name fields | Special auto-fill signer types | Plain text boxes (no auto-fill) |
| "Visible on Nexus" folder toggle | Shown; `api_visible` honored | Hidden; `api_visible` ignored (folders API still works, returns all) |
| Linked / testing account sharing | Available | Disabled |
| Share template to all accounts (`ALL_ID`) | Available | Disabled |
| Cross-company config fallback | Legacy first-account fallback | Disabled (each company isolated) |

## Enforcement notes (for reviewers)

- Field-type stripping is enforced **server-side** (`Templates::ProductModeFieldTypes`
  applied in `FindAcroFields`, `ProcessDocument`, and `Template.create_from_pdf_tags`),
  not merely hidden in the builder UI, so candidate/signer-name fields cannot be
  created via crafted requests.
- Company isolation rides on the existing `account_id` + CanCanCan scoping; the
  super admin's acting-company context is enforced through `Ability` so even a
  super admin is scoped while acting inside a company.
- Cross-account doors are gated by `Docuseal.cross_account_sharing_allowed?` and
  config isolation by `Docuseal.per_company_config_isolation?`.

## Reverting to Healthcare Mode

Set **Settings → Product Mode** back to **Healthcare (Nexus / ATS)**. All gates
become no-ops and behavior returns to the existing agency experience. Existing
templates that already contain candidate/signer fields continue to render in both
modes; the mode only affects what is offered/created going forward.
