# Requirements — Standard (Productized) Mode & Logical Company Partition

## Introduction

Today NexusSIGN is deployed as one EC2/Docker instance per agency (physical partition). Each
agency logs in on its own URL (e.g. `nexus-sign-fsm.laboredge.com`) and, because it is the only
tenant on the box, cross-company data leakage is not a concern. The product also carries a set of
healthcare/ATS ("Nexus") customizations: candidate-specific field types in the builder tray
(Candidate SSN, Candidate Permanent Address, etc.), signer-name auto-mapping, and a "Visible on
Nexus" folder toggle used by the Nexus ATS integration.

This spec defines a **productized deployment** in which a single instance serves **multiple
companies** with a **logical partition** (isolation by data, not by server) and runs a
**non-healthcare "Standard" flow** with the ATS-specific customizations stripped. The mode is
controlled by the platform Super Admin.

Two independent capabilities are specified here and are intended to ship together:

1. **Logical Company Partition** — one instance, many companies, each isolated to their own area,
   folders, sub-folders, users, and folder permissions, with no spillage across companies.
2. **Standard Mode feature set** — the productized, non-healthcare experience: candidate fields
   removed from the tray, signer name fields rendered as plain text, and the Nexus visibility
   toggle hidden.

## Glossary

| Term | Definition |
| --- | --- |
| **Platform Super Admin** | The product owner (you). Operates across all companies; manages the company roster. Distinct from a company's own admin. |
| **Company** | A logically isolated tenant. Maps to an existing `Account` record. Owns its users, folders, templates, submissions, and folder permissions. |
| **Company Admin** | An `admin`-role user scoped to a single Company. Full operational control of that Company only. |
| **Standard Mode** | Productized, non-healthcare flow. Candidate fields off, signer names as text, Nexus toggle hidden. |
| **Healthcare/ATS Mode (Nexus flow)** | The existing flow: candidate field types on, signer-name auto-mapping on, "Visible on Nexus" toggle shown. Preserved as the non-productized behavior. |
| **Mode flag** | The runtime setting, controlled by the Platform Super Admin, that selects Standard vs Healthcare/ATS behavior. |
| **Logical partition** | Isolation of companies by data scoping (`account_id` + authorization) rather than by separate servers. |
| **Candidate fields** | The healthcare/ATS custom field types: `candidatepermanentaddress1`, `candidatepermanentcity`, `candidatepermanentstate`, `candidatepermanentzip`, `candidatessn`, `candidateprimaryprofession`, `candidateprimaryspecialty`, `candidateavailablefrom`. |
| **Signer fields** | `signerfullname`, `signerfirstname`, `signerlastname`, `signerprimaryphone`, `signeremail` — auto-fillable recipient fields. |
| **Nexus visibility toggle** | The `api_visible` boolean on `template_folders`, labeled "Visible on Nexus", gating folder exposure to the Nexus ATS API. |
| **Cross-account door** | An existing feature that deliberately crosses account boundaries: linked accounts, testing accounts, and `TemplateSharing::ALL_ID`. |

## Assumptions & Decisions

- **A-1** The `Account` model is the Company unit. No new "Company" model is introduced; the
  existing `account_id` scoping is reused.
- **A-2** The mode flag is **runtime** and Super-Admin-controlled (not the boot-time
  `ENV['MULTITENANT']`). `MULTITENANT` remains an infrastructure flag and may also be enabled for a
  productized deployment, but it does not, by itself, select Standard Mode.
- **A-3** In Standard Mode, one user belongs to exactly one Company (the existing
  `users.account_id` constraint). Multi-company user access via `AccountAccess` is **not** enabled.
- **A-4** In Standard Mode, cross-account doors (linked/testing accounts, `TemplateSharing::ALL_ID`)
  are **disabled** to guarantee isolation.
- **A-5** Public signing flows (finding a template/submitter by slug/UUID for an external signer)
  are out of scope for partition changes; they are not company-admin surfaces.
- **A-6** Naming: "Nexus" continues to mean the ATS integration/healthcare flow. The productized
  mode is named **Standard** to avoid overloading "Nexus".
- **A-7 (resolves OQ-1)** The Platform Super Admin's acting-Company context is **persisted/sticky**:
  the selected Company stays in effect until explicitly switched, shown via a top-bar "Acting as"
  indicator with a switcher, plus an "Enter" action on the Company list.
- **A-8 (resolves OQ-2)** In Standard Mode the Nexus folder `api_visible` flag is a **no-op** and the
  folders API stays available; the endpoint is not removed.
- **A-9 (resolves OQ-3, revised)** Per-Company config isolation is driven **entirely by the
  runtime Standard Mode toggle** — no environment variable is required. All global-fallback config
  lookups are gated by `Docuseal.per_company_config_isolation?`, which is true whenever Standard
  Mode is on. `ENV['MULTITENANT']=true` also enables isolation but is optional and not recommended
  (it brings unrelated hosted-SaaS behavior).

---

## Requirements

### Requirement 1 — Runtime mode flag controlled by the Platform Super Admin

**User Story:** As the Platform Super Admin, I want to switch the instance between Standard
(productized, non-healthcare) and Healthcare/ATS behavior at runtime, so that I can productize
without maintaining a separate codebase.

#### Acceptance Criteria

1. WHEN the instance boots THEN the system SHALL resolve a mode value of either `standard` or
   `healthcare` from a persisted global setting, defaulting to `healthcare` (current behavior) when
   unset.
2. WHERE the current user is the Platform Super Admin THE system SHALL expose a control to read and
   change the mode.
3. WHEN a non-super-admin user attempts to read or change the mode THEN the system SHALL deny the
   action and SHALL NOT reveal the control.
4. WHEN the mode changes THEN the system SHALL apply the new behavior to subsequent requests without
   requiring a redeploy.
5. THE system SHALL expose the resolved mode to both server-side code and the template-builder
   front end so that gating decisions are consistent across layers.
6. THE mode flag SHALL be independent of `ENV['MULTITENANT']`; enabling `MULTITENANT` SHALL NOT by
   itself change the resolved mode.

### Requirement 2 — Logical company partition (data isolation)

**User Story:** As the Platform Super Admin, I want each Company's data fully isolated on a shared
instance, so that Company A can never see, view, or edit Company B's area, folders, sub-folders,
users, templates, submissions, or folder permissions.

#### Acceptance Criteria

1. WHEN any user other than the Platform Super Admin issues a request for content records
   (templates, template folders, submissions, submitters, teams, users, folder permissions,
   account configs) THEN the system SHALL restrict results to that user's own Company
   (`account_id`).
2. WHEN a Company user attempts to read, update, move, or delete a record belonging to another
   Company by direct id/slug/uuid THEN the system SHALL deny the action.
3. WHEN a Company user opens the template **Move** dialog THEN the system SHALL only list folders
   within their own Company that they are permitted to view, and SHALL never list another Company's
   folders.
4. WHEN a Company user views the Default/home area THEN the system SHALL only show their own
   Company's default folder and permitted content.
5. WHEN a Company user searches, exports, or reindexes THEN the system SHALL restrict results to
   their own Company.
6. WHEN a Company Admin creates or edits a user THEN the system SHALL force the new/edited user into
   the acting Company and SHALL reject any attempt to assign a different `account_id` via request
   parameters.
7. WHERE a per-Company configuration exists (SMTP, timeserver, trusted certs, app URL, webhook URLs)
   THE system SHALL resolve it for the acting Company and SHALL NOT fall back to "the first
   account" in a productized (partitioned) deployment.

### Requirement 3 — Access rights, roles, and permissions boundaries

**User Story:** As the Platform Super Admin, I want a clear separation between platform-level and
company-level authority, so that a Company Admin has full power within their Company but zero reach
outside it, and only I hold cross-company authority.

#### Acceptance Criteria

1. THE system SHALL distinguish Platform Super Admin authority (cross-company) from Company Admin
   authority (single company).
2. WHEN a Company Admin performs any content or settings action THEN the system SHALL scope every
   granted ability to the Company Admin's own `account_id`.
3. WHEN a Company Admin attempts to create, promote, edit, or delete a Platform Super Admin THEN the
   system SHALL deny the action.
4. WHEN a Company Admin attempts to assign the `super_admin` role to any user THEN the system SHALL
   deny the action.
5. WHERE the existing per-section admin permissions apply (Users, Folder Permissions, Teams, API,
   Data Migration, etc.) THE system SHALL continue to gate each settings section per Company Admin,
   scoped to that admin's Company.
6. WHEN the Platform Super Admin operates within the product content areas THEN the system SHALL
   provide an explicit acting-Company context so that content reads and writes are attributed to a
   single Company at a time, preventing accidental cross-company edits.
7. THE folder-permission model SHALL continue to enforce that a user/team and the folder they are
   granted on belong to the same Company.

### Requirement 4 — Company management for the Platform Super Admin

**User Story:** As the Platform Super Admin, I want to create and manage Companies and their users
from one place, so that I can onboard a new agency without provisioning a new server.

#### Acceptance Criteria

1. WHERE the current user is the Platform Super Admin THE system SHALL provide a screen to list all
   Companies.
2. WHEN the Platform Super Admin creates a Company THEN the system SHALL create the Company
   (`Account`) and its first Company Admin user, and SHALL initialize the Company's default folder.
3. WHEN the Platform Super Admin archives a Company THEN the system SHALL prevent that Company's
   users from authenticating and SHALL exclude its data from other Companies' views, without hard
   deletion.
4. WHEN a non-super-admin attempts to access Company management THEN the system SHALL deny access
   and SHALL NOT reveal the screen.
5. WHEN a Company is created THEN the system SHALL NOT route creation through the public first-run
   setup flow.
6. WHEN the Platform Super Admin creates a Company user THEN the system SHALL allow assigning that
   user to the specified Company, subject to Requirement 3.
7. THE Company list SHALL provide an "Enter" action per Company that sets the acting-Company context
   (Requirement 3.6) and lands the Platform Super Admin on that Company's home/Default area.
8. WHILE the Platform Super Admin is acting within a Company THE system SHALL display a persistent
   top-bar indicator ("Acting as: {Company}") that includes a switcher to change the acting Company
   without returning to the Company list. (Decision: OQ-1 → Option A, sticky/persisted context.)
9. THE acting-Company switcher and the "Enter" action SHALL be available only to the Platform Super
   Admin; regular Company users SHALL NOT see any switcher.

### Requirement 5 — Disable cross-account doors in a partitioned deployment

**User Story:** As the Platform Super Admin, I want cross-company sharing features turned off in the
productized deployment, so that no template or data crosses a Company boundary by design.

#### Acceptance Criteria

1. WHERE the deployment is partitioned (Standard Mode) THE system SHALL disable linked-account and
   testing-account sharing between Companies.
2. WHERE the deployment is partitioned THE system SHALL suppress `TemplateSharing::ALL_ID`
   (share-to-all-accounts) so a template is never broadcast to other Companies.
3. WHEN clone/duplicate is performed in a partitioned deployment THEN the system SHALL only permit
   cloning from a source in the same Company.
4. WHEN the Default/home shared-template view is rendered in a partitioned deployment THEN the
   system SHALL only include the acting Company's own shared templates.

### Requirement 6 — Standard Mode: remove candidate (healthcare) field types

**User Story:** As the Platform Super Admin, I want the healthcare Candidate field types removed
from the builder in the productized product, so that non-healthcare customers do not see
irrelevant fields like Candidate SSN.

#### Acceptance Criteria

1. WHERE the mode is `standard` THE system SHALL NOT offer any Candidate field type
   (`candidatepermanentaddress1`, `candidatepermanentcity`, `candidatepermanentstate`,
   `candidatepermanentzip`, `candidatessn`, `candidateprimaryprofession`,
   `candidateprimaryspecialty`, `candidateavailablefrom`) in the field tray (desktop and mobile).
2. WHERE the mode is `standard` AND a document is imported (PDF tags, AcroForm names, Sertifi/SFLD
   tags) THE system SHALL NOT create Candidate-typed fields; such fields SHALL resolve to a plain
   `text` field.
3. WHERE the mode is `healthcare` THE system SHALL continue to offer and auto-map Candidate field
   types exactly as today (no regression).
4. WHEN mode gating is applied THEN the system SHALL enforce it on the server so that Candidate
   fields cannot be created via crafted requests, not only hidden in the UI.

### Requirement 7 — Standard Mode: signer name fields as plain text

**User Story:** As the Platform Super Admin, I want signer name fields to be ordinary text boxes in
the productized product, so that the non-healthcare flow does not depend on ATS signer auto-mapping.

#### Acceptance Criteria

1. WHERE the mode is `standard` AND a document is imported THE system SHALL map "Signer First
   Name", "Signer Last Name", and "Signer Full Name" (from PDF field names, AcroForm names, and
   Sertifi/SFLD tags) to a plain `text` field rather than the `signerfirstname` / `signerlastname`
   / `signerfullname` types.
2. WHERE the mode is `standard` THE system SHALL NOT auto-fill these fields from recipient signer
   metadata; they SHALL behave as normal text inputs.
3. WHERE the mode is `healthcare` THE system SHALL preserve the current signer field mapping and
   auto-fill behavior (no regression).
4. THE decision for standard vs healthcare mapping SHALL be enforced server-side during document
   processing.

### Requirement 8 — Standard Mode: hide the Nexus visibility toggle

**User Story:** As a Company user in the productized product, I don't want to see a "Visible on
Nexus" toggle, because there is no Nexus ATS integration in the non-healthcare flow.

#### Acceptance Criteria

1. WHERE the mode is `standard` THE system SHALL hide the "Visible on Nexus" toggle on the folder
   view.
2. WHERE the mode is `standard` THE system SHALL treat folder API visibility as a no-op (the
   `api_visible` flag is ignored and the folders API remains available, returning all active
   folders). The Nexus folders API endpoint SHALL NOT be removed. (Decision: OQ-2 → Option A.)
3. WHERE the mode is `healthcare` THE system SHALL continue to show the toggle and honor
   `api_visible` (no regression).
4. WHEN a user attempts to change `api_visible` in `standard` mode THEN the system SHALL ignore or
   reject the change rather than persisting a Nexus-only setting.

### Requirement 9 — No regression for existing single-tenant agencies

**User Story:** As an existing agency on my own instance, I want the current behavior unchanged
when the productized mode is off, so that my healthcare/ATS workflows keep working.

#### Acceptance Criteria

1. WHEN the mode is unset or `healthcare` AND the deployment is single-tenant THEN the system SHALL
   behave exactly as it does today for fields, signer mapping, Nexus visibility, linked/testing
   accounts, and configuration fallback.
2. THE partition and Standard-Mode changes SHALL be additive and gated, introducing no behavioral
   change to a default single-tenant, healthcare deployment.
3. WHEN existing templates already contain Candidate or signer-typed fields AND the instance later
   runs in `standard` mode THEN the system SHALL continue to render and process those existing
   fields without data loss (gating affects creation/offering, not stored data).

---

## Out of Scope

- Billing, plans, and metered usage (the `:plan` account-config paths remain as-is).
- Public signing-page changes (slug/uuid lookups for external signers).
- Migrating existing physically-partitioned agencies onto a shared instance (data migration is a
  separate effort).
- Building a subdomain-per-company router (partition is by `account_id` + acting-company context,
  not by hostname).

## Resolved Decisions (previously open questions)

1. **OQ-1 → Resolved (Option A):** The acting-Company context is persisted/sticky, surfaced as a
   top-bar "Acting as: {Company}" indicator with a switcher, plus an "Enter" action on the Company
   list that lands on the Company's home area (Req 4.7–4.9, A-7). Regular users have no switcher.
2. **OQ-2 → Resolved (Option A):** In Standard Mode the `api_visible` flag is a no-op; the folders
   API is kept (returns all active folders) and is not removed (Req 8.2, A-8).
3. **OQ-3 → Resolved (revised):** No environment variable is required. Config isolation is driven by
   the runtime Standard Mode toggle via `Docuseal.per_company_config_isolation?` (Req 2.7, A-9).
   `MULTITENANT` is optional and not recommended.
