# DocuSeal Template Tags Documentation

This document describes the templating tag system used in DocuSeal for creating dynamic documents with form fields and data placeholders.

## Overview

DocuSeal supports two types of tags:

| Tag Type | Syntax | Purpose | When Processed |
|----------|--------|---------|----------------|
| **Data Variables** | `[[variable_name]]` | Replaced with data values | Before PDF generation |
| **Form Fields** | `{{FieldName;type=X;options}}` | Interactive form fields for signing | During signing |

### Key Difference

- **`[[...]]`** = Data placeholder → Replaced with values from `variables` object
- **`{{...;type=X}}`** = Form field → Becomes interactive field for signers

**Important:** Form field tags MUST include `type=` to be recognized as interactive fields.

---

## Form Field Tags `{{...}}`

Form field tags create interactive fields that signers can fill out. These tags are processed during PDF generation and converted into actual form fields.

### Basic Syntax

```
{{FieldName;type=fieldtype;role=RoleName;required=true}}
```

### Components

| Component | Required | Description |
|-----------|----------|-------------|
| `FieldName` | Yes | Unique identifier for the field (e.g., `BuyerSign`, `CustomerName`) |
| `type` | No | Field type (default: `text`) |
| `role` | No | Assigns field to a specific signer role |
| `required` | No | Whether the field must be filled (`true`/`false`) |

### Field Types

| Type | Description | Example |
|------|-------------|---------|
| `signature` | Signature capture field | `{{BuyerSign;type=signature;role=Buyer}}` |
| `initials` | Initials field | `{{BuyerInit;type=initials;role=Buyer}}` |
| `text` | Single-line text input | `{{CustomerName;type=text;role=Buyer}}` |
| `date` | Date picker field | `{{SignDate;type=date;role=Buyer}}` |
| `datenow` | Auto-filled current date | `{{BuyerDate;type=datenow;role=Buyer}}` |
| `checkbox` | Checkbox field | `{{AgreeTerms;type=checkbox;role=Buyer}}` |
| `number` | Numeric input | `{{Quantity;type=number;role=Buyer}}` |
| `phone` | Phone number input | `{{PhoneNumber;type=phone;role=Buyer}}` |
| `email` | Email input | `{{EmailAddress;type=email;role=Buyer}}` |
| `image` | Image upload field | `{{Photo;type=image;role=Buyer}}` |
| `stamp` | Stamp/seal field | `{{CompanyStamp;type=stamp;role=Seller}}` |
| `payment` | Payment field | `{{Payment;type=payment;role=Buyer}}` |
| `file` | File attachment | `{{Attachment;type=file;role=Buyer}}` |
| `cells` | Multiple character cells | `{{Code;type=cells;role=Buyer}}` |

### Role Assignment

Roles determine which signer is responsible for filling a field. Common roles:

```
{{BuyerSign;type=signature;role=Buyer}}
{{SellerSign;type=signature;role=Seller}}
{{WitnessSign;type=signature;role=Witness}}
```

**Multiple Signers Example:**
```
BUYER SECTION
{{BuyerSign;type=signature;role=Buyer;required=true}}
Name: {{BuyerName;type=text;role=Buyer}}
Date: {{BuyerDate;type=datenow;role=Buyer}}

SELLER SECTION
{{SellerSign;type=signature;role=Seller;required=true}}
Name: {{SellerName;type=text;role=Seller}}
Date: {{SellerDate;type=datenow;role=Seller}}
```

### Complete Field Examples

```
# Signature (required)
{{BuyerSign;type=signature;role=Buyer;required=true}}

# Text field
{{CustomerName;type=text;role=Buyer}}

# Auto-date
{{SignedDate;type=datenow;role=Buyer}}

# Initials
{{BuyerInitials;type=initials;role=Buyer}}

# Checkbox
{{AcceptTerms;type=checkbox;role=Buyer;required=true}}
```

---

## Data Placeholder Tags `[[...]]`

Data placeholders are replaced with actual values when the document is generated. These are NOT form fields - they display pre-filled data.

### Basic Syntax

```
[[variable_name]]
```

### Common Placeholders

```
Contract Number: [[contract_number]]
Date: [[contract_date]]
Customer: [[customer_name]]
Company: [[company_name]]
Address: [[customer_address]]
Email: [[customer_email]]
Total: $[[total]]
```

### Nested/Object Placeholders

Access nested data using dot notation:

```
Product: [[item.name]]
Price: $[[item.unit_price]]
Quantity: [[item.quantity]]
```

---

## Control Flow Tags

### Loops `[[for:items]]...[[end]]`

Repeat content for each item in a collection. DocuSeal supports two types of loops:

#### 1. Paragraph Loops (Regular Text)

For repeating paragraphs or text blocks:

```
[[for:items]]
Product: [[item.name]]
Description: [[item.description]]
Quantity: [[item.quantity]]
Unit Price: $[[item.unit_price]]
Subtotal: $[[item.subtotal]]

[[end]]
```

**Output (with 2 items):**
```
Product: Enterprise Software License
Description: Annual subscription
Quantity: 1
Unit Price: $15,000.00
Subtotal: $15,000.00

Product: Professional Training
Description: 2-day on-site training
Quantity: 1
Unit Price: $2,500.00
Subtotal: $2,500.00
```

#### 2. Table Row Loops

For repeating rows in a Word table - the entire table row (`<w:tr>`) is duplicated for each item:

| Product | Qty | Price | Subtotal |
|---------|-----|-------|----------|
| [[item.name]] | [[item.quantity]] | $[[item.unit_price]] | $[[item.subtotal]] |

[[for:items]] [[end]]

**Note:** For table loops, place the item accessors in a single row. The `[[for:items]]` and `[[end]]` tags can be outside the table or in separate rows.

### Loop Syntax Rules

| Rule | Correct | Incorrect |
|------|---------|-----------|
| Loop variable | `[[for:items]]` (plural) | `[[for:item]]` |
| Item accessor | `[[item.name]]` (singular) | - |
| Alternative | `[[items.name]]` also works | - |
| Closing tag | `[[end]]` or `[[end:items]]` | Missing `[[end]]` |

### API Data Structure for Loops

```json
{
  "variables": {
    "items": [
      {
        "name": "Product A",
        "description": "First product",
        "quantity": "2",
        "unit_price": "100.00",
        "subtotal": "200.00"
      },
      {
        "name": "Product B",
        "description": "Second product",
        "quantity": "1",
        "unit_price": "150.00",
        "subtotal": "150.00"
      }
    ]
  }
}
```

### Complete Loop Example

**Template:**
```
ORDER DETAILS

[[for:items]]
┌─────────────────────────────────────────┐
│ Product: [[item.name]]                  │
│ Description: [[item.description]]       │
│ Quantity: [[item.quantity]]             │
│ Price: $[[item.unit_price]]             │
│ Subtotal: $[[item.subtotal]]            │
└─────────────────────────────────────────┘
[[end]]

TOTAL: $[[total]]
```

**Output:**
```
ORDER DETAILS

┌─────────────────────────────────────────┐
│ Product: Product A                      │
│ Description: First product              │
│ Quantity: 2                             │
│ Price: $100.00                          │
│ Subtotal: $200.00                       │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ Product: Product B                      │
│ Description: Second product             │
│ Quantity: 1                             │
│ Price: $150.00                          │
│ Subtotal: $150.00                       │
└─────────────────────────────────────────┘

TOTAL: $350.00
```

### Empty Loop Handling

If the `items` array is empty or not provided, the entire loop block is removed from the output.

### Conditionals `[[if:condition]]...[[end]]`

Show content only when condition is true:

```
[[if:has_discount]]
Discount ([[discount_percent]]%): -$[[discount_amount]]
[[end]]
```

### If-Else

```
[[if:payment_installment]]
Payment Plan: [[installment_count]] monthly payments of $[[installment_amount]]
[[else]]
Payment Due: Net [[payment_days]] days from contract date
[[end]]
```

---

## Template Examples

### Simple Contract Template

```
CONTRACT AGREEMENT

Contract Number: [[contract_number]]
Date: [[contract_date]]

---

PARTIES

Seller: [[company_name]]
Address: [[company_address]]

Buyer: [[customer_name]]
Company: [[customer_company]]
Email: [[customer_email]]

---

ORDER DETAILS

[[for:items]]
Product: [[item.name]]
Description: [[item.description]]
Quantity: [[item.quantity]]
Unit Price: $[[item.unit_price]]
Subtotal: $[[item.subtotal]]
[[end]]

---

PRICING

Subtotal: $[[subtotal]]
[[if:has_discount]]
Discount ([[discount_percent]]%): -$[[discount_amount]]
[[end]]
Tax ([[tax_rate]]%): $[[tax_amount]]
TOTAL: $[[total]]

---

SIGNATURES

Buyer Signature: {{BuyerSign;type=signature;role=Buyer;required=true}}
Buyer Name: {{BuyerName;type=text;role=Buyer}}
Date: {{BuyerDate;type=datenow;role=Buyer}}

Seller Signature: {{SellerSign;type=signature;role=Seller;required=true}}
Seller Name: {{SellerName;type=text;role=Seller}}
Date: {{SellerDate;type=datenow;role=Seller}}
```

### NDA Template Example

```
NON-DISCLOSURE AGREEMENT

This Agreement is entered into as of [[effective_date]]

BETWEEN:
[[disclosing_party_name]] ("Disclosing Party")
AND:
[[receiving_party_name]] ("Receiving Party")

---

CONFIDENTIAL INFORMATION

The Receiving Party agrees to:
{{AcceptTerms;type=checkbox;role=Receiver;required=true}} Keep all information confidential
{{AcceptDuration;type=checkbox;role=Receiver;required=true}} Maintain confidentiality for [[duration_years]] years

---

SIGNATURES

Disclosing Party:
{{DiscloserSign;type=signature;role=Discloser;required=true}}
Name: {{DiscloserName;type=text;role=Discloser}}
Date: {{DiscloserDate;type=datenow;role=Discloser}}

Receiving Party:
{{ReceiverSign;type=signature;role=Receiver;required=true}}
Name: {{ReceiverName;type=text;role=Receiver}}
Date: {{ReceiverDate;type=datenow;role=Receiver}}
```

---

## Best Practices

### Field Naming

1. **Use descriptive names**: `BuyerSignature` instead of `sig1`
2. **Include role in name**: `BuyerName`, `SellerName` for clarity
3. **Be consistent**: Use same naming pattern throughout
4. **Avoid spaces**: Use camelCase or underscores

### Role Assignment

1. **Define clear roles**: `Buyer`, `Seller`, `Witness`, `Notary`
2. **Match API submitters**: Role names should match submitter roles in API calls
3. **One role per signer**: Each signer should have a distinct role

### Layout Tips

1. **Position tags where fields should appear**: Tags are replaced with form fields at their exact location
2. **Leave enough space for signatures**: Signature fields need vertical space
3. **Align related fields**: Group fields by signer for better UX

### Common Patterns

**Two-Party Signature Block:**
```
BUYER                                    SELLER
─────────────────────────                ─────────────────────────

{{BuyerSign;type=signature;role=Buyer}}  {{SellerSign;type=signature;role=Seller}}

Name: {{BuyerName;type=text;role=Buyer}} Name: {{SellerName;type=text;role=Seller}}

Date: {{BuyerDate;type=datenow;role=Buyer}} Date: {{SellerDate;type=datenow;role=Seller}}
```

**Required Field Indicator:**
```
* Required fields

Signature*: {{Sign;type=signature;role=Signer;required=true}}
Name*: {{Name;type=text;role=Signer;required=true}}
Phone: {{Phone;type=phone;role=Signer}}
```

---

## API Integration

When submitting documents via API, the submitters' roles must match the roles defined in the template:

```json
{
  "template_id": 123,
  "submitters": [
    {
      "role": "Buyer",
      "email": "buyer@example.com",
      "name": "John Doe"
    },
    {
      "role": "Seller", 
      "email": "seller@example.com",
      "name": "Jane Smith"
    }
  ]
}
```

---

## How Tag Processing Works (Two-PDF Approach)

When a DOCX template with `{{...}}` tags is submitted, DocuSeal uses a sophisticated two-PDF approach:

### Processing Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DOCX SUBMISSION FLOW                              │
└─────────────────────────────────────────────────────────────────────────┘

1. DOCX with Tags ──────┬──────────────────────────────────────────────────
                        │
                        ├──► [PDF 1: Tagged]     ──► Tag Position Detection
                        │    (Contains {{tags}})     Using Pdfium to find
                        │                            exact X,Y coordinates
                        │
                        └──► [PDF 2: Clean]      ──► Final Document
                             (Tags Removed)          Form fields placed
                                                     at detected positions
```

### Step-by-Step Process

1. **Variable Substitution**: `[[...]]` placeholders are replaced with data values
2. **Tagged PDF Generation**: DOCX (with `{{...}}` tags) is converted to PDF via Gotenberg
3. **Tag Position Detection**: Pdfium parses the tagged PDF to find exact coordinates of each `{{...}}` tag
4. **Clean PDF Generation**: Tags are removed from the DOCX, then converted to a clean PDF
5. **Field Placement**: Form fields are placed on the clean PDF at positions detected from the tagged PDF

### Why Two PDFs?

- **Tagged PDF**: Used only for detecting where tags appear in the document
- **Clean PDF**: The final document users see, with invisible form fields at correct positions
- **Result**: Users see a professional document with form fields, not visible tag text

---

## Troubleshooting

### Tags Not Being Detected

1. **Check syntax**: Ensure double braces `{{` and `}}`
2. **No spaces in tag**: `{{FieldName}}` not `{{ FieldName }}`
3. **Valid field type**: Use supported types listed above
4. **Check tag format**: Use semicolons to separate options: `{{Name;type=text;role=Buyer}}`

### Tags Still Visible in PDF

1. **Check server logs**: Look for "DOCX TAG REMOVAL" log entries
2. **Verify tag format**: Tags must be `{{name;type=X}}` format
3. **Check encoding**: Ensure DOCX uses standard UTF-8 encoding
4. **Avoid special characters**: Don't use Unicode curly braces (use standard `{` and `}`)

### Field Position Issues

1. **Tags may be hyphenated**: Word processors can split tags across lines
2. **Use simple fonts**: Complex formatting can interfere with tag detection
3. **Keep tags on single line**: Avoid line breaks within a tag
4. **Check PDF conversion**: Ensure Gotenberg service is running correctly

---

## Reference

### All Supported Field Types

| Type | Input | Output |
|------|-------|--------|
| `text` | Text box | String value |
| `signature` | Drawing pad | Signature image |
| `initials` | Small drawing pad | Initials image |
| `date` | Date picker | Date string |
| `datenow` | Auto-filled | Current date |
| `checkbox` | Checkbox | Boolean |
| `number` | Number input | Numeric value |
| `phone` | Phone input | Phone string |
| `email` | Email input | Email string |
| `image` | Image upload | Image |
| `stamp` | Stamp selector | Stamp image |
| `file` | File upload | Attachment |
| `cells` | Character boxes | String |
| `payment` | Payment form | Payment info |

### Tag Options Reference

| Option | Values | Description |
|--------|--------|-------------|
| `type` | See field types | Type of form field |
| `role` | Any string | Signer role assignment |
| `required` | `true`/`false` | Field is mandatory |
| `readonly` | `true`/`false` | Field cannot be edited |
| `default` | Any value | Default field value |

---

## API Submitter Parameters

When creating submissions via API, these parameters are available for each submitter:

### Basic Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `role` | string | Must match a role in template (e.g., `{{Field;type=X;role=Signer}}`) |
| `email` | string | Submitter's email address |
| `name` | string | Submitter's display name |
| `phone` | string | Phone number in E.164 format (e.g., `+628123456789`) |
| `external_id` | string | Your app's unique identifier for this submitter |
| `completed` | boolean | Mark as pre-completed (skip signing) |

### Communication Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `send_email` | boolean | `true` | Send signature request email |
| `send_sms` | boolean | `false` | Send signature request SMS |
| `message.subject` | string | - | Custom email subject |
| `message.body` | string | - | Custom email body |
| `reply_to` | string | - | Reply-to email address |
| `completed_redirect_url` | string | - | URL to redirect after completion |

### Two-Factor Authentication (2FA)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `require_phone_2fa` | boolean | `false` | Require phone OTP verification to access documents |
| `require_email_2fa` | boolean | `false` | Require email OTP verification to access documents |

#### Phone 2FA Setup

When `require_phone_2fa: true`:
1. The submitter must have a valid `phone` number
2. DocuSeal sends an OTP code via:
   - **Phone OTP Webhook** (if configured) - You send SMS via your provider
   - **Built-in SMS** (if no webhook configured and SMS is enabled)
3. Submitter enters the 6-digit code to access the form
4. OTP codes are valid for **10 minutes**

#### Email 2FA Setup

When `require_email_2fa: true`:
1. The submitter must have a valid `email` address
2. DocuSeal sends an OTP code via email automatically
3. Submitter enters the 6-digit code to access the form
4. OTP codes are valid for **5 minutes**

> **Note**: Email 2FA does not have a webhook option - emails are always sent by DocuSeal. Only Phone 2FA supports custom webhook delivery.

#### Example with 2FA

```json
{
  "template_id": 123,
  "submitters": [
    {
      "role": "Signer",
      "email": "signer@example.com",
      "phone": "+628123456789",
      "require_phone_2fa": true
    }
  ]
}
```

### Field Configuration

| Parameter | Type | Description |
|-----------|------|-------------|
| `fields` | array | Override field settings |
| `fields[].name` | string | Field name to configure |
| `fields[].default_value` | any | Set default value |
| `fields[].readonly` | boolean | Make field read-only |
| `fields[].required` | boolean | Override required setting |
| `values` | object | Pre-fill field values (key-value pairs) |
| `readonly_fields` | array | List of field names to make read-only |

### Metadata

| Parameter | Type | Description |
|-----------|------|-------------|
| `metadata` | object | Custom key-value pairs for your app |

### Workflow & Signing Order

DocuSeal supports two levels of signing order control:

#### Submission-Level Order (Top-Level Parameter)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `order` | string | `"preserved"` | Controls overall signing workflow |

**Values:**
- `"preserved"` - Sequential signing. Second party receives signature request only after the first party signs.
- `"random"` - Parallel signing. All parties receive signature requests immediately and can sign in any order.

#### Submitter-Level Order (Per-Submitter Parameter)

| Parameter | Type | Description |
|-----------|------|-------------|
| `order` | integer | Position in signing sequence (0 = first, 1 = second, etc.) |
| `go_to_last` | boolean | Start at the last unfilled field |

**Order Groups:** Use the same `order` number for multiple submitters to create parallel signing within a sequential workflow.

#### Signing Order Examples

**Example 1: Sequential Signing (Default)**

```json
{
  "template_id": 123,
  "order": "preserved",
  "submitters": [
    { "role": "Buyer", "email": "buyer@example.com" },
    { "role": "Seller", "email": "seller@example.com" }
  ]
}
```
- Buyer signs first → Seller receives request after Buyer completes

**Example 2: Parallel Signing**

```json
{
  "template_id": 123,
  "order": "random",
  "submitters": [
    { "role": "Buyer", "email": "buyer@example.com" },
    { "role": "Seller", "email": "seller@example.com" }
  ]
}
```
- Both Buyer and Seller receive requests immediately, can sign in any order

**Example 3: Custom Order with Groups**

```json
{
  "template_id": 123,
  "order": "preserved",
  "submitters": [
    { "role": "Witness 1", "email": "witness1@example.com", "order": 0 },
    { "role": "Witness 2", "email": "witness2@example.com", "order": 0 },
    { "role": "Manager", "email": "manager@example.com", "order": 1 },
    { "role": "Director", "email": "director@example.com", "order": 2 }
  ]
}
```
- **Order 0**: Witness 1 and Witness 2 sign in parallel (same order group)
- **Order 1**: Manager signs after both witnesses complete
- **Order 2**: Director signs last

**Example 4: Reverse Order**

```json
{
  "template_id": 123,
  "order": "preserved",
  "submitters": [
    { "role": "Employee", "email": "employee@example.com", "order": 1 },
    { "role": "HR Manager", "email": "hr@example.com", "order": 0 }
  ]
}
```
- HR Manager signs first (order: 0), then Employee (order: 1)

---

## Consent Settings

Consent allows you to require signers to accept terms and conditions before signing documents.

### How Consent Works

When enabled, submitters see a checkbox with your consent text and a link to your terms document. They must check the box before they can proceed with signing.

### Configuration Levels

#### 1. Account-Level Defaults (Settings UI)

Go to **Settings** → **Consent** to configure default consent for all templates:

| Setting | Description |
|---------|-------------|
| **Consent Document URL** | URL to your terms and conditions document |
| **Consent Text** | Checkbox label (default: "I have read and agree to the terms and conditions") |

#### 2. Template-Level Override (Template Settings UI)

In the template editor, go to **Settings** → **Consent** to override account defaults:

| Setting | Description |
|---------|-------------|
| **Enable Consent** | Toggle consent for this template |
| **Consent Document URL** | Override URL for this template |
| **Consent Text** | Override text for this template |

### Template Preferences for Consent

Consent is controlled via template `preferences`:

| Preference Key | Type | Description |
|----------------|------|-------------|
| `consent_enabled` | boolean | Enable consent checkbox for this template |
| `consent_document_url` | string | URL to terms document (falls back to account default) |
| `consent_document_text` | string | Consent checkbox text (falls back to account default) |

### API Parameters for Consent

Consent can be configured at **top-level** (all submitters) or **per-submitter** (per role):

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `consent_enabled` | boolean | `false` | Enable consent checkbox |
| `consent_document_url` | string | - | URL to terms and conditions document |
| `consent_document_text` | string | - | Consent checkbox label text |

#### Priority Order

Consent settings are resolved in this priority:
1. **Per-submitter API parameters** (highest priority)
2. **Top-level submission API parameters**
3. **Template preferences** (set via Template Editor UI)
4. **Account defaults** (set via Settings → Consent)

#### API Example: Same Consent for All Submitters (Top-Level)

```json
{
  "template_id": 123,
  "consent_enabled": true,
  "consent_document_url": "https://example.com/terms",
  "consent_document_text": "I agree to the Terms of Service",
  "submitters": [
    { "role": "Buyer", "email": "buyer@example.com" },
    { "role": "Seller", "email": "seller@example.com" }
  ]
}
```

Both Buyer and Seller see the same consent.

#### API Example: Different Consent Per Role

```json
{
  "template_id": 123,
  "submitters": [
    {
      "role": "Buyer",
      "email": "buyer@example.com",
      "consent_enabled": true,
      "consent_document_url": "https://example.com/buyer-terms",
      "consent_document_text": "I agree to the Buyer Terms of Service"
    },
    {
      "role": "Seller",
      "email": "seller@example.com",
      "consent_enabled": true,
      "consent_document_url": "https://example.com/seller-terms",
      "consent_document_text": "I agree to the Seller Agreement"
    }
  ]
}
```

Each role sees their own consent document.

#### API Example: Consent for One Role Only

```json
{
  "template_id": 123,
  "submitters": [
    {
      "role": "Buyer",
      "email": "buyer@example.com",
      "consent_enabled": true,
      "consent_document_url": "https://example.com/terms",
      "consent_document_text": "I agree to the Terms"
    },
    {
      "role": "Seller",
      "email": "seller@example.com",
      "consent_enabled": false
    }
  ]
}
```

Only Buyer sees consent; Seller signs without consent.

#### API Example: DOCX Submission with Per-Role Consent

```json
{
  "name": "Contract with Terms",
  "documents": [{"name": "contract.docx", "file": "BASE64_ENCODED_DOCX"}],
  "submitters": [
    {
      "role": "Buyer",
      "email": "buyer@example.com",
      "consent_enabled": true,
      "consent_document_url": "https://example.com/buyer-terms.pdf"
    },
    {
      "role": "Seller",
      "email": "seller@example.com",
      "consent_enabled": false
    }
  ]
}
```

#### Fallback Behavior

If `consent_enabled: true` but no URL/text is provided:
- `consent_document_url` falls back to: submission setting → template setting → account default
- `consent_document_text` falls back to: submission setting → template setting → account default (or "I have read and agree to the terms and conditions")

### Example Consent Flow

```
┌─────────────────────────────────────────────┐
│         Document Signing Form               │
├─────────────────────────────────────────────┤
│                                             │
│  [Document Preview]                         │
│                                             │
│  ☐ I have read and agree to the            │
│    terms and conditions                     │
│    (Click to view terms)                    │
│                                             │
│  [Sign Document] ← disabled until checked   │
│                                             │
└─────────────────────────────────────────────┘
```

### Audit Trail

When consent is enabled, the audit trail records:
- Timestamp when the submitter agreed to consent
- The consent text that was displayed
- The consent document URL that was linked

---

## Related Documentation

- [Phone OTP Webhook](./webhooks/phone-otp-webhook.md) - Custom SMS provider integration
- [Form Webhook](./webhooks/form-webhook.md) - Form lifecycle events
- [Submission Webhook](./webhooks/submission-webhook.md) - Submission events
