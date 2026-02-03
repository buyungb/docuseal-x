#!/usr/bin/env python3
"""
Test DOCX Submission API

Usage:
    python3 test_docx_python.py <docx_file> <api_url> <api_token>
    
Example:
    python3 test_docx_python.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN
"""

import sys
import json
import base64
import urllib.request
import ssl
from datetime import datetime

def main():
    # Parse arguments
    if len(sys.argv) < 4:
        print("Usage: python3 test_docx_python.py <docx_file> <api_url> <api_token>")
        print("Example: python3 test_docx_python.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN")
        sys.exit(1)
    
    docx_file = sys.argv[1]
    api_url = sys.argv[2].rstrip('/')
    api_token = sys.argv[3]
    
    print(f"=== DocuSeal DOCX Submission Test (Python) ===")
    print(f"File: {docx_file}")
    print(f"API: {api_url}")
    print()
    
    # Read and encode DOCX file
    print("Reading DOCX file...")
    try:
        with open(docx_file, 'rb') as f:
            docx_data = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {docx_file}")
        sys.exit(1)
    
    print(f"File size: {len(docx_data)} bytes")
    print(f"First 4 bytes: {list(docx_data[:4])}")
    
    # Verify it's a valid DOCX/ZIP
    if docx_data[:4] != b'PK\x03\x04':
        print("ERROR: File does not appear to be a valid DOCX (missing PK header)")
        sys.exit(1)
    
    print("Encoding to base64...")
    docx_base64 = base64.b64encode(docx_data).decode('ascii')
    print(f"Base64 length: {len(docx_base64)} characters")
    
    # Verify base64 encoding roundtrip
    decoded_check = base64.b64decode(docx_base64)
    if decoded_check != docx_data:
        print("ERROR: Base64 encoding/decoding mismatch!")
        sys.exit(1)
    print("Base64 roundtrip verified OK")
    
    # Build request payload
    contract_num = f"SC-{int(datetime.now().timestamp())}"
    contract_date = datetime.now().strftime("%B %d, %Y")
    
    payload = {
        "name": "Sales Contract - Python Test",
        "variables": {
            "contract_number": contract_num,
            "contract_date": contract_date,
            "company_name": "TechVendor Inc.",
            "company_address": "123 Business Ave, San Francisco, CA",
            "sales_rep_name": "Jane Smith",
            "sales_rep_email": "jane@techvendor.com",
            "customer_name": "John Doe",
            "customer_company": "Acme Corporation",
            "customer_address": "456 Corporate Blvd, New York, NY",
            "customer_phone": "+1 555 123 4567",
            "customer_email": "john@acme.com",
            "items": [
                {
                    "name": "Enterprise Software License",
                    "description": "1-year license",
                    "quantity": "1",
                    "unit_price": "15000",
                    "subtotal": "15000"
                },
                {
                    "name": "Training",
                    "description": "2-day training",
                    "quantity": "1",
                    "unit_price": "2500",
                    "subtotal": "2500"
                }
            ],
            "subtotal": "17500",
            "has_discount": True,
            "discount_percent": "10",
            "discount_amount": "1750",
            "tax_rate": "10",
            "tax_amount": "1575",
            "total": "17325",
            "payment_installment": False,
            "payment_days": "30",
            "delivery_days": "14",
            "warranty_months": "12",
            "jurisdiction": "California"
        },
        "documents": [{
            "name": "contract.docx",
            "file": docx_base64
        }],
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
        ],
        "send_email": False,
        "order": "preserved"
    }
    
    # Convert to JSON
    json_data = json.dumps(payload).encode('utf-8')
    print(f"JSON payload size: {len(json_data)} bytes")
    
    # Make request
    print()
    print("Sending request to API...")
    
    url = f"{api_url}/api/submissions/docx"
    
    # Create request
    req = urllib.request.Request(
        url,
        data=json_data,
        headers={
            'Content-Type': 'application/json',
            'X-Auth-Token': api_token
        },
        method='POST'
    )
    
    # Disable SSL verification for self-signed certs
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as response:
            result = response.read().decode('utf-8')
            print()
            print("=== Response ===")
            print(json.dumps(json.loads(result), indent=2))
    except urllib.error.HTTPError as e:
        print(f"HTTP Error: {e.code}")
        error_body = e.read().decode('utf-8')
        print(f"Response: {error_body}")
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")
    
    print()
    print("=== Done ===")

if __name__ == "__main__":
    main()
