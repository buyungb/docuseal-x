# SealRoute API Documentation

Complete API reference for all REST endpoints.

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

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `template_id` | integer | Yes | Template to use |
| `submitters` | array | Yes | Array of submitter objects |
| `submitters[].role` | string | Yes | Must match template role |
| `submitters[].email` | string | Yes* | Submitter email |
| `submitters[].name` | string | No | Display name |
| `submitters[].phone` | string | No | Phone (E.164 format) |
| `submitters[].send_email` | boolean | No | Send invitation email (default: true) |
| `submitters[].send_sms` | boolean | No | Send invitation SMS |
| `submitters[].external_id` | string | No | Your external identifier |
| `submitters[].metadata` | object | No | Custom key-value data |
| `submitters[].values` | object | No | Pre-fill field values |
| `submitters[].fields` | array | No | Override field settings |
| `submitters[].completed_redirect_url` | string | No | Redirect URL after signing |
| `submitters[].require_phone_2fa` | boolean | No | Require phone OTP |
| `submitters[].require_email_2fa` | boolean | No | Require email OTP |
| `order` | string | No | `preserved` (sequential) or `random` (parallel) |
| `message` | object | No | Custom email `{ subject, body }` |

### Create Submission from DOCX

```
POST /api/submissions/docx
```

Create a one-off submission from a DOCX file with embedded tags.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `documents` | array | Yes | `[{ name: "file.docx", file: "BASE64..." }]` |
| `variables` | object | No | Data variables for `[[...]]` placeholders |
| `submitters` | array | Yes | Array of submitter objects (same as above) |
| `name` | string | No | Submission name |
| `order` | string | No | `preserved` or `random` |
| `send_email` | boolean | No | Send emails |
| `logo_url` | string | No | Custom logo URL (branding) |
| `company_name` | string | No | Custom company name (branding) |
| `stamp_url` | string | No | Custom stamp image URL |
| `consent_enabled` | boolean | No | Require consent checkbox |
| `consent_document_url` | string | No | Terms URL |
| `consent_document_text` | string | No | Consent text |

**Example:**
```bash
curl -X POST https://api.sealroute.com/api/submissions/docx \
  -H "X-Auth-Token: YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Contract",
    "documents": [{"name": "contract.docx", "file": "BASE64_DATA"}],
    "variables": {"customer_name": "John Doe", "total": "1000"},
    "submitters": [{"role": "Buyer", "email": "buyer@example.com"}],
    "logo_url": "https://example.com/logo.png",
    "company_name": "My Company"
  }'
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

## Events (Webhooks)

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
