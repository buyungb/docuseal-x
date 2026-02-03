#!/bin/bash

# =============================================================================
# Simple DOCX Submission Test
# =============================================================================
# Quick test script - just edit the config below and run!
# =============================================================================

# ============ EDIT THESE VALUES ============
API_URL="https://app-docuseal-efewx1-8bf21e-20-198-225-77.traefik.me"
API_TOKEN="YOUR_API_TOKEN_HERE"
DOCX_FILE="simple_contract.docx"
BUYER_EMAIL="buyer@example.com"
SELLER_EMAIL="seller@example.com"
# ==========================================

echo "=== DocuSeal DOCX Submission Test ==="
echo ""
echo "API: $API_URL"
echo "File: $DOCX_FILE"
echo ""

# Check file exists
if [ ! -f "$DOCX_FILE" ]; then
    echo "ERROR: File not found: $DOCX_FILE"
    echo ""
    echo "Create the DOCX file first:"
    echo "1. Copy content from simple_contract_template.txt to Word/Google Docs"
    echo "2. Save as simple_contract.docx in this folder"
    exit 1
fi

# Encode to base64
echo "Encoding file..."
DOCX_B64=$(base64 -i "$DOCX_FILE" | tr -d '\n')

echo "Sending request..."
echo ""

# API Request (-k to ignore SSL certificate errors)
curl -k -X POST "${API_URL}/api/submissions/docx" \
  -H "X-Auth-Token: ${API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Test Contract",
    "variables": {
      "contract_number": "TEST-001",
      "contract_date": "February 3, 2026",
      "company_name": "My Company Inc.",
      "company_address": "123 Main Street, City",
      "customer_name": "Test Customer",
      "customer_company": "Customer Corp",
      "customer_address": "456 Oak Avenue",
      "customer_email": "customer@test.com",
      "items": [
        {
          "name": "Product A",
          "description": "First product",
          "quantity": "2",
          "unit_price": "500.00",
          "subtotal": "1,000.00"
        },
        {
          "name": "Service B", 
          "description": "Consulting service",
          "quantity": "10",
          "unit_price": "100.00",
          "subtotal": "1,000.00"
        }
      ],
      "subtotal": "2,000.00",
      "has_discount": true,
      "discount_percent": "10",
      "discount_amount": "200.00",
      "tax_rate": "10",
      "tax_amount": "180.00",
      "total": "1,980.00",
      "payment_days": "30",
      "delivery_days": "7",
      "warranty_months": "12",
      "special_terms": "Free support for 30 days."
    },
    "documents": [{
      "name": "contract.docx",
      "file": "'"${DOCX_B64}"'"
    }],
    "submitters": [
      {"role": "Buyer", "email": "'"${BUYER_EMAIL}"'", "name": "Test Buyer"},
      {"role": "Seller", "email": "'"${SELLER_EMAIL}"'", "name": "Test Seller"}
    ],
    "send_email": false
  }'

echo ""
echo ""
echo "=== Done ==="
