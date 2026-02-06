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
