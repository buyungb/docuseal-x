#!/usr/bin/env python3
"""
Test DOCX Submission API with simple_contract_template.txt

This script tests the /api/submissions/docx endpoint with all the variables
and form fields defined in simple_contract_template.txt.

Usage:
    python3 test_docx_python.py <docx_file> <api_url> <api_token>
    
Example:
    python3 test_docx_python.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN

Template Variables (replaced by API):
    [[contract_number]], [[contract_date]]
    [[company_name]], [[company_address]]
    [[customer_name]], [[customer_company]], [[customer_address]], [[customer_email]]
    [[for:items]] with [[item.name]], [[item.description]], [[item.quantity]], [[item.unit_price]], [[item.subtotal]]
    [[subtotal]], [[has_discount]], [[discount_percent]], [[discount_amount]]
    [[tax_rate]], [[tax_amount]], [[total]]
    [[payment_days]], [[delivery_days]], [[warranty_months]]
    [[special_terms]] (optional)
    [[prepared_by]], [[prepared_date]]

Form Fields (interactive, for signers):
    {{BuyerSign;type=signature;role=Buyer;required=true}}
    {{BuyerName;type=text;role=Buyer}}
    {{BuyerDate;type=datenow;role=Buyer}}
    {{SellerSign;type=signature;role=Seller;required=true}}
    {{SellerName;type=text;role=Seller}}
    {{SellerDate;type=datenow;role=Seller}}
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
    
    print("=== DocuSeal DOCX Submission Test (Python) ===")
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
    
    # Build request payload matching simple_contract_template.txt
    contract_num = f"SC-{int(datetime.now().timestamp())}"
    contract_date = datetime.now().strftime("%B %d, %Y")
    prepared_date = datetime.now().strftime("%B %d, %Y")
    
    payload = {
        "name": f"Simple Contract - {contract_num}",
        "variables": {
            # Contract header
            "contract_number": contract_num,
            "contract_date": contract_date,
            
            # Seller (company) info
            "company_name": "TechVendor Inc.",
            "company_address": "123 Business Ave, San Francisco, CA 94102",
            
            # Buyer (customer) info
            "customer_name": "John Doe",
            "customer_company": "Acme Corporation",
            "customer_address": "456 Corporate Blvd, New York, NY 10001",
            "customer_email": "john.doe@acme.com",
            
            # Order items (loop)
            "items": [
                {
                    "name": "Enterprise Software License",
                    "description": "Annual subscription - 50 users",
                    "quantity": "1",
                    "unit_price": "15,000.00",
                    "subtotal": "15,000.00"
                },
                {
                    "name": "Professional Training",
                    "description": "2-day on-site training session",
                    "quantity": "1",
                    "unit_price": "2,500.00",
                    "subtotal": "2,500.00"
                },
                {
                    "name": "Technical Support",
                    "description": "12-month premium support package",
                    "quantity": "1",
                    "unit_price": "3,000.00",
                    "subtotal": "3,000.00"
                }
            ],
            
            # Pricing
            "subtotal": "20,500.00",
            "has_discount": True,           # Enable discount section
            "discount_percent": "10",
            "discount_amount": "2,050.00",
            "tax_rate": "8.5",
            "tax_amount": "1,568.25",
            "total": "20,018.25",
            
            # Terms
            "payment_days": "30",
            "delivery_days": "14",
            "warranty_months": "12",
            
            # Optional special terms (set to False to hide section)
            "special_terms": "Early payment discount: 2% if paid within 10 days.",
            
            # Signature section
            "prepared_by": "Sales Department",
            "prepared_date": prepared_date
        },
        "documents": [{
            "name": docx_file,
            "file": docx_base64
        }],
        "submitters": [
            {
                "role": "Buyer",
                "email": "buyung@aplindo.tech",
                "name": "John Doe",
                "phone": "+62811192575"
            },
            {
                "role": "Seller",
                "email": "anggit@aplindo.tech",
                "name": "Jane Smith",
                "phone": "+6281770938580"
            }
        ],
        "send_email": False,
        "order": "preserved"
    }
    
    # Print variables being sent
    print()
    print("Variables being sent:")
    for key, value in payload["variables"].items():
        if key == "items":
            print(f"  {key}: [{len(value)} items]")
            for i, item in enumerate(value):
                print(f"    [{i}] {item['name']}: {item['quantity']} x ${item['unit_price']}")
        elif isinstance(value, bool):
            print(f"  {key}: {value}")
        else:
            print(f"  {key}: {value[:50]}..." if len(str(value)) > 50 else f"  {key}: {value}")
    
    print()
    print(f"Submitters: {[s['role'] + ' (' + s['email'] + ')' for s in payload['submitters']]}")
    
    # Convert to JSON
    json_data = json.dumps(payload).encode('utf-8')
    print()
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
        with urllib.request.urlopen(req, context=ctx, timeout=300) as response:
            result = response.read().decode('utf-8')
            data = json.loads(result)
            
            print()
            print("=== SUCCESS ===")
            print(f"Created {len(data)} submitter(s):")
            print()
            
            for submitter in data:
                print(f"  {submitter.get('role', 'Unknown')}:")
                print(f"    ID: {submitter.get('id')}")
                print(f"    Name: {submitter.get('name')}")
                print(f"    Email: {submitter.get('email')}")
                print(f"    Status: {submitter.get('status')}")
                print(f"    Signing URL: {submitter.get('embed_src')}")
                print()
            
            print("Full response:")
            print(json.dumps(data, indent=2))
            
    except urllib.error.HTTPError as e:
        print()
        print(f"=== ERROR ===")
        print(f"HTTP Error: {e.code}")
        error_body = e.read().decode('utf-8')
        try:
            error_json = json.loads(error_body)
            print(f"Error: {json.dumps(error_json, indent=2)}")
        except:
            print(f"Response: {error_body}")
    except Exception as e:
        print()
        print(f"=== ERROR ===")
        print(f"Error: {type(e).__name__}: {e}")
    
    print()
    print("=== Done ===")


if __name__ == "__main__":
    main()
