#!/bin/bash

# =============================================================================
# Test DOCX Submission API
# =============================================================================
# Usage: 
#   ./test_docx_submission.sh <docx_file> <api_url> <api_token>
#
# Example:
#   ./test_docx_submission.sh simple_contract.docx https://your-docuseal.com YOUR_API_TOKEN
# =============================================================================

# Configuration - Edit these values or pass as arguments
API_URL="${2:-https://your-docuseal.com}"
API_TOKEN="${3:-YOUR_API_TOKEN}"
DOCX_FILE="${1:-simple_contract.docx}"
BUYER_EMAIL="buyung@aplindo.tech"
SELLER_EMAIL="anggit@aplindo.tech"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}=== DocuSeal DOCX Submission Test ===${NC}"
echo ""

# Check if DOCX file exists
if [ ! -f "$DOCX_FILE" ]; then
    echo -e "${RED}Error: DOCX file not found: $DOCX_FILE${NC}"
    exit 1
fi

echo -e "DOCX File: ${GREEN}$DOCX_FILE${NC}"
echo -e "API URL: ${GREEN}$API_URL${NC}"
echo -e "Buyer Email: ${GREEN}$BUYER_EMAIL${NC}"
echo -e "Seller Email: ${GREEN}$SELLER_EMAIL${NC}"
echo ""

# Encode DOCX to base64 (using strict base64 encoding)
echo "Encoding DOCX to base64..."
DOCX_BASE64=$(base64 -i "$DOCX_FILE" | tr -d '\n\r')

# Verify base64 encoding
echo "Base64 length: ${#DOCX_BASE64} characters"

# Create temp files
TEMP_JSON=$(mktemp)
TEMP_BASE64=$(mktemp)

# Save base64 to temp file to avoid shell interpretation issues
echo -n "$DOCX_BASE64" > "$TEMP_BASE64"

CONTRACT_NUM="SC-$(date +%s)"
CONTRACT_DATE=$(date +"%B %d, %Y")

# Create JSON using python to properly escape the base64 string
python3 << PYTHON_SCRIPT > "$TEMP_JSON"
import json

# Read base64 from file
with open("$TEMP_BASE64", "r") as f:
    docx_base64 = f.read()

data = {
    "name": "Sales Contract - Test",
    "variables": {
        "contract_number": "${CONTRACT_NUM}",
        "contract_date": "${CONTRACT_DATE}",
        "company_name": "TechVendor Inc.",
        "company_address": "123 Business Ave, Suite 100, San Francisco, CA 94102",
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
                "unit_price": "15000.00",
                "subtotal": "15000.00"
            },
            {
                "name": "Implementation Services",
                "description": "On-site setup and configuration",
                "quantity": "40",
                "unit_price": "150.00",
                "subtotal": "6000.00"
            },
            {
                "name": "Training Package",
                "description": "2-day admin training",
                "quantity": "1",
                "unit_price": "2500.00",
                "subtotal": "2500.00"
            }
        ],
        "subtotal": "23500.00",
        "has_discount": True,
        "discount_percent": "10",
        "discount_amount": "2350.00",
        "tax_rate": "8.5",
        "tax_amount": "1797.75",
        "total": "22947.75",
        "payment_installment": False,
        "payment_days": "30",
        "delivery_days": "14",
        "warranty_months": "12",
        "jurisdiction": "State of California",
        "special_terms": "Extended support included for first 90 days at no additional cost."
    },
    "documents": [{
        "name": "sales_contract.docx",
        "file": docx_base64
    }],
    "submitters": [
        {
            "role": "Buyer",
            "email": "${BUYER_EMAIL}",
            "name": "John Doe"
        },
        {
            "role": "Seller",
            "email": "${SELLER_EMAIL}",
            "name": "Jane Smith"
        }
    ],
    "send_email": True,
    "order": "preserved"
}

print(json.dumps(data))
PYTHON_SCRIPT

rm -f "$TEMP_BASE64"

echo "Sending request to API..."
echo ""

# Make API request using the temp file (-k to ignore SSL cert errors)
curl -s -k -X POST "${API_URL}/api/submissions/docx" \
  -H "X-Auth-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @"$TEMP_JSON" | python3 -m json.tool 2>/dev/null || cat

# Cleanup
rm -f "$TEMP_JSON"

echo ""
echo -e "${GREEN}=== Request Complete ===${NC}"
