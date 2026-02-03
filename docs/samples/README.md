# Sample Document Templates

This folder contains sample templates demonstrating DOCX variables and text tags.

## Files

| File | Description |
|------|-------------|
| `sales_contract_template.txt` | Full sales contract with all features |
| `simple_contract_template.txt` | Simplified contract for quick testing |

## How to Create DOCX Files

### Option 1: Microsoft Word
1. Open the `.txt` file
2. Copy all content
3. Paste into a new Word document
4. Format as desired (fonts, margins, etc.)
5. Save as `.docx`

### Option 2: Google Docs
1. Go to [docs.google.com](https://docs.google.com)
2. Create new document
3. Paste the template content
4. File → Download → Microsoft Word (.docx)

### Option 3: LibreOffice Writer
1. Open `.txt` file in LibreOffice Writer
2. Format as needed
3. Save As → `.docx` format

### Option 4: Online Converter
1. Go to [cloudconvert.com/txt-to-docx](https://cloudconvert.com/txt-to-docx)
2. Upload the `.txt` file
3. Download the `.docx`

## Template Syntax

### Dynamic Variables (filled by API before signing)
```
[[variable_name]]           - Simple variable
[[if:condition]]...[[end]]  - Conditional block
[[for:items]]...[[end]]     - Loop
[[item.property]]           - Item accessor in loops
```

### Form Field Tags (filled by signer during signing)
```
{{FieldName;type=text}}                    - Text input
{{Sign;type=signature;role=Buyer}}         - Signature
{{Init;type=initials;role=Buyer}}          - Initials
{{Date;type=datenow}}                      - Auto date
{{Agree;type=checkbox}}                    - Checkbox
{{Choice;type=select;options=A,B,C}}       - Dropdown
```

## API Usage Example

```bash
# Encode DOCX to base64
DOCX_BASE64=$(base64 -i simple_contract.docx)

# Create submission
curl -X POST "https://your-docuseal.com/api/submissions/docx" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Contract",
    "variables": {
      "contract_number": "C-001",
      "contract_date": "2026-02-03",
      "company_name": "My Company",
      "company_address": "123 Main St",
      "customer_name": "John Doe",
      "customer_company": "Client Inc",
      "customer_address": "456 Oak Ave",
      "customer_email": "john@example.com",
      "items": [
        {"name": "Service A", "description": "Consulting", "quantity": "10", "unit_price": "100", "subtotal": "1000"}
      ],
      "subtotal": "1000",
      "has_discount": false,
      "tax_rate": "10",
      "tax_amount": "100",
      "total": "1100",
      "payment_days": "30",
      "delivery_days": "7",
      "warranty_months": "12"
    },
    "documents": [{"name": "contract.docx", "file": "'"$DOCX_BASE64"'"}],
    "submitters": [
      {"role": "Buyer", "email": "buyer@example.com"},
      {"role": "Seller", "email": "seller@example.com"}
    ]
  }'
```

## Testing Variables Only

To test just the variable substitution without signing:

```javascript
// Test with minimal variables
const variables = {
  contract_number: "TEST-001",
  contract_date: "February 3, 2026",
  company_name: "Test Company",
  customer_name: "Test Customer",
  items: [
    { name: "Item 1", quantity: "1", unit_price: "100", subtotal: "100" }
  ],
  total: "100"
};
```
