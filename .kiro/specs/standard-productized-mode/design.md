# Design — Standard (Productized) Mode & Logical Company Partition

## Overview

This design turns NexusSIGN from a one-instance-per-agency product into a single instance that
serves multiple isolated Companies, running a productized non-healthcare "Standard" flow, while
preserving the existing healthcare/ATS ("Nexus") behavior for current deployments.

The design rests on four pillars, each mapping to a small, well-understood choke point in the
existing codebase rather than a rewrite:

1. **A runtime mode flag** (`ProductMode`) stored as a global setting and exposed to server + front
   end. (Req 1)
2. **Tenant isolation** built on the existing `account_id` + CanCanCan `accessible_by` scoping,
   with an explicit **acting-Company context** for the Platform Super Admin and the removal of the
   two global-fallback leak sites. (Req 2, 3)
3. **Company management** for the Platform Super Admin (list/create/archive Companies + first
   admin), reusing `Account` as the Company unit. (Req 4)
4. **Feature gating** driven by the mode flag: field-tray allow-list, PDF/AcroForm/Sertifi mapping
   fallback to `text`, cross-account-door disablement, and hiding the Nexus visibility toggle.
   (Req 5, 6, 7, 8)

The guiding principle is **gate, don't fork**: one codebase, behavior selected at runtime, with all
security-relevant decisions enforced server-side (Req 6.4, 7.4, 9.2).

## Architecture

```
                        ┌─────────────────────────────────────┐
                        │        ProductMode (global)          │
                        │  standard | healthcare (default)     │
                        │  stored as platform-level setting    │
                        └───────────────┬─────────────────────┘
                                        │ resolved at request time
          ┌─────────────────────────────┼──────────────────────────────┐
          │                             │                              │
   Server-side gating          Front-end gating (props)        Isolation layer
   - PDF/Acro/Sertifi map       - data-field-types allow-list   - accessible_by(account_id)
   - api_visible no-op          - hide Nexus toggle (erb)       - acting-company context
   - cross-account doors off                                    - no first-account fallback
          │                                                            │
          └──────────────── one Account == one Company ────────────────┘
```

### Why a runtime flag, not `ENV['MULTITENANT']`

`Docuseal.multitenant?` (`lib/docuseal.rb`) is a **boot-time** ENV flag frozen into constants
(`CONSOLE_URL`, `CDN_URL`, Puma plugins, route drawing). It also carries SaaS baggage (rate limits,
`:plan`-gated webhooks, HTTPS-only downloads, subdomain consoles) unrelated to the healthcare-vs-
standard distinction. Therefore `ProductMode` is a **separate, runtime, Super-Admin-controlled**
setting (Req 1.6, A-2). A productized deployment will *typically also* set `MULTITENANT=true` to get
per-Company config isolation (see "Global-fallback leak sites"), but the two are decoupled.

## Components and Interfaces

### 1. `ProductMode` global setting (Req 1)

**Storage.** Model it as a single global key, reusing the existing config machinery. Two viable
options; design recommends **Option A**:

- **Option A (recommended): platform `AccountConfig` key.** Add `PRODUCT_MODE_KEY = 'product_mode'`
  to `AccountConfig` (`app/models/account_config.rb`, alongside the existing `*_KEY` constants).
  Store it on the platform/first `Account`. Values: `'standard'` | `'healthcare'`. Rationale: reuses
  the existing per-key config store, migrations, and encryption-free text storage; no new table.
- **Option B: dedicated `Setting` table / ENV-overridable.** Cleaner conceptually but adds a table
  and a second config path. Deferred unless you want mode independent of any Account.

**Accessor.** Add a resolver, e.g. `Docuseal.product_mode` / `Docuseal.standard_mode?`:

```ruby
# lib/docuseal.rb (sketch)
def product_mode
  @product_mode ||= AccountConfig
    .where(key: AccountConfig::PRODUCT_MODE_KEY)
    .order(:account_id).limit(1).pick(:value) || 'healthcare'
end

def standard_mode?
  product_mode == 'standard'
end

def reset_product_mode! = (@product_mode = nil)   # called after the setting is changed
```

Because this is read on many requests, cache it in-process and bust the cache when the Super Admin
changes it (Req 1.4). (Mirrors the existing `@fulltext_search` / `@default_url_options` memoization
pattern already in `lib/docuseal.rb`.)

**Controller.** New `ProductModeController` (Super-Admin only), gated exactly like
`AdminPermissionsController` does (`before_action :authorize_super_admin` returning unless
`current_user.super_admin?`). `update` writes the AccountConfig and calls `reset_product_mode!`
(Req 1.2, 1.3).

**Front-end exposure.** Pass the mode into the template-builder mount point (see component 5) and
anywhere else the UI must react (Req 1.5).

### 2. Tenant isolation & acting-Company context (Req 2, 3)

The audit confirmed the codebase already scopes content through CanCanCan
`accessible_by(current_ability)` everywhere (templates, folders, submissions, users), and
`lib/ability.rb` already adds `account_id: user.account_id` for `admin`/`editor`/`viewer`. So for
**Company Admins the partition already holds**. The design closes three specific gaps:

#### 2a. Split Platform Super Admin from `can :manage, :all` with an acting-Company context

`lib/ability.rb` currently grants `super_admin -> can :manage, :all` (unscoped). For content
operations we introduce an **acting-Company** concept so the Super Admin operates inside one Company
at a time (Req 3.6):

- Add `current_company` resolution in `ApplicationController`. Today
  `current_account = current_user&.account`. For a Super Admin, `current_account` becomes the
  **selected acting Company** (from session), falling back to their own account when none selected.
  For everyone else it stays `current_user.account` unchanged.
- The acting-Company selector reuses the existing **impersonation-like session pattern** already
  present (`impersonates :user`, `request.session[:impersonated_user_id]`). We store
  `session[:acting_account_id]` and validate it against `Account` on each request.
- **OQ-1 → RESOLVED (Option A):** persisted/sticky session selector with an explicit
  "Acting as: {Company}" top-bar indicator, so the Super Admin can't accidentally edit the wrong
  Company. **Switching mechanism:** (a) the Company list (component 3) has an **"Enter"** action per
  Company that sets `session[:acting_account_id]` and redirects to that Company's home/Default area;
  (b) the top-bar indicator includes a **switcher** (dropdown of Companies) to change the acting
  Company from anywhere without returning to the list. Both are Super-Admin-only; regular users never
  see a switcher.

Note: The Company-management screens (component 3) intentionally operate **above** any single
Company and remain authorized by `super_admin?` directly, not by acting-Company scope.

#### 2b. Remove the two global-fallback leak sites (Req 2.7)

The only places that assume "one account" are:

- `lib/account_configs.rb`: `configs ||= Account.order(:id).first.account_configs.find_by(key:) unless Docuseal.multitenant?`
- `lib/accounts.rb`: `url ||= Account.order(:id).first.encrypted_configs.find_by(...) unless Docuseal.multitenant?` (timeserver), and similar `multitenant?` branches for signing PKCS / trusted certs / SMTP in `lib/action_mailer_configs_interceptor.rb` and `lib/webhook_urls.rb`.

These are **already guarded by `Docuseal.multitenant?`** — when `MULTITENANT=true`, each Company
resolves its own config with no first-account fallback. **OQ-3 → RESOLVED (Option A):** a
partitioned/productized deployment SHALL run with `MULTITENANT=true` so these fallbacks are off, and
the app SHALL emit a boot-time warning if `standard_mode?` is on while `MULTITENANT` is off, making
the isolation guarantee explicit.

#### 2c. Parameter-hardening on user create/edit (Req 2.6, 3.3, 3.4)

`users_controller.rb` already: builds via `current_account.users.new`, blocks non-super-admins from
assigning `super_admin`, and authorizes `Account.accessible_by(current_ability)` when an explicit
`account_id` is passed. Design keeps this and adds: in the partitioned deployment a Company Admin's
`account_id` param is ignored (forced to `current_account`), and only the Platform Super Admin may
target another Company (subject to acting-Company / explicit authorize). No new mechanism — tightening
existing checks.

#### 2d. Move dialog & folder autocomplete (Req 2.3)

`template_folders_autocomplete_controller.rb` and the move flow already filter via
`TemplateFolders.filter_active_folders(permitted_folders..., Template.accessible_by(current_ability))`
and `TemplateFolderPermissions.visible_to`. With 2a in place these are automatically Company-scoped.
Design adds a test asserting no cross-Company folder appears in the move picker.

### 3. Company management (Req 4)

New Super-Admin-only area, `CompaniesController` (or `Admin::CompaniesController`):

- `index` — list `Account.active` (all Companies) with user counts. Authorized by `super_admin?`.
- `create` — create an `Account` + first `admin` user (role `admin`, not `super_admin`), then
  `account.default_template_folder` (lazy-creator already exists on `Account`). Does **not** use the
  public `SetupController` path (Req 4.5).
- `archive`/`unarchive` — set `Account#archived_at`. `User#active_for_authentication?` already blocks
  login when `account.archived_at?` (confirmed in `app/models/user.rb`), so archiving a Company
  immediately locks out its users with no extra code (Req 4.3).

Reuses existing `Account` associations and the `active` scope. No schema change required for the
Company concept itself.

### 4. Disable cross-account doors (Req 5)

The cross-account doors identified in the audit:

- **Linked / testing accounts** — `AccountLinkedAccount`, `template_sharings_testing_controller.rb`,
  `testing_accounts_controller.rb`, `authorized_clone_account_id?` in `templates_controller.rb`
  (`true_user.account.linked_accounts.accessible_by(...)`).
- **`TemplateSharing::ALL_ID`** — broadcast-to-all in `templates_dashboard_controller.rb`
  (`shared_account_ids << TemplateSharing::ALL_ID if !Docuseal.multitenant? && !current_account.testing?`).

Design: introduce a single predicate, e.g. `Docuseal.cross_account_sharing_allowed?` = `!standard_mode?`
(and already effectively off under `multitenant?` for `ALL_ID`). Then:

- `authorized_clone_account_id?` returns true only for same-Company sources when sharing is not
  allowed (Req 5.3).
- The Default/home shared-template query omits linked/testing accounts and `ALL_ID` when sharing is
  not allowed (Req 5.2, 5.4).
- The testing-account entry points (`testing_accounts_controller`, `template_sharings_testing_controller`)
  are hidden/denied in Standard Mode (Req 5.1).

### 5. Field-tray gating — remove Candidate fields (Req 6)

**Front-end (offering).** The builder mount in `app/javascript/application.js` currently does **not**
pass `fieldTypes`, so it defaults to `[]`, which the tray components treat as "show all". The tray
components (`field_type.vue`, `fields.vue`, `mobile_fields.vue`) already gate each entry with
`v-if="fieldTypes.includes(type) || ..."`. So the change is purely additive:

- Render the mode into the `<template-builder>` element as a data attribute, e.g.
  `data-field-types="<allow-list>"` when `Docuseal.standard_mode?`.
- In `application.js`, parse it: `fieldTypes: (this.dataset.fieldTypes || '').split(',').filter(Boolean)`.
- The Standard allow-list = all standard types + signer types **excluding** the 8 candidate types.
  With a non-empty `fieldTypes`, `fieldIconsSorted` already restricts the tray to exactly that list.

No edits to the Vue tray logic itself — we only supply the prop that the components already honor.

**Server-side (enforcement, Req 6.4).** Offering is not enough; creation must be blocked. Gate the
three mapping tables so Candidate types are never produced in Standard Mode:

- `lib/pdf_field_parser.rb` — `SERTIFI_TAG_MAPPINGS` candidate entries fall back to `{ type: 'text' }`.
- `lib/templates/find_acro_fields.rb` — `CUSTOM_FIELD_NAME_TO_TYPE` candidate entries fall back to `text`.
- `lib/templates/process_document.rb` — `FIELD_NAME_MAPPINGS` candidate patterns → `text`.

Implement as a mode-aware filter applied where these constants are consumed (a helper that, in
Standard Mode, rewrites any `candidate*` mapped type to `text`), keeping the constants themselves
intact for Healthcare Mode (Req 6.3). Existing stored candidate fields still render (Req 9.3), since
gating affects creation/offering, not stored schema.

### 6. Signer name fields as plain text (Req 7)

Same three mapping sites. In Standard Mode, `signerfullname` / `signerfirstname` / `signerlastname`
resolve to `{ type: 'text' }` and skip the auto-fill path (`Submitters::MaybeUpdateDefaultValues`
only acts on the special signer types, so mapping to `text` inherently disables auto-fill — Req 7.2).
Healthcare Mode unchanged (Req 7.3). Enforced server-side during document processing (Req 7.4).

Design detail: extend the same mode-aware mapping filter from component 5 so a single function
handles both "candidate → text" and "signer-name → text", keeping the logic in one place.

### 7. Hide the Nexus visibility toggle (Req 8)

- **View:** `app/views/template_folders/show.html.erb` wraps the "Visible on Nexus" toggle
  (`t('visible_on_nexus')`, `template_folder[api_visible]`) in `unless Docuseal.standard_mode?`.
- **Controller:** `template_folders_controller.rb#update` currently branches on
  `params[:template_folder]&.key?('api_visible')`. In Standard Mode, ignore/reject the `api_visible`
  param (Req 8.4).
- **API scope:** `api/folders_controller.rb` uses `.api_visible`. **OQ-2 → RESOLVED (Option A):**
  make the `api_visible` scope a **no-op** in Standard Mode — redefine it to ignore the flag when
  `Docuseal.standard_mode?` so the folders API stays available and returns all active folders. The
  endpoint is **not** removed.

## Data Models

No new tables required.

- **`ProductMode`**: stored as an `AccountConfig` row (`key = 'product_mode'`), Option A. If Option B
  is chosen later, a `settings` table would be added; not in this design.
- **Company**: `Account` (existing). Archival via existing `archived_at`.
- **Acting-Company context**: `session[:acting_account_id]` (no DB).

All isolation continues to ride on the existing `account_id` columns and unique indexes documented in
`db/schema.rb`.

## Error Handling

- **Authorization failures** reuse the existing `rescue_from CanCan::AccessDenied` → redirect to
  root with alert (`application_controller.rb`). Company-management and mode controllers add explicit
  `super_admin?` guards returning `not_authorized` (mirrors `AdminPermissionsController`).
- **Invalid acting-Company**: if `session[:acting_account_id]` references a missing/archived Account,
  clear it and fall back to the Super Admin's own account.
- **Mode read failure / unset**: default to `'healthcare'` (no regression, Req 9.1).
- **Param tampering** (`account_id`, `api_visible`, candidate/signer types): server rejects/ignores
  rather than trusting the client (Req 2.6, 6.4, 7.4, 8.4).

## Testing Strategy

- **Model/lib unit tests**: `Docuseal.product_mode`/`standard_mode?` resolution + caching/reset; the
  mode-aware mapping filter (candidate→text, signer-name→text) for all three mapping sources; the
  `api_visible` no-op scope; `cross_account_sharing_allowed?`.
- **Request/controller tests**: mode controller super-admin gating; company management create/archive
  and login lockout after archive; user-create `account_id` hardening; move-dialog/autocomplete
  cross-Company exclusion; Default/home excludes linked/`ALL_ID` in Standard Mode.
- **Isolation tests (Req 2)**: Company A user cannot read/update/move/delete Company B records by
  id/slug/uuid; search/export scoped.
- **Regression tests (Req 9)**: with mode `healthcare` + single-tenant, candidate fields offered,
  signer mapping/auto-fill intact, Nexus toggle shown, linked/testing accounts work, config fallback
  unchanged.
- **Front-end**: builder receives `data-field-types` and the tray hides candidate types in Standard
  Mode; existing templates with candidate fields still render.
- Use the existing RSpec setup (`spec/rails_helper.rb`), including the `multitenant: true` helper to
  exercise the partitioned config paths.

## Traceability

| Requirement | Design component |
| --- | --- |
| 1 Runtime mode flag | Component 1 (`ProductMode`, controller, caching, FE exposure) |
| 2 Logical partition | Component 2a–2d (acting-Company, fallback removal, param-hardening, move dialog) |
| 3 Access/roles boundaries | Component 2a, 2c; Company mgmt authorization |
| 4 Company management | Component 3 |
| 5 Cross-account doors off | Component 4 |
| 6 Remove candidate fields | Component 5 (FE allow-list + server mapping filter) |
| 7 Signer names as text | Component 6 (server mapping filter, auto-fill disabled) |
| 8 Hide Nexus toggle | Component 7 (view + controller + api scope) |
| 9 No regression | Defaults to `healthcare`; all gating additive; testing strategy |

## Resolved Decisions (previously open questions)

- **OQ-1 → Option A:** Persisted/sticky acting-Company context. Switching via an "Enter" action on
  the Company list (lands on the Company's home area) and a top-bar "Acting as" switcher available
  everywhere. Super-Admin-only.
- **OQ-2 → Option A:** No-op `api_visible` scope in Standard Mode; the folders API is retained.
- **OQ-3 → REVISED:** No env var required. Config isolation is driven entirely by the runtime
  Standard Mode toggle via `Docuseal.per_company_config_isolation?` (gates all six global-fallback
  sites: account_configs, timeserver, signing pkcs, trusted certs, SMTP interceptor, webhook URLs).
  `MULTITENANT` is optional and not recommended (SaaS baggage). The boot-time warning was removed.
