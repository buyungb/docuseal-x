# SealRoute API Documentation

Complete API reference for all REST endpoints. **Browse this guide on the web:** [`/api-docs`](/api-docs) (same content as this file; Markdown source lives in `docs/API.md`).

## Authentication

All API requests require the `X-Auth-Token` header (unless noted otherwise):

```
X-Auth-Token: YOUR_API_KEY
```

Get your API key from **Settings → API** or via the User Management API.

---

## User Management

### List Users

```
GET /api/users
```

Returns all active users in the account. **Admin only.**

**Response:**
```json
[
  {
    "id": 1,
    "email": "admin@example.com",
    "first_name": "John",
    "last_name": "Doe",
    "role": "admin",
    "created_at": "2026-01-01T00:00:00Z",
    "updated_at": "2026-01-01T00:00:00Z"
  }
]
```

### Get Current User

```
GET /api/user
```

Returns the authenticated user's info.

### Get User by ID

```
GET /api/users/:id
```

**Admin only.**

### Create User

```
POST /api/users
```

**Admin only.** Returns the new user with their API key.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `email` | string | Yes | User email address |
| `first_name` | string | No | First name |
| `last_name` | string | No | Last name |
| `password` | string | No | Password (auto-generated if blank) |
| `role` | string | No | `admin`, `editor`, or `viewer` (default: `admin`) |

**Example:**
```bash
curl -X POST https://api.sealroute.com/api/users \
  -H "X-Auth-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"new@example.com","first_name":"Jane","role":"editor"}'
```

**Response (201):**
```json
{
  "id": 5,
  "email": "new@example.com",
  "first_name": "Jane",
  "last_name": null,
  "role": "editor",
  "api_key": "abc123...generated_key..."
}
```

### Update User

```
PUT /api/users/:id
```

**Admin only.**

| Parameter | Type | Description |
|-----------|------|-------------|
| `email` | string | New email |
| `first_name` | string | New first name |
| `last_name` | string | New last name |
| `password` | string | New password |
| `role` | string | `admin`, `editor`, or `viewer` |

### Delete User

```
DELETE /api/users/:id
```

**Admin only.** Soft-deletes (archives) the user. Cannot delete yourself.

### Get User's API Key

```
GET /api/users/:id/api_key
```

**Admin only.**

**Response:**
```json
{
  "id": 5,
  "email": "user@example.com",
  "api_key": "abc123..."
}
```

### Regenerate User's API Key

```
POST /api/users/:id/api_key
```

**Admin only.** Generates a new API key (old key stops working immediately).

---

## Templates

### List Templates

```
GET /api/templates
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `q` | string | Search by name |
| `folder` | string | Filter by folder name |
| `archived` | boolean | Include archived templates |
| `external_id` | string | Filter by external ID |
| `limit` | integer | Max results (default 10, max 100) |
| `after` | integer | Cursor for pagination (ID) |
| `before` | integer | Cursor for pagination (ID) |

### Get Template

```
GET /api/templates/:id
```

### Update Template

```
PUT /api/templates/:id
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Template name |
| `external_id` | string | External identifier |
| `folder_name` | string | Move to folder |
| `roles` | array | Update submitter roles |
| `fields` | array | Update field definitions |
| `archived` | boolean | Archive/unarchive |

### Delete Template

```
DELETE /api/templates/:id
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `permanently` | boolean | If true, permanently delete (default: archive) |

### Clone Template

```
POST /api/templates/:template_id/clone
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Name for the clone |
| `folder_name` | string | Target folder |
| `external_id` | string | External ID for the clone |

---

## Submissions

### List Submissions

```
GET /api/submissions
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `q` | string | Search query |
| `template_id` | integer | Filter by template |
| `template_folder` | string | Filter by folder |
| `archived` | boolean | Include archived |
| `limit` | integer | Max results (default 10, max 100) |
| `after` | integer | Cursor pagination |
| `before` | integer | Cursor pagination |

### Get Submission

```
GET /api/submissions/:id
```

### Create Submission

```
POST /api/submissions
```

Create a submission from an existing template.

#### Top-Level Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `template_id` | integer | Yes | Template to use |
| `submitters` | array | Yes | Array of submitter objects (see below) |
| `order` | string | No | `preserved` (sequential) or `random` (parallel) |
| `send_email` | boolean | No | Send invitation emails (default: true) |
| `message` | object | No | Custom email `{ subject, body }` |
| `consent_enabled` | boolean | No | Require consent checkbox for all submitters |
| `consent_document_url` | string | No | Terms and conditions URL |
| `consent_document_text` | string | No | Consent checkbox label text |
| `preferences` | object | No | Template-level preferences (see [Template Preferences](#template-preferences)) |

#### Submitter-Level Parameters (`submitters[]`)

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `role` | string | Yes | Must match a role defined in the template |
| `email` | string | Yes* | Submitter email (* or `phone` required) |
| `name` | string | No | Display name |
| `phone` | string | No | Phone number (E.164 format, e.g. `+628123456789`) |
| `external_id` | string | No | Your external identifier |
| `values` | object | No | Pre-fill `{{...;type=X}}` form field values (keyed by field name) |
| `variables` | object | No | Role-scoped `[[...]]` data variables (merged with top-level `variables`) |
| `fields` | array | No | Override field settings (`[{ name, default_value, readonly, required }]`) |
| `metadata` | object | No | Custom key-value data stored with the submitter |
| `send_email` | boolean | No | Send invitation email (overrides top-level) |
| `send_sms` | boolean | No | Send invitation SMS |
| `completed_redirect_url` | string | No | Redirect URL after signing |
| `order` | integer | No | Position in signing sequence (0 = first, same number = parallel) |
| `completed` | boolean | No | Mark as pre-completed (skip signing) |
| `go_to_last` | boolean | No | Start at the last unfilled field |
| `require_phone_2fa` | boolean | No | Require phone OTP verification to access |
| `require_email_2fa` | boolean | No | Require email OTP verification to access |
| `consent_enabled` | boolean | No | Per-submitter consent override |
| `consent_document_url` | string | No | Per-submitter terms URL |
| `consent_document_text` | string | No | Per-submitter consent checkbox text |
| `reply_to` | string | No | Reply-to email address for invitation |
| `message.subject` | string | No | Custom email subject for this submitter |
| `message.body` | string | No | Custom email body for this submitter |

### Create Submission from DOCX

```
POST /api/submissions/docx
```

Create a one-off submission from a DOCX file with embedded tags. The DOCX can contain `[[variable]]` data placeholders and `{{Field;type=X}}` form field tags. See [TEMPLATE_TAGS.md](./TEMPLATE_TAGS.md) for full tag syntax.

#### Top-Level Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `documents` | array | Yes | `[{ name: "file.docx", file: "BASE64..." }]` |
| `variables` | object | No | Data variables for `[[...]]` placeholders |
| `submitters` | array | Yes | Array of submitter objects (see below) |
| `name` | string | No | Submission name |
| `order` | string | No | `preserved` (sequential) or `random` (parallel) |
| `send_email` | boolean | No | Send invitation emails (default: true) |
| `logo_url` | string | No | Custom logo URL (branding) |
| `company_name` | string | No | Custom company name (branding) |
| `stamp_url` | string | No | Custom stamp image URL for `{{stamp}}` fields |
| `consent_enabled` | boolean | No | Require consent checkbox for all submitters |
| `consent_document_url` | string | No | Terms and conditions URL |
| `consent_document_text` | string | No | Consent checkbox label text |
| `preferences` | object | No | Template-level preferences (see [Template Preferences](#template-preferences)) |

#### Submitter-Level Parameters (`submitters[]`)

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `role` | string | Yes | Must match `role=` in `{{...}}` tags |
| `email` | string | Yes* | Submitter email (* or `phone` required) |
| `name` | string | No | Display name |
| `phone` | string | No | Phone number (E.164 format, e.g. `+628123456789`) |
| `external_id` | string | No | Your external identifier |
| `values` | object | No | Pre-fill `{{...;type=X}}` form fields (keyed by field name) |
| `variables` | object | No | Role-scoped `[[...]]` variables (merged with top-level `variables`) |
| `fields` | array | No | Override field settings (`[{ name, default_value, readonly, required }]`) |
| `metadata` | object | No | Custom key-value data stored with the submitter |
| `send_email` | boolean | No | Send invitation email (overrides top-level) |
| `send_sms` | boolean | No | Send invitation SMS |
| `completed_redirect_url` | string | No | Redirect URL after signing |
| `order` | integer | No | Position in signing sequence (0 = first, same number = parallel) |
| `completed` | boolean | No | Mark as pre-completed (skip signing) |
| `go_to_last` | boolean | No | Start at the last unfilled field |
| `require_phone_2fa` | boolean | No | Require phone OTP verification to access |
| `require_email_2fa` | boolean | No | Require email OTP verification to access |
| `consent_enabled` | boolean | No | Per-submitter consent override |
| `consent_document_url` | string | No | Per-submitter terms URL |
| `consent_document_text` | string | No | Per-submitter consent checkbox text |
| `reply_to` | string | No | Reply-to email address for invitation |
| `message.subject` | string | No | Custom email subject for this submitter |
| `message.body` | string | No | Custom email body for this submitter |

#### Variables vs Values

| JSON Key | DOCX Tag | Purpose |
|----------|----------|---------|
| `variables` (top-level or `submitters[].variables`) | `[[variable_name]]` | Static text replacement before PDF generation |
| `submitters[].values` | `{{FieldName;type=X}}` | Pre-fill interactive form fields |

Top-level `variables` and each submitter's `variables` are merged into a single map. Later submitters override duplicate keys.

#### DOCX Formatting Inheritance

The API automatically extracts formatting from the DOCX and applies it to rendered fields:

| DOCX Property | Detected From | Applied As |
|---------------|---------------|------------|
| **Alignment** | `<w:jc>` (center, right) | `preferences.align` |
| **Font family** | `<w:rFonts>` (Times New Roman → Times, Arial → Helvetica) | `preferences.font` |
| **Font size** | `<w:sz>` or document defaults in `styles.xml` | `preferences.font_size` |

Explicit tag attributes (e.g., `font=Courier;font_size=14`) override DOCX formatting.

#### Template Preferences

Both `POST /api/submissions` and `POST /api/submissions/docx` accept a top-level `preferences` object that is persisted on the submission's template. These flags override account-level defaults (configured under **Settings → Personalization**) for this specific submission.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `completed_notification_email_enabled` | boolean | `true` | Send the sender a notification email when all submitters complete |
| `completed_notification_email_attach_audit` | boolean | `true` | Attach the audit log PDF to the sender's completion-notification email |
| `completed_notification_email_attach_documents` | boolean | `true` | Attach signed document PDFs to the sender's completion-notification email |
| `documents_copy_email_enabled` | boolean | `true` | Email each signer a copy of the completed documents |
| `documents_copy_email_attach_audit` | boolean | `true` | Attach the audit log PDF to the signer's copy email |
| `documents_copy_email_attach_documents` | boolean | `true` | Attach signed document PDFs to the signer's copy email |
| `submitters_order` | string | — | `preserved` (sequential) or `random` (parallel). Same effect as top-level `order`. |
| `bcc_completed` | string | — | Comma-separated BCC addresses for completion notifications |
| `require_email_2fa` | boolean | `false` | Require email OTP for every signer |
| `require_phone_2fa` | boolean | `false` | Require phone OTP (requires phone OTP webhook config) |
| `shared_link_2fa` | boolean | `false` | Require email 2FA when the signing link is shared |

Account-level toggles act as a ceiling: if e.g. `attach_audit_log` is disabled under Personalization, a template-level `true` here will not re-enable it. The audit trail PDF itself is **always generated** on completion regardless of these flags; they only control whether it is attached to outgoing emails.

#### Example

```bash
curl -X POST https://api.sealroute.com/api/submissions/docx \
  -H "X-Auth-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Contract",
    "documents": [{"name": "contract.docx", "file": "BASE64_DATA"}],
    "variables": {
      "contract_number": "C-001",
      "contract_date": "April 15, 2026"
    },
    "submitters": [
      {
        "role": "anggota",
        "email": "member@example.com",
        "phone": "+628123456789",
        "variables": {
          "Nama_Anggota": "Muhammad",
          "NRP_Anggota": "1234567890"
        }
      },
      {
        "role": "Buyer",
        "email": "buyer@example.com",
        "name": "John Doe"
      }
    ],
    "order": "preserved",
    "send_email": false,
    "logo_url": "https://example.com/logo.png",
    "company_name": "My Company",
    "preferences": {
      "completed_notification_email_attach_audit": true,
      "documents_copy_email_attach_audit": true
    }
  }'
```

**Response (200):** Array of submitter objects with signing URLs:

```json
[
  {
    "id": 1,
    "submission_id": 100,
    "role": "anggota",
    "email": "member@example.com",
    "status": "pending",
    "embed_src": "https://api.sealroute.com/s/AbCdEf..."
  },
  {
    "id": 2,
    "submission_id": 100,
    "role": "Buyer",
    "email": "buyer@example.com",
    "status": "pending",
    "embed_src": "https://api.sealroute.com/s/GhIjKl..."
  }
]
```

### Create Submission from PDF

```
POST /api/submissions/pdf
```

Create a submission from a PDF file with text tags.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `documents` | array | Yes | `[{ name: "file.pdf", file: "BASE64..." }]` |
| `submitters` | array | Yes | Submitter objects |
| `name` | string | No | Submission name |

### Delete Submission

```
DELETE /api/submissions/:id
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `permanently` | boolean | Permanently delete (default: archive) |

### Get Submission Documents

```
GET /api/submissions/:id/documents
```

Returns signed document download URLs.

| Parameter | Type | Description |
|-----------|------|-------------|
| `merge` | string | Set to `true` to get a single merged PDF |

**Response:**
```json
{
  "id": 1,
  "documents": [
    { "name": "contract.pdf", "url": "https://..." }
  ]
}
```

---

## Submitters

### List Submitters

```
GET /api/submitters
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `q` | string | Search by name/email |
| `submission_id` | integer | Filter by submission |
| `template_id` | integer | Filter by template |
| `external_id` | string | Filter by external ID |
| `slug` | string | Filter by slug |
| `completed_after` | string | Filter by completion date (ISO 8601) |
| `completed_before` | string | Filter by completion date (ISO 8601) |
| `limit` | integer | Max results |
| `after` | integer | Cursor pagination |
| `before` | integer | Cursor pagination |

### Get Submitter

```
GET /api/submitters/:id
```

### Update Submitter

```
PUT /api/submitters/:id
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `name` | string | Display name |
| `email` | string | Email address |
| `phone` | string | Phone number |
| `values` | object | Field values |
| `metadata` | object | Custom metadata |
| `send_email` | boolean | Re-send invitation email |
| `send_sms` | boolean | Re-send invitation SMS |
| `completed` | boolean | Mark as completed |
| `fields` | array | Override field settings |

---

## Tools

### Merge PDFs

```
POST /api/tools/merge
```

Merge multiple PDF files into one.

| Parameter | Type | Description |
|-----------|------|-------------|
| `files` | array | Array of base64-encoded PDF strings |

**Response:**
```json
{
  "data": "BASE64_MERGED_PDF"
}
```

### Verify PDF Signature

```
POST /api/tools/verify
```

Verify digital signatures in a PDF.

| Parameter | Type | Description |
|-----------|------|-------------|
| `file` | string | Base64-encoded PDF |

**Response:**
```json
{
  "checksum_status": "valid",
  "signatures": [...]
}
```

---

## Webhooks

Manage outgoing webhook URLs that receive HTTP POST callbacks when events occur. **Admin only.**

### Supported Events

| Event | Triggered When |
|-------|----------------|
| `form.viewed` | A submitter views the signing form |
| `form.started` | A submitter starts filling the form |
| `form.completed` | A submitter finishes signing |
| `form.declined` | A submitter declines to sign |
| `submission.created` | A new submission is created |
| `submission.completed` | All submitters have completed |
| `submission.expired` | A submission expires |
| `submission.archived` | A submission is archived |
| `template.created` | A new template is created |
| `template.updated` | A template is modified |

### List Webhooks

```
GET /api/webhooks
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `limit` | integer | Max results (default 10, max 100) |
| `after` | integer | Cursor pagination (ID) |
| `before` | integer | Cursor pagination (ID) |

**Response:**
```json
{
  "data": [
    {
      "id": 1,
      "url": "https://example.com/webhook",
      "events": ["form.completed", "submission.completed"],
      "secret": { "X-Webhook-Secret": "your_secret" },
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-01T00:00:00Z"
    }
  ],
  "pagination": { "count": 1, "next": 1, "prev": 1 }
}
```

### Get Webhook

```
GET /api/webhooks/:id
```

### Create Webhook

```
POST /api/webhooks
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `url` | string | Yes | Destination URL (receives POST requests) |
| `events` | array | No | Event types to subscribe to (default: all form events) |
| `secret` | object | No | Custom HTTP header `{ "Header-Name": "value" }` sent with each request |

**Example:**
```bash
curl -X POST https://api.sealroute.com/api/webhooks \
  -H "X-Auth-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/webhook",
    "events": ["form.completed", "submission.completed"],
    "secret": { "X-Webhook-Secret": "my_secret_token" }
  }'
```

**Response (201):**
```json
{
  "id": 1,
  "url": "https://example.com/webhook",
  "events": ["form.completed", "submission.completed"],
  "secret": { "X-Webhook-Secret": "my_secret_token" },
  "created_at": "2026-04-15T10:00:00Z",
  "updated_at": "2026-04-15T10:00:00Z"
}
```

### Update Webhook

```
PUT /api/webhooks/:id
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `url` | string | New destination URL |
| `events` | array | Replace subscribed events |
| `secret` | object | Replace secret header |

### Delete Webhook

```
DELETE /api/webhooks/:id
```

**Response:**
```json
{
  "message": "Webhook has been deleted"
}
```

### Test Webhook

```
POST /api/webhooks/:id/test
```

Sends a test `form.completed` event using the most recently completed submitter. Useful for verifying your endpoint works.

**Response:**
```json
{
  "message": "Test webhook request has been queued"
}
```

### Webhook Payload Format

When an event fires, SealRoute sends a POST request to your URL with this JSON body:

```json
{
  "event_type": "form.completed",
  "timestamp": "2026-04-15T10:30:00Z",
  "data": {
    "id": 123,
    "submission_id": 456,
    "email": "signer@example.com",
    "status": "completed",
    ...
  }
}
```

The `data` shape depends on the event type:
- **`form.*`** events include submitter details (id, email, name, status, values, documents)
- **`submission.*`** events include submission details (id, status, submitters, template)
- **`template.*`** events include template details (id, name, fields, submitters)

If a `secret` header is configured, it is included in every request for your server to verify authenticity.

---

## Events (Polling)

As an alternative to webhooks, you can poll for events.

### Form Events

```
GET /api/events/form/:type
```

List form-related events (e.g., `form.completed`).

| Parameter | Type | Description |
|-----------|------|-------------|
| `limit` | integer | Max results |
| `after` | string | Unix timestamp cursor |
| `before` | string | Unix timestamp cursor |

### Submission Events

```
GET /api/events/submission/:type
```

List submission-related events (e.g., `submission.completed`).

Same pagination parameters as form events.

---

## File Upload

### Upload Attachment

```
POST /api/attachments
```

**No authentication required** — uses submitter slug for authorization.

| Parameter | Type | Description |
|-----------|------|-------------|
| `submitter_slug` | string | Submitter's unique slug |
| `type` | string | Field type (`signature`, `initials`, `image`, etc.) |
| `file` | file | The file to upload |

---

## Pagination

List endpoints support cursor-based pagination:

```json
{
  "data": [...],
  "pagination": {
    "count": 10,
    "next": 123,
    "prev": 456
  }
}
```

Use `after` and `before` query parameters with the cursor values.

---

## Error Responses

| Status | Description |
|--------|-------------|
| `401` | Missing or invalid `X-Auth-Token` |
| `403` | Insufficient permissions (wrong role) |
| `404` | Resource not found |
| `422` | Validation error (check `error` field) |
| `429` | Rate limited |

**Error format:**
```json
{
  "error": "Description of the error"
}
```

---

## Roles & Permissions

| Role | Templates | Submissions | Users | Settings |
|------|-----------|-------------|-------|----------|
| `admin` | Full access | Full access | CRUD | Full access |
| `editor` | Own + shared | Own templates | Read only | Limited |
| `viewer` | Shared only | Shared only | Self only | None |

---

## Rate Limits

The API does not enforce hard rate limits by default, but the phone verification endpoint (`/api/send_phone_verification_code`) has a 60-second cooldown per phone number.
