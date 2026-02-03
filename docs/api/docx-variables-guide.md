# DOCX Dynamic Variables & Text Tags Guide

This guide explains how to create personalized documents using DOCX dynamic content variables and embedded text field tags.

## Overview

DocuSeal supports two types of document templating:

| Syntax | Purpose | When Filled | Example |
|--------|---------|-------------|---------|
| `[[variable]]` | Dynamic content | Before signing (via API) | `[[customer_name]]` → "John Doe" |
| `{{tag;type=...}}` | Interactive fields | During signing (by signer) | `{{Sign;type=signature}}` → ✍️ |

## DOCX Variable Syntax

### Simple Variables

Replace placeholders with values:

```
Dear [[customer_name]],

Your order #[[order_number]] has been confirmed.
Total: $[[total_amount]]
```

### Conditional Blocks

Show/hide content based on conditions:

```
[[if:is_premium_customer]]
Thank you for being a Premium member! You receive free shipping.
[[else]]
Standard shipping rates apply.
[[end]]
```

### Loops

Repeat content for arrays:

```
ORDER ITEMS:
[[for:items]]
- [[item.name]]: [[item.quantity]] x $[[item.price]] = $[[item.subtotal]]
[[end]]

Total: $[[total]]
```

## Text Tag Syntax for Form Fields

### Basic Tag Format

```
{{FieldName;type=fieldtype;role=SignerRole;required=true}}
```

### Supported Field Types

| Type | Description | Example |
|------|-------------|---------|
| `text` | Text input | `{{Name;type=text}}` |
| `signature` | Signature field | `{{Sign;type=signature}}` |
| `initials` | Initials field | `{{Init;type=initials}}` |
| `date` | Date picker | `{{Date;type=date}}` |
| `datenow` | Auto-filled current date | `{{Today;type=datenow}}` |
| `checkbox` | Checkbox | `{{Agree;type=checkbox}}` |
| `select` | Dropdown select | `{{Choice;type=select;options=A,B,C}}` |
| `radio` | Radio buttons | `{{Option;type=radio;options=Yes,No}}` |
| `number` | Number input | `{{Amount;type=number}}` |
| `phone` | Phone number | `{{Phone;type=phone}}` |
| `image` | Image upload | `{{Photo;type=image}}` |
| `file` | File attachment | `{{Document;type=file}}` |
| `stamp` | Stamp/seal | `{{Stamp;type=stamp}}` |

### Tag Attributes

| Attribute | Description | Example |
|-----------|-------------|---------|
| `type` | Field type (required) | `type=signature` |
| `role` | Signer role name | `role=Customer` |
| `required` | Make field required | `required=true` |
| `readonly` | Make field read-only | `readonly=true` |
| `default` | Default value | `default=John Doe` |
| `options` | Options for select/radio | `options=Yes,No,Maybe` |
| `format` | Date/signature format | `format=DD/MM/YYYY` |
| `width` | Field width in pixels | `width=200` |
| `height` | Field height in pixels | `height=80` |

---

## Real-World Example: Sales Contract

### Step 1: Create DOCX Template

Create a file named `sales_contract.docx` with this content:

```
                        SALES AGREEMENT
                        Contract #: [[contract_number]]
                        Date: [[contract_date]]

SELLER INFORMATION
Company: [[company_name]]
Address: [[company_address]]
Contact: [[sales_rep_name]] | [[sales_rep_email]]

BUYER INFORMATION  
Name: [[customer_name]]
Company: [[customer_company]]
Address: [[customer_address]]
Phone: [[customer_phone]]
Email: [[customer_email]]

─────────────────────────────────────────────────────────────

PRODUCTS/SERVICES

[[for:items]]
┌─────────────────────────────────────────────────────────┐
│ [[item.name]]                                           │
│ Description: [[item.description]]                       │
│ Quantity: [[item.quantity]] × $[[item.unit_price]]      │
│ Subtotal: $[[item.subtotal]]                            │
└─────────────────────────────────────────────────────────┘
[[end]]

─────────────────────────────────────────────────────────────

PRICING SUMMARY
                                    Subtotal: $[[subtotal]]
[[if:has_discount]]
                                    Discount ([[discount_percent]]%): -$[[discount_amount]]
[[end]]
                                    Tax ([[tax_rate]]%): $[[tax_amount]]
                                    ─────────────
                                    TOTAL: $[[total]]

─────────────────────────────────────────────────────────────

PAYMENT TERMS
[[if:payment_installment]]
Payment Plan: [[installment_count]] monthly payments of $[[installment_amount]]
First Payment Due: [[first_payment_date]]
[[else]]
Payment Due: Net [[payment_days]] days from contract date
[[end]]

─────────────────────────────────────────────────────────────

TERMS AND CONDITIONS

1. Delivery will be completed within [[delivery_days]] business days.
2. Warranty period: [[warranty_months]] months from delivery date.
3. This agreement is governed by the laws of [[jurisdiction]].

[[if:special_terms]]
SPECIAL TERMS:
[[special_terms]]
[[end]]

─────────────────────────────────────────────────────────────

SIGNATURES

By signing below, both parties agree to the terms stated above.

BUYER                                    SELLER

{{BuyerSign;type=signature;role=Buyer}}  {{SellerSign;type=signature;role=Seller}}

Name: {{BuyerName;type=text;role=Buyer}} Name: {{SellerName;type=text;role=Seller}}

Date: {{BuyerDate;type=datenow;role=Buyer}} Date: {{SellerDate;type=datenow;role=Seller}}

Initials: {{BuyerInit;type=initials;role=Buyer}} {{SellerInit;type=initials;role=Seller}}
```

### Step 2: API Request

#### Using cURL

```bash
# First, base64 encode your DOCX file
DOCX_BASE64=$(base64 -i sales_contract.docx)

curl -X POST "https://your-docuseal.com/api/submissions/docx" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Sales Contract - Acme Corp",
    "variables": {
      "contract_number": "SC-2026-001234",
      "contract_date": "February 3, 2026",
      "company_name": "TechVendor Inc.",
      "company_address": "123 Business Ave, San Francisco, CA 94102",
      "sales_rep_name": "Jane Smith",
      "sales_rep_email": "jane@techvendor.com",
      "customer_name": "John Doe",
      "customer_company": "Acme Corporation",
      "customer_address": "456 Corporate Blvd, New York, NY 10001",
      "customer_phone": "+1 (555) 123-4567",
      "customer_email": "john@acme.com",
      "items": [
        {
          "name": "Enterprise Software License",
          "description": "1-year license for up to 100 users",
          "quantity": "1",
          "unit_price": "15,000.00",
          "subtotal": "15,000.00"
        },
        {
          "name": "Implementation Services",
          "description": "On-site setup and configuration",
          "quantity": "40",
          "unit_price": "150.00",
          "subtotal": "6,000.00"
        }
      ],
      "subtotal": "21,000.00",
      "has_discount": true,
      "discount_percent": "10",
      "discount_amount": "2,100.00",
      "tax_rate": "8.5",
      "tax_amount": "1,606.50",
      "total": "20,506.50",
      "payment_installment": false,
      "payment_days": "30",
      "delivery_days": "14",
      "warranty_months": "12",
      "jurisdiction": "State of California",
      "special_terms": "Extended support included for first 90 days."
    },
    "documents": [{
      "name": "sales_contract.docx",
      "file": "'"$DOCX_BASE64"'"
    }],
    "submitters": [
      {
        "role": "Buyer",
        "email": "john@acme.com",
        "name": "John Doe"
      },
      {
        "role": "Seller",
        "email": "jane@techvendor.com",
        "name": "Jane Smith"
      }
    ],
    "send_email": true,
    "order": "preserved"
  }'
```

#### Using JavaScript/Node.js

```javascript
const fetch = require('node-fetch');
const fs = require('fs');

async function createSalesContract() {
  // Read and encode DOCX template
  const docxFile = fs.readFileSync('./sales_contract.docx');
  const base64Docx = docxFile.toString('base64');

  const response = await fetch('https://your-docuseal.com/api/submissions/docx', {
    method: 'POST',
    headers: {
      'X-Auth-Token': 'YOUR_API_KEY',
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      name: 'Sales Contract - Acme Corp',
      
      variables: {
        contract_number: 'SC-2026-001234',
        contract_date: 'February 3, 2026',
        company_name: 'TechVendor Inc.',
        company_address: '123 Business Ave, San Francisco, CA 94102',
        sales_rep_name: 'Jane Smith',
        sales_rep_email: 'jane@techvendor.com',
        customer_name: 'John Doe',
        customer_company: 'Acme Corporation',
        customer_address: '456 Corporate Blvd, New York, NY 10001',
        customer_phone: '+1 (555) 123-4567',
        customer_email: 'john@acme.com',
        items: [
          {
            name: 'Enterprise Software License',
            description: '1-year license for up to 100 users',
            quantity: '1',
            unit_price: '15,000.00',
            subtotal: '15,000.00'
          },
          {
            name: 'Implementation Services',
            description: 'On-site setup and configuration',
            quantity: '40',
            unit_price: '150.00',
            subtotal: '6,000.00'
          }
        ],
        subtotal: '21,000.00',
        has_discount: true,
        discount_percent: '10',
        discount_amount: '2,100.00',
        tax_rate: '8.5',
        tax_amount: '1,606.50',
        total: '20,506.50',
        payment_installment: false,
        payment_days: '30',
        delivery_days: '14',
        warranty_months: '12',
        jurisdiction: 'State of California',
        special_terms: 'Extended support included for first 90 days.'
      },
      
      documents: [{
        name: 'sales_contract.docx',
        file: base64Docx
      }],
      
      submitters: [
        {
          role: 'Buyer',
          email: 'john@acme.com',
          name: 'John Doe',
          phone: '+15551234567'
        },
        {
          role: 'Seller',
          email: 'jane@techvendor.com',
          name: 'Jane Smith'
        }
      ],
      
      send_email: true,
      order: 'preserved'
    })
  });

  const result = await response.json();
  console.log('Contract created:', result);
  
  // Returns array of submitter objects with signing URLs
  // result[0].embed_src = "https://your-docuseal.com/s/abc123"
}

createSalesContract();
```

#### Using Python

```python
import requests
import base64
import json

def create_sales_contract():
    # Read and encode DOCX template
    with open('sales_contract.docx', 'rb') as f:
        docx_base64 = base64.b64encode(f.read()).decode('utf-8')
    
    response = requests.post(
        'https://your-docuseal.com/api/submissions/docx',
        headers={
            'X-Auth-Token': 'YOUR_API_KEY',
            'Content-Type': 'application/json'
        },
        json={
            'name': 'Sales Contract - Acme Corp',
            'variables': {
                'contract_number': 'SC-2026-001234',
                'contract_date': 'February 3, 2026',
                'company_name': 'TechVendor Inc.',
                'company_address': '123 Business Ave, San Francisco, CA 94102',
                'sales_rep_name': 'Jane Smith',
                'sales_rep_email': 'jane@techvendor.com',
                'customer_name': 'John Doe',
                'customer_company': 'Acme Corporation',
                'customer_address': '456 Corporate Blvd, New York, NY 10001',
                'customer_phone': '+1 (555) 123-4567',
                'customer_email': 'john@acme.com',
                'items': [
                    {
                        'name': 'Enterprise Software License',
                        'description': '1-year license for up to 100 users',
                        'quantity': '1',
                        'unit_price': '15,000.00',
                        'subtotal': '15,000.00'
                    },
                    {
                        'name': 'Implementation Services',
                        'description': 'On-site setup and configuration',
                        'quantity': '40',
                        'unit_price': '150.00',
                        'subtotal': '6,000.00'
                    }
                ],
                'subtotal': '21,000.00',
                'has_discount': True,
                'discount_percent': '10',
                'discount_amount': '2,100.00',
                'tax_rate': '8.5',
                'tax_amount': '1,606.50',
                'total': '20,506.50',
                'payment_installment': False,
                'payment_days': '30',
                'delivery_days': '14',
                'warranty_months': '12',
                'jurisdiction': 'State of California',
                'special_terms': 'Extended support included for first 90 days.'
            },
            'documents': [{
                'name': 'sales_contract.docx',
                'file': docx_base64
            }],
            'submitters': [
                {
                    'role': 'Buyer',
                    'email': 'john@acme.com',
                    'name': 'John Doe',
                    'phone': '+15551234567'
                },
                {
                    'role': 'Seller',
                    'email': 'jane@techvendor.com',
                    'name': 'Jane Smith'
                }
            ],
            'send_email': True,
            'order': 'preserved'
        }
    )
    
    result = response.json()
    print('Contract created:', json.dumps(result, indent=2))
    return result

create_sales_contract()
```

### Step 3: Response

The API returns an array of submitter objects:

```json
[
  {
    "id": 12345,
    "submission_id": 6789,
    "uuid": "abc123...",
    "email": "john@acme.com",
    "name": "John Doe",
    "role": "Buyer",
    "status": "pending",
    "embed_src": "https://your-docuseal.com/s/abc123xyz",
    "preferences": {}
  },
  {
    "id": 12346,
    "submission_id": 6789,
    "uuid": "def456...",
    "email": "jane@techvendor.com",
    "name": "Jane Smith",
    "role": "Seller",
    "status": "awaiting",
    "embed_src": "https://your-docuseal.com/s/def456xyz",
    "preferences": {}
  }
]
```

---

## Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                    DOCUMENT GENERATION FLOW                      │
└─────────────────────────────────────────────────────────────────┘

     ┌──────────────┐
     │  CRM/ERP     │
     │  System      │
     └──────┬───────┘
            │
            │ 1. Collect order data
            ▼
     ┌──────────────┐      ┌──────────────┐
     │  Your App    │──────│  DOCX        │
     │  Backend     │      │  Template    │
     └──────┬───────┘      └──────────────┘
            │
            │ 2. POST /api/submissions/docx
            │    - Template file (base64)
            │    - Variables (customer data, items, pricing)
            │    - Submitters (signers)
            ▼
     ┌──────────────────────────────────────┐
     │           DocuSeal API               │
     │                                      │
     │  ┌────────────────────────────────┐  │
     │  │ 3. Process DOCX Variables      │  │
     │  │    [[customer_name]] → John    │  │
     │  │    [[for:items]]... → expanded │  │
     │  └────────────────────────────────┘  │
     │                 │                    │
     │                 ▼                    │
     │  ┌────────────────────────────────┐  │
     │  │ 4. Convert DOCX → PDF          │  │
     │  └────────────────────────────────┘  │
     │                 │                    │
     │                 ▼                    │
     │  ┌────────────────────────────────┐  │
     │  │ 5. Parse {{tags}} → Fields     │  │
     │  │    {{BuyerSign}} → Signature   │  │
     │  │    {{BuyerDate}} → Date field  │  │
     │  └────────────────────────────────┘  │
     │                 │                    │
     │                 ▼                    │
     │  ┌────────────────────────────────┐  │
     │  │ 6. Create Submission           │  │
     │  │    - Assign fields to roles    │  │
     │  │    - Generate signing URLs     │  │
     │  └────────────────────────────────┘  │
     └──────────────┬───────────────────────┘
                    │
                    │ 7. Return signing URLs
                    ▼
     ┌──────────────────────────────────────┐
     │           Email / Webhook            │
     │                                      │
     │   Buyer: https://.../s/abc123        │
     │   Seller: https://.../s/xyz789       │
     └──────────────┬───────────────────────┘
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
  ┌───────────┐           ┌───────────┐
  │  Buyer    │           │  Seller   │
  │  Signs    │           │  Signs    │
  │  (1st)    │           │  (2nd)    │
  └─────┬─────┘           └─────┬─────┘
        │                       │
        └───────────┬───────────┘
                    ▼
     ┌──────────────────────────────────────┐
     │         Completed Document           │
     │                                      │
     │   - All variables filled             │
     │   - All signatures collected         │
     │   - Audit trail included             │
     │   - PDF available for download       │
     └──────────────────────────────────────┘
                    │
                    │ 8. Webhook notification
                    ▼
     ┌──────────────────────────────────────┐
     │           Your System                │
     │                                      │
     │   - Update CRM status                │
     │   - Archive signed document          │
     │   - Trigger fulfillment              │
     └──────────────────────────────────────┘
```

---

## PDF Text Tags API

For PDF documents with embedded text tags, use the `/api/submissions/pdf` endpoint:

```bash
curl -X POST "https://your-docuseal.com/api/submissions/pdf" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Agreement with Text Tags",
    "documents": [{
      "name": "agreement.pdf",
      "file": "<base64-encoded-pdf>"
    }],
    "submitters": [{
      "role": "Customer",
      "email": "customer@example.com"
    }]
  }'
```

The PDF should contain text tags like:
- `{{CustomerName;type=text;role=Customer;required=true}}`
- `{{Signature;type=signature;role=Customer}}`
- `{{Date;type=datenow}}`

These tags will be automatically detected and converted to interactive form fields.

---

## Additional Resources

- [API Documentation](/docs/api/)
- [Webhook Documentation](/docs/webhooks/)
- [Embedding Guide](/docs/embedding/)
