# Sample Document Templates

This folder contains sample templates demonstrating DOCX variables and text tags.

## Two-PDF Architecture

DocuSeal uses a sophisticated **two-PDF approach** for accurate form field placement while keeping the final document clean:

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DOCX SUBMISSION FLOW                                 │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────┐
│  DOCX Template  │
│  with [[vars]]  │
│  and {{tags}}   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Variable Subst. │  [[...]] placeholders replaced with data
│ ([[...]] only)  │
└────────┬────────┘
         │
         ├─────────────────────────────────────┐
         │                                     │
         ▼                                     ▼
┌─────────────────┐                   ┌─────────────────┐
│  PDF 1: Tagged  │                   │ Tag Removal     │
│  (with {{...}}) │                   │ (DOCX level)    │
└────────┬────────┘                   └────────┬────────┘
         │                                     │
         ▼                                     ▼
┌─────────────────┐                   ┌─────────────────┐
│ Tag Detection   │                   │  PDF 2: Clean   │
│ (Pdfium finds   │                   │  (no {{...}})   │
│  X,Y positions) │                   └────────┬────────┘
└────────┬────────┘                            │
         │                                     │
         └──────────────┬──────────────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │  Final Document │
              │  Clean PDF with │
              │  form fields at │
              │  correct pos    │
              └─────────────────┘
```

### Why Two PDFs?

| PDF | Purpose | Content |
|-----|---------|---------|
| **Tagged PDF** | Position detection only | Contains visible `{{...}}` tags for coordinate extraction |
| **Clean PDF** | Final document | Tags removed, professional appearance |

### Processing Steps

1. **Variable Substitution**: `[[...]]` placeholders replaced with data from API
2. **Tagged PDF Generation**: DOCX → PDF with `{{...}}` tags visible
3. **Tag Position Detection**: Pdfium extracts exact X,Y coordinates of each tag
4. **Clean DOCX Creation**: All `{{...}}` tags removed from DOCX content
5. **Clean PDF Generation**: Clean DOCX → PDF (no visible tags)
6. **Field Placement**: Form fields placed on clean PDF at detected positions

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `GOTENBERG_URL` | Gotenberg service URL (DOCX→PDF) | `http://gotenberg:3000` |

### Result

Users see a professional document with:
- ✅ All `[[...]]` variables replaced with actual data
- ✅ No visible `{{...}}` tag text
- ✅ Interactive form fields at correct positions
- ✅ Clean, professional appearance

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

### 1. Data Variables `[[...]]` (Replaced with API data)

Use double square brackets for data that should be replaced before the document is signed:

```
[[variable_name]]           - Simple variable
[[if:condition]]...[[end]]  - Conditional block
[[for:items]]...[[end]]     - Loop
[[item.property]]           - Item accessor in loops
```

**Examples:**
```
Contract #: [[contract_number]]
Customer: [[customer_name]]
Prepared By: [[prepared_by]]
Date: [[contract_date]]
```

### 2. Form Field Tags `{{name;type=X}}` (Interactive fields for signers)

Use double curly braces WITH `type=` option for fields that signers will fill out:

```
{{FieldName;type=text;role=Buyer}}               - Text input field
{{Sign;type=signature;role=Buyer;required=true}} - Signature field
{{Init;type=initials;role=Buyer}}                - Initials field
{{Date;type=datenow;role=Buyer}}                 - Auto-filled date
{{Agree;type=checkbox;role=Buyer}}               - Checkbox
```

**Important:** Form field tags MUST have `type=` to be recognized as interactive fields.

### Quick Reference

| Syntax | Purpose | When Replaced | Example |
|--------|---------|---------------|---------|
| `[[name]]` | Data placeholder | Before signing | `[[customer_name]]` → "John Doe" |
| `{{name;type=X}}` | Form field | During signing | `{{Sign;type=signature}}` → signature pad |

### Common Mistake

❌ **Wrong:** `{{prepared_by}}` - No type, ambiguous behavior
✅ **Correct:** `[[prepared_by]]` - Data variable, replaced with API data
✅ **Correct:** `{{Name;type=text;role=Buyer}}` - Form field with type

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
      "warranty_months": "12",
      "prepared_by": "Sales Team",
      "prepared_date": "February 4, 2026"
    },
    "documents": [{"name": "contract.docx", "file": "'"$DOCX_BASE64"'"}],
    "submitters": [
      {"role": "Buyer", "email": "buyer@example.com", "name": "John Doe"},
      {"role": "Seller", "email": "seller@example.com", "name": "Jane Smith"}
    ]
  }'
```

### What Happens

1. `[[...]]` variables are replaced with data from `variables` object
2. `{{...;type=X}}` tags become interactive form fields
3. Tags are removed from the final PDF (clean document)
4. Form fields appear at the exact positions where tags were

## Sample Files

| File | Description |
|------|-------------|
| `simple_contract_template.txt` | Basic contract with loops and conditionals |
| `sales_contract_template.txt` | Full-featured sales agreement |
| `test_docx_python.py` | Python script to test DOCX submission API |
| `test_docx_submission.sh` | Shell script for API testing |

## Testing

### Using Python Script

```bash
# Test with a DOCX file
python3 test_docx_python.py your_template.docx https://your-server.com YOUR_API_KEY
```

### Using cURL

```bash
# Encode and submit
DOCX_BASE64=$(base64 -i your_template.docx)
curl -X POST "https://your-server.com/api/submissions/docx" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"documents":[{"name":"doc.docx","file":"'"$DOCX_BASE64"'"}],"submitters":[{"role":"Buyer","email":"test@example.com"}]}'
```

## Debugging

Check server logs for tag processing:

```
DOCX TAG REMOVAL: Starting - found 6 tags in raw XML
DOCX TAG REMOVAL: Strategy 1 (global gsub) removed 6 tags
DOCX TAG REMOVAL: SUCCESS - All tags removed (total: 6)
```

If tags still appear in the final PDF, check:
1. Tag syntax is correct: `{{Name;type=text;role=Buyer}}`
2. Gotenberg service is running
3. No encoding issues in the DOCX file
