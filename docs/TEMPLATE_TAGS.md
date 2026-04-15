# SealRoute Template Tags Documentation

This document describes the templating tag system used in SealRoute for creating dynamic documents with form fields and data placeholders.

## Overview

SealRoute supports two types of tags:

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
| `datenow` | Auto-filled current date (readonly) | `{{BuyerDate;type=datenow;role=Buyer}}` |
| `checkbox` | Checkbox field | `{{AgreeTerms;type=checkbox;role=Buyer}}` |
| `number` | Numeric input | `{{Quantity;type=number;role=Buyer}}` |
| `phone` | Phone number input | `{{PhoneNumber;type=phone;role=Buyer}}` |
| `email` | Email input | `{{EmailAddress;type=email;role=Buyer}}` |
| `image` | Image upload field | `{{Photo;type=image;role=Buyer}}` |
| `stamp` | Stamp/seal field | `{{CompanyStamp;type=stamp;role=Seller}}` |
| `stamp` (background) | Stamp behind content | `{{CompanyStamp;type=stamp;role=Seller;position=background}}` |
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

Repeat content for each item in a collection. SealRoute supports two types of loops:

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

## Auto-Date (`datenow`) Behavior

The `datenow` field type creates a **readonly date field** that is automatically filled with the current date when the signer completes the form.

### How It Works

1. In the DOCX template: `{{SignDate;type=datenow;role=Buyer}}`
2. Internally converted to: `type=date`, `readonly=true`, `default_value={{date}}`
3. When the signer submits, `{{date}}` resolves to the current date in the account's timezone
4. The date is rendered on the final PDF using the field's format preference

### Date Format

By default, dates use `DD/MM/YYYY` (or `MM/DD/YYYY` for US locales). Override with `format`:

```
{{SignDate;type=datenow;role=Buyer;format=DD/MM/YYYY}}
{{SignDate;type=datenow;role=Buyer;format=MMMM DD, YYYY}}
```

### Important Notes

- `datenow` fields are **not** interactive — signers cannot change the date
- The date is set at **completion time**, not at document creation time
- If you need signers to pick a date, use `type=date` instead

---

## DOCX Formatting Inheritance

When using DOCX templates, SealRoute reads paragraph formatting from the document and applies it to the rendered field values. This means the final PDF matches the visual style of your DOCX.

### Automatic Alignment Detection

If a field tag is placed in a **centered** or **right-aligned** paragraph in Word, the field is automatically positioned and aligned accordingly:

```
                    {{SignDate;type=datenow;role=Buyer}}        ← centered in Word
                    {{BuyerSign;type=signature;role=Buyer}}     ← centered in Word
                    [[Nama_Anggota]]                            ← centered in Word
```

The system reads `<w:jc w:val="center"/>` from the DOCX XML and:
- **Positions** the field centered on the page content area
- Sets `preferences.align = "center"` so the rendered value text is also centered

### Automatic Font Detection

The system reads the font family from `<w:rFonts>` in the DOCX XML and maps it:

| DOCX Font | Mapped To |
|-----------|-----------|
| Times New Roman | `Times` |
| Arial | `Helvetica` |
| Courier New | `Courier` |

Other fonts fall back to the system default (GoNotoKurrent or Helvetica).

### Automatic Font Size Detection

The system reads the font size from `<w:sz>` in the DOCX XML. DOCX stores sizes in half-points (e.g., `sz=24` = 12pt).

**Resolution order** (first match wins):

1. Explicit `font_size=N` attribute in the tag (e.g., `{{Date;type=date;font_size=14}}`)
2. Run-level `<w:sz>` on the text run containing the tag
3. Paragraph-level default `<w:pPr><w:rPr><w:sz>`
4. Document default from `<w:docDefaults>` in `word/styles.xml`
5. `Normal` style in `word/styles.xml`
6. System default (11pt, scaled to page size)

This means if your DOCX document uses 12pt font throughout, all field values (dates, text, etc.) will render at 12pt in the final PDF — without needing to specify `font_size` in each tag.

### Explicit Overrides

Tag attributes always override DOCX formatting:

```
{{SignDate;type=datenow;role=Buyer;align=left;font=Courier;font_size=10}}
```

This forces left alignment, Courier font, and 10pt size regardless of DOCX paragraph formatting.

---

## Signature Alignment

By default, drawn signatures are aligned to the **left** within their field area. You can control this with the `align` attribute:

```
{{BuyerSign;type=signature;role=Buyer;align=left}}     ← default
{{BuyerSign;type=signature;role=Buyer;align=center}}   ← centered
{{BuyerSign;type=signature;role=Buyer;align=right}}    ← right-aligned
```

This affects both the signing UI (where the signature image is displayed) and the flattened PDF output.

---

## API Integration

### Variable Scoping (`[[...]]` vs `submitters[].values`)

There are two ways to pass data, and they serve different purposes:

| Mechanism | Syntax in DOCX | JSON Location | Purpose |
|-----------|---------------|---------------|---------|
| `variables` | `[[variable_name]]` | Top-level `variables` or `submitters[].variables` | Text replacement before PDF generation |
| `values` | `{{FieldName;type=X}}` | `submitters[].values` | Pre-fill interactive form fields |

**`[[...]]`** tags are replaced with content from the **`variables`** object. They become static text in the document.

**`{{...;type=X}}`** tags become interactive form fields. Pre-fill them with **`submitters[].values`** (keyed by field name or UUID).

### Role-Scoped Variables

Variables for `[[...]]` tags can be provided at the top level or nested under each submitter. All are merged into a single map before substitution:

```json
{
  "variables": {
    "contract_number": "C-001",
    "contract_date": "April 15, 2026"
  },
  "submitters": [
    {
      "role": "anggota",
      "email": "member@example.com",
      "variables": {
        "Nama_Anggota": "Muhammad",
        "NRP_Anggota": "1234567890"
      }
    },
    {
      "role": "Buyer",
      "email": "buyer@example.com"
    }
  ]
}
```

In this example:
- `[[contract_number]]` and `[[contract_date]]` come from top-level `variables`
- `[[Nama_Anggota]]` and `[[NRP_Anggota]]` come from the `anggota` submitter's `variables`
- All are merged before substitution (later submitters override duplicate keys)

### Submitter Roles

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

## How Tag Processing Works

When a DOCX template with `{{...}}` tags is submitted via the API, SealRoute processes it as follows:

### Processing Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DOCX SUBMISSION FLOW                              │
└─────────────────────────────────────────────────────────────────────────┘

1. DOCX with Tags
   │
   ├──► [[...]] variables replaced with data from "variables" object
   │
   ├──► {{...}} tags made invisible (white text, original text preserved)
   │
   ├──► DOCX paragraph formatting extracted (alignment, font family, font size)
   │
   ├──► Converted to PDF via Gotenberg (single PDF)
   │
   ├──► Pdfium scans the SAME PDF to find {{...}} tag positions
   │    (white text is invisible to users but readable by Pdfium)
   │
   └──► Form fields placed at detected positions with inherited formatting
```

### Step-by-Step Process

1. **Variable Substitution**: `[[...]]` placeholders replaced with values from `variables`
2. **DOCX Analysis**: Paragraph alignment (`center`/`right`), font family (`Times New Roman`, etc.), and font size extracted from DOCX XML — including document defaults from `styles.xml`
3. **Tag Invisibility**: `{{...}}` tags made invisible (white font color) — text preserved for detection
4. **PDF Conversion**: Single PDF generated via Gotenberg
5. **Tag Position Detection**: Pdfium extracts tag positions from the same PDF (white text is still searchable)
6. **Formatting Application**: Detected alignment, font, and font size carried into field preferences
7. **Field Placement**: Interactive form fields placed at correct positions with matching typography

### Single-PDF Approach

Using the **same PDF** for both display and detection eliminates layout mismatches that could occur from separate conversions. Tags are invisible to users but remain extractable by Pdfium.

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
2. **Use standard fonts**: Use Times New Roman, Arial, or Courier New for best results
3. **Keep tags on single line**: Avoid line breaks within a tag
4. **Check PDF conversion**: Ensure Gotenberg service is running correctly
5. **Centered tags**: Tags in centered paragraphs are automatically centered on the page
6. **Font mismatch**: If the rendered date/text looks different from the document font, add `font=Times` to the tag or ensure the DOCX paragraph uses a recognized font family
7. **Font size mismatch**: If the rendered text appears too small or too large, add `font_size=12` (or whichever point size matches your document) to the tag. The system auto-detects font size from the DOCX, but only recognizes `<w:sz>` at the run, paragraph, or `docDefaults` level

---

## Reference

### All Supported Field Types

| Type | Input | Output |
|------|-------|--------|
| `text` | Text box | String value |
| `signature` | Drawing pad | Signature image |
| `initials` | Small drawing pad | Initials image |
| `date` | Date picker | Date string |
| `datenow` | Auto-filled (readonly) | Current date at signing time |
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
| `position` | `background`/`foreground` | Stamp layer: `background` = behind content, `foreground` = on top (default) |
| `align` | `left`/`center`/`right` | Horizontal text alignment for the rendered value |
| `valign` | `top`/`center`/`bottom` | Vertical alignment within the field area |
| `font` | `Times`/`Helvetica`/`Courier` | Font family for the rendered value |
| `font_size` | Integer | Font size in points |
| `font_type` | `bold`/`italic`/`bold_italic` | Font variant |
| `color` | Hex color (e.g. `FF0000`) | Text color for the rendered value |
| `format` | Date/number format string | Format pattern (e.g. `DD/MM/YYYY` for dates) |

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
2. SealRoute sends an OTP code via:
   - **Phone OTP Webhook** (if configured) - You send SMS via your provider
   - **Built-in SMS** (if no webhook configured and SMS is enabled)
3. Submitter enters the 6-digit code to access the form
4. OTP codes are valid for **10 minutes**

#### Email 2FA Setup

When `require_email_2fa: true`:
1. The submitter must have a valid `email` address
2. SealRoute sends an OTP code via email automatically
3. Submitter enters the 6-digit code to access the form
4. OTP codes are valid for **5 minutes**

> **Note**: Email 2FA does not have a webhook option - emails are always sent by SealRoute. Only Phone 2FA supports custom webhook delivery.

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

SealRoute supports two levels of signing order control:

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

## Custom Branding

You can customize the logo and company name displayed in the signing form, emails, and audit trail PDF. **No DOCX tag is needed** — branding is set via API parameters or the Settings UI.

### API Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `logo_url` | string | URL to your company logo image (PNG, JPG, SVG) |
| `company_name` | string | Your company name (replaces "SealRoute" in the UI) |
| `stamp_url` | string | URL to stamp image for `{{stamp}}` fields in signed PDFs (falls back to `logo_url`) |

### API Example

```json
{
  "template_id": 123,
  "logo_url": "https://example.com/your-logo.png",
  "company_name": "Your Company",
  "submitters": [
    { "role": "Signer", "email": "signer@example.com" }
  ]
}
```

### Settings UI

Go to **Settings** → **Personalization** → **Company Logo** to set:
- **Logo URL**: URL to your logo image
- **Company Name**: Your brand name

### Where Branding Appears

| Location | What changes |
|----------|-------------|
| **Signing form** | Logo and name in the header banner |
| **Start form** (share link) | Logo and name on the landing page |
| **Admin navbar** | Logo and name in the top navigation |
| **Audit trail PDF** | Logo and name in the audit log header |
| **Emails** | Company name in email templates |

### Important Notes

- Branding is set at the **account level** — once set, it applies to all submissions
- The API `logo_url` and `company_name` parameters **update account settings** (they persist)
- If no custom branding is set, the default SealRoute logo and name are used
- The logo is NOT embedded in the signed document PDF — it only appears in the UI and audit trail

---

## Related Documentation

- [Phone OTP Webhook](./webhooks/phone-otp-webhook.md) - Custom SMS provider integration
- [Form Webhook](./webhooks/form-webhook.md) - Form lifecycle events
- [Submission Webhook](./webhooks/submission-webhook.md) - Submission events
