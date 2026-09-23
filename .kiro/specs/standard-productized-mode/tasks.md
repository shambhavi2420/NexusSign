# Implementation Plan — Standard (Productized) Mode & Logical Company Partition

Tasks are ordered so each builds on the previous and can be tested in isolation. Every task cites
the requirements it satisfies. Foundational, low-risk pieces (the mode flag) come first; the
security-sensitive isolation work is staged with tests before the feature gating.

> Convention: `[ ]` not started. Sub-bullets are the concrete edits/tests for that task.

---

- [x] 1. Introduce the `ProductMode` runtime flag (foundation)
  - Add `PRODUCT_MODE_KEY = 'product_mode'` to `app/models/account_config.rb` alongside existing keys.
  - Add `Docuseal.product_mode`, `Docuseal.standard_mode?`, and `Docuseal.reset_product_mode!` to
    `lib/docuseal.rb`, memoized like `@fulltext_search`, defaulting to `'healthcare'` when unset.
  - Unit tests: unset → `healthcare`; set to `standard` → `standard`; reset busts the cache.
  - _Requirements: 1.1, 1.6, 9.1_

- [x] 2. Super-Admin control to read/change the mode
  - Add `ProductModeController` (`show`/`update`) gated by `authorize_super_admin` (mirror
    `AdminPermissionsController`); `update` writes the AccountConfig and calls `reset_product_mode!`.
  - Add route under `/settings` (super-admin only) and a minimal settings UI entry.
  - Request tests: super admin can read/update; non-super-admin is denied and cannot see the control.
  - _Requirements: 1.2, 1.3, 1.4_

- [x] 3. Expose the resolved mode to the front end
  - Pass mode into the `<template-builder>` element (new `data-*` attribute) from the builder view.
  - Confirm any other UI that must react can read the mode (helper method).
  - _Requirements: 1.5_

- [x] 4. ~~Boot-time coupling assertion~~ — REMOVED (superseded)
  - Originally warned when Standard Mode ran without `MULTITENANT`. Removed after the decision to make
    Standard Mode fully UI-driven: `Docuseal.per_company_config_isolation?` (= standard_mode? ||
    multitenant?) enables config isolation from the UI toggle alone, so no env var and no warning are
    needed. The initializer and its spec were deleted.
  - _Requirements: 2.7_

- [x] 5. Isolation test harness (write tests before hardening)
  - Add cross-Company isolation specs: Company A user cannot read/update/move/delete Company B
    records by id/slug/uuid; search/export scoped to own Company.
  - These start red where gaps exist and turn green as tasks 6–8 land.
  - _Requirements: 2.1, 2.2, 2.5_

- [x] 6. Acting-Company context + switcher for the Platform Super Admin (persisted/sticky — Option A)
  - Add `session[:acting_account_id]` resolution; make `current_account` return the acting Company
    for a super admin (fallback to own account), unchanged for everyone else.
  - Validate the session value against `Account` each request; clear if missing/archived.
  - Add a persistent top-bar "Acting as: {Company}" indicator with a switcher dropdown (Super-Admin
    only; hidden for regular users).
  - Add an "Enter" action (used by the Company list, Task 10) that sets the acting Company and
    redirects to that Company's home/Default area.
  - Tests: super admin content reads/writes attributed to the acting Company; switch changes context;
    invalid id falls back; regular users see no switcher.
  - _Requirements: 3.1, 3.6, 2.1, 4.7, 4.8, 4.9_

- [x] 7. Remove global-fallback leak sites under partition
  - In `lib/account_configs.rb` and `lib/accounts.rb` (and the SMTP/webhook branches in
    `lib/action_mailer_configs_interceptor.rb`, `lib/webhook_urls.rb`), ensure the
    `Account.order(:id).first` fallback is off for a partitioned deployment (guarded by
    `multitenant?` and/or `standard_mode?`).
  - Tests (use `multitenant: true` helper): each Company resolves its own config; no first-account
    bleed-through.
  - _Requirements: 2.7_

- [x] 8. Harden user create/edit account scoping
  - Ensure a Company Admin's `account_id` param is ignored (forced to `current_account`); only the
    Platform Super Admin may target another Company (subject to acting-Company/authorize).
  - Keep existing super-admin-role assignment block and super-admin-protection rules.
  - Tests: Company Admin cannot create a user in another Company or assign `super_admin`.
  - _Requirements: 2.6, 3.2, 3.3, 3.4, 3.5, 3.7_

- [x] 9. Move dialog & folder autocomplete cross-Company exclusion
  - Verify `template_folders_autocomplete_controller.rb` and the move flow list only own-Company,
    permitted folders under the acting-Company context.
  - Test: no cross-Company folder appears in the move picker.
  - _Requirements: 2.3_

- [x] 10. Company management screens (Super-Admin only)
  - Add `CompaniesController`: `index` (list `Account.active` + user counts, each row with an
    "Enter" action wired to the acting-Company context from Task 6), `create`
    (Account + first `admin` user + default folder, NOT via `SetupController`), `archive`/`unarchive`
    (toggle `archived_at`).
  - Routes gated by `super_admin?`.
  - Tests: create yields a working Company + admin; "Enter" lands on that Company's home; archive
    locks out login (`User#active_for_authentication?`); non-super-admin denied and screen hidden.
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7_

- [x] 11. Disable cross-account doors in Standard Mode
  - Add `Docuseal.cross_account_sharing_allowed?` (= `!standard_mode?`).
  - Gate `authorized_clone_account_id?` (same-Company only), the Default/home shared-template query
    (omit linked/testing + `TemplateSharing::ALL_ID`), and hide/deny testing-account entry points
    (`testing_accounts_controller`, `template_sharings_testing_controller`).
  - Tests: in Standard Mode no cross-Company template appears in Default/home; clone from another
    Company denied.
  - _Requirements: 5.1, 5.2, 5.3, 5.4_

- [x] 12. Mode-aware field mapping filter (server enforcement core)
  - Add a single helper that, in Standard Mode, rewrites any mapped `candidate*` type and any
    `signerfullname`/`signerfirstname`/`signerlastname` type to `text`.
  - Apply it where these constants are consumed in `lib/pdf_field_parser.rb`
    (`SERTIFI_TAG_MAPPINGS`), `lib/templates/find_acro_fields.rb` (`CUSTOM_FIELD_NAME_TO_TYPE`), and
    `lib/templates/process_document.rb` (`FIELD_NAME_MAPPINGS`). Leave constants intact for
    Healthcare Mode.
  - Unit tests per source: Standard → `text`; Healthcare → candidate/signer types (no regression).
  - _Requirements: 6.2, 6.3, 6.4, 7.1, 7.3, 7.4_

- [x] 13. Field-tray allow-list in the builder (offering)
  - Render `data-field-types=<standard allow-list>` (all standard + signer types, excluding the 8
    candidate types) when `standard_mode?`; parse it in `app/javascript/application.js`
    (`fieldTypes: (this.dataset.fieldTypes || '').split(',').filter(Boolean)`).
  - No changes to `field_type.vue` / `fields.vue` / `mobile_fields.vue` logic (they already honor
    `fieldTypes`).
  - Tests/manual check: candidate types absent from desktop + mobile tray in Standard Mode; all
    present in Healthcare Mode; existing candidate fields still render.
  - _Requirements: 6.1, 7.2, 9.3_

- [x] 14. Hide the Nexus visibility toggle & neutralize `api_visible`
  - Wrap the "Visible on Nexus" toggle in `app/views/template_folders/show.html.erb` with
    `unless Docuseal.standard_mode?`.
  - In `template_folders_controller.rb#update`, ignore/reject the `api_visible` param in Standard Mode.
  - Make `TemplateFolder.api_visible` scope a no-op in Standard Mode (per OQ-2 recommendation) so
    `api/folders_controller.rb` returns all active folders.
  - Tests: toggle hidden and `api_visible` unchanged in Standard Mode; shown/honored in Healthcare Mode.
  - _Requirements: 8.1, 8.2, 8.3, 8.4_

- [x] 15. Regression pass for default single-tenant healthcare deployment
  - Full run with mode unset/`healthcare` + single-tenant: candidate fields offered, signer
    mapping/auto-fill intact, Nexus toggle shown/honored, linked/testing accounts work, config
    fallback unchanged.
  - _Requirements: 9.1, 9.2, 9.3_

- [x] 16. Documentation & deployment notes
  - Document how to enable Standard Mode (super-admin control), the recommended `MULTITENANT=true`
    coupling, and the Company onboarding flow.
  - _Requirements: 1, 4 (operational support)_

---

## Sequencing notes

- Tasks 1–4 are safe, additive foundation and can merge independently.
- Task 5 (tests first) intentionally precedes 6–9 so the isolation guarantees are demonstrated, not
  assumed.
- Tasks 12–14 are the visible "Standard Mode" behavior; 12 (server) must land with or before 13
  (UI) so gating can never be bypassed by the client.
- Task 15 is the regression gate before shipping.

## Decisions (confirmed — no longer blocking)

- **OQ-1 → Option A** (Tasks 6, 10): persisted/sticky acting-Company context with a top-bar switcher
  and an "Enter" action on the Company list that lands on the Company home area.
- **OQ-2 → Option A** (Task 14): `api_visible` no-op scope; the Nexus folders API is retained.
- **OQ-3 → REVISED** (Tasks 4, 7): No env var required. Config isolation is fully driven by the
  runtime Standard Mode toggle (`per_company_config_isolation?`). `MULTITENANT` optional, not
  recommended. Boot-time warning removed.
