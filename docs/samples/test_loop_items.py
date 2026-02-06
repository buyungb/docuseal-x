#!/usr/bin/env python3
"""
Test Items Loop API

This script tests the [[for:items]]...[[end]] loop functionality.

Usage:
    python3 test_loop_items.py <docx_file> <api_url> <api_token>

Example:
    python3 test_loop_items.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN
"""

import sys
import json
import base64
import urllib.request
import ssl
from datetime import datetime


def create_test_payload(docx_base64):
    """Create a test payload with multiple items for loop testing."""
    
    invoice_num = f"INV-{int(datetime.now().timestamp())}"
    invoice_date = datetime.now().strftime("%B %d, %Y")
    
    # Test items - these will be looped in the template
    items = [
        {
            "name": "Enterprise Software License",
            "description": "Annual license for up to 100 users",
            "quantity": "1",
            "unit_price": "15000",
            "subtotal": "15000"
        },
        {
            "name": "Implementation Service",
            "description": "On-site implementation and setup",
            "quantity": "40",
            "unit_price": "150",
            "subtotal": "6000"
        },
        {
            "name": "Training Package",
            "description": "2-day onsite training for team",
            "quantity": "1",
            "unit_price": "2500",
            "subtotal": "2500"
        },
        {
            "name": "Support Package",
            "description": "Premium 24/7 support for 1 year",
            "quantity": "1",
            "unit_price": "3000",
            "subtotal": "3000"
        }
    ]
    
    # Calculate totals
    subtotal = sum(int(item["subtotal"]) for item in items)
    discount_percent = 10
    discount_amount = subtotal * discount_percent / 100
    tax_rate = 8
    taxable = subtotal - discount_amount
    tax_amount = taxable * tax_rate / 100
    total = taxable + tax_amount
    
    return {
        "name": f"Loop Test - Invoice {invoice_num}",
        "variables": {
            # Simple variables
            "invoice_number": invoice_num,
            "invoice_date": invoice_date,
            "customer_name": "Acme Corporation",
            "customer_company": "Acme Corp",
            "customer_address": "456 Corporate Blvd, New York, NY",
            "customer_email": "billing@acme.com",
            
            # Company info
            "company_name": "TechVendor Inc.",
            "company_address": "123 Business Ave, San Francisco, CA",
            
            # ITEMS ARRAY - This is what [[for:items]] will loop over
            # Each item should have properties that match [[item.property]]
            "items": items,
            
            # Pricing summary
            "subtotal": str(subtotal),
            "has_discount": True,
            "discount_percent": str(discount_percent),
            "discount_amount": str(int(discount_amount)),
            "tax_rate": str(tax_rate),
            "tax_amount": str(int(tax_amount)),
            "total": str(int(total)),
            
            # Terms
            "payment_days": "30",
            "delivery_days": "14",
            "warranty_months": "12"
        },
        "documents": [{
            "name": "invoice.docx",
            "file": docx_base64
        }],
        "submitters": [
            {
                "role": "Approver",
                "email": "approver@example.com",
                "name": "John Approver"
            }
        ],
        "send_email": False,
        "order": "preserved"
    }


def main():
    if len(sys.argv) < 4:
        print("Usage: python3 test_loop_items.py <docx_file> <api_url> <api_token>")
        print("\nThis script tests the items loop functionality:")
        print("  - [[for:items]]...[[end]] - loops over items array")
        print("  - [[item.name]], [[item.quantity]], etc. - access item properties")
        print("  - [[if:has_discount]]...[[end]] - conditional display")
        sys.exit(1)
    
    docx_file = sys.argv[1]
    api_url = sys.argv[2].rstrip('/')
    api_token = sys.argv[3]
    
    print("=" * 60)
    print("DocuSeal Items Loop Test")
    print("=" * 60)
    print(f"File: {docx_file}")
    print(f"API: {api_url}")
    print()
    
    # Read DOCX file
    print("Reading DOCX file...")
    try:
        with open(docx_file, 'rb') as f:
            docx_data = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {docx_file}")
        sys.exit(1)
    
    if docx_data[:4] != b'PK\x03\x04':
        print("ERROR: File is not a valid DOCX")
        sys.exit(1)
    
    print(f"File size: {len(docx_data)} bytes")
    
    # Encode to base64
    docx_base64 = base64.b64encode(docx_data).decode('ascii')
    
    # Create payload
    payload = create_test_payload(docx_base64)
    
    # Show items that will be looped
    print()
    print("Items to loop (variables.items):")
    print("-" * 40)
    for i, item in enumerate(payload["variables"]["items"], 1):
        print(f"  {i}. {item['name']}")
        print(f"     Qty: {item['quantity']} x ${item['unit_price']} = ${item['subtotal']}")
    print()
    print(f"Subtotal: ${payload['variables']['subtotal']}")
    print(f"Discount: {payload['variables']['discount_percent']}% = -${payload['variables']['discount_amount']}")
    print(f"Tax: {payload['variables']['tax_rate']}% = ${payload['variables']['tax_amount']}")
    print(f"Total: ${payload['variables']['total']}")
    print()
    
    # Send request
    print("Sending request to API...")
    json_data = json.dumps(payload).encode('utf-8')
    
    url = f"{api_url}/api/submissions/docx"
    req = urllib.request.Request(
        url,
        data=json_data,
        headers={
            'Content-Type': 'application/json',
            'X-Auth-Token': api_token
        },
        method='POST'
    )
    
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=300) as response:
            result = response.read().decode('utf-8')
            print()
            print("=" * 60)
            print("SUCCESS - Response:")
            print("=" * 60)
            response_data = json.loads(result)
            print(json.dumps(response_data, indent=2))
            
            # Extract signing URLs
            if isinstance(response_data, list) and len(response_data) > 0:
                print()
                print("Signing URLs:")
                for sub in response_data:
                    for submitter in sub.get('submitters', []):
                        print(f"  - {submitter.get('role', 'Unknown')}: {submitter.get('embed_src', 'N/A')}")
    except urllib.error.HTTPError as e:
        print(f"HTTP Error: {e.code}")
        error_body = e.read().decode('utf-8')
        print(f"Response: {error_body}")
    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")
    
    print()
    print("=" * 60)
    print("Done")
    print("=" * 60)


if __name__ == "__main__":
    main()
