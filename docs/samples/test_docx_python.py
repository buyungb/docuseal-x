#!/usr/bin/env python3
"""
Test DOCX Submission API with simple_contract_template.txt

This script tests the /api/submissions/docx endpoint with all the variables
and form fields defined in simple_contract_template.txt.

Usage:
    python3 test_docx_python.py <docx_file> <api_url> <api_token> [command]

Commands:
    (default)         Create a DOCX submission (with optional custom email message)
    webhook:list      List existing outgoing webhooks
    webhook:create    Register a webhook URL. Extra args: <url> [event1,event2,...]
    webhook:test      Send a test form.completed event. Extra args: <webhook_id>
    webhook:delete    Delete a webhook. Extra args: <webhook_id>

Examples:
    python3 test_docx_python.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN
    python3 test_docx_python.py _ https://your-docuseal.com YOUR_TOKEN webhook:list
    python3 test_docx_python.py _ https://your-docuseal.com YOUR_TOKEN \
        webhook:create https://example.com/hook form.completed,submission.completed
    python3 test_docx_python.py _ https://your-docuseal.com YOUR_TOKEN webhook:test 1

Note on "custom message to the user":
    SealRoute has TWO separate features here — do not confuse them.

    1. Custom invitation EMAIL to each signer (what the signer receives)
       Set `message: { subject, body }` on the submission (top-level) and/or on
       each `submitters[]` entry. Per-submitter overrides top-level. The `body`
       is Markdown and supports merge tags:
           {template.name}              - submission/template name
           {submitter.link}             - the per-signer signing URL (required
                                          if you override body, otherwise the
                                          signer has no way to open the form)
           {submitter.name}             - signer display name
           {submitter.email}            - signer email
           {account.name}               - your account/company name
           {submission.submitters}      - comma list of all signers
       Emails are only sent when `send_email: true` (default). If you set
       `send_email: false` the message block is ignored — use `embed_src` from
       the API response to deliver the link yourself.

    2. Outgoing WEBHOOKS (server-to-server notifications to YOUR endpoint)
       Webhooks are configured via `/api/webhooks` (admin token required).
       They flow OUT of SealRoute to a URL you own when events occur
       (form.viewed, form.started, form.completed, form.declined,
       submission.created, submission.completed, submission.expired,
       submission.archived, template.created, template.updated).
       There is no API to push an arbitrary message INTO the signer via a
       webhook — webhooks notify your backend, and your backend can then
       deliver whatever custom message you want (SMS, Slack, push, etc.).

    See docs/API.md §"Webhooks" for full payload format.

Template Variables (replaced by API):
    Keys for [[...]] (and {{...}} without type) can be sent as top-level "variables" and/or
    nested under each submitter as submitters[].variables (merged in order; later submitters
    override duplicate keys). submitters[].values only pre-fills {{...;type=...}} form fields.

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
    {{OwnerSign;type=signature;role=Owner;required=true}}
    {{OwnerName;type=text;role=Owner}}
    {{OwnerDate;type=datenow;role=Owner}}

API Branding (no DOCX tag needed - set via API parameters):
    logo_url: URL to company logo image (shown in signing form, emails, audit trail)
    company_name: Company display name (replaces "DocuSeal" in UI)
    stamp_url: URL to stamp image (used in {{stamp}} fields in signed PDFs, falls back to logo_url)
"""

import sys
import json
import base64
import urllib.request
import urllib.error
import ssl
from datetime import datetime


def _ssl_ctx():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def api_request(method, api_url, api_token, path, body=None, timeout=60):
    """Minimal JSON helper for calling SealRoute's REST API."""
    url = f"{api_url}{path}"
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            'Content-Type': 'application/json',
            'X-Auth-Token': api_token,
        },
        method=method,
    )
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=timeout) as resp:
            raw = resp.read().decode('utf-8')
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode('utf-8')
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {'error': raw}


def cmd_webhook_list(api_url, api_token):
    code, data = api_request('GET', api_url, api_token, '/api/webhooks')
    print(f"GET /api/webhooks -> {code}")
    print(json.dumps(data, indent=2))


def cmd_webhook_create(api_url, api_token, hook_url, events_csv=None):
    body = {'url': hook_url}
    if events_csv:
        body['events'] = [e.strip() for e in events_csv.split(',') if e.strip()]
    # Optional shared secret header your endpoint can verify:
    body['secret'] = {'X-Webhook-Secret': 'change-me'}
    code, data = api_request('POST', api_url, api_token, '/api/webhooks', body)
    print(f"POST /api/webhooks -> {code}")
    print(json.dumps(data, indent=2))


def cmd_webhook_test(api_url, api_token, webhook_id):
    code, data = api_request('POST', api_url, api_token,
                             f'/api/webhooks/{webhook_id}/test')
    print(f"POST /api/webhooks/{webhook_id}/test -> {code}")
    print(json.dumps(data, indent=2))


def cmd_webhook_delete(api_url, api_token, webhook_id):
    code, data = api_request('DELETE', api_url, api_token,
                             f'/api/webhooks/{webhook_id}')
    print(f"DELETE /api/webhooks/{webhook_id} -> {code}")
    print(json.dumps(data, indent=2))


def main():
    # Parse arguments
    if len(sys.argv) < 4:
        print("Usage: python3 test_docx_python.py <docx_file> <api_url> <api_token> [command ...]")
        print("Example: python3 test_docx_python.py simple_contract.docx https://your-docuseal.com YOUR_TOKEN")
        print("See the module docstring for webhook subcommands.")
        sys.exit(1)

    docx_file = sys.argv[1]
    api_url = sys.argv[2].rstrip('/')
    api_token = sys.argv[3]

    # Optional subcommand (webhook management etc.)
    if len(sys.argv) >= 5:
        command = sys.argv[4]
        extra = sys.argv[5:]
        if command == 'webhook:list':
            return cmd_webhook_list(api_url, api_token)
        if command == 'webhook:create':
            if not extra:
                print("webhook:create requires <url> [event1,event2,...]")
                sys.exit(1)
            return cmd_webhook_create(api_url, api_token, extra[0],
                                      extra[1] if len(extra) > 1 else None)
        if command == 'webhook:test':
            if not extra:
                print("webhook:test requires <webhook_id>")
                sys.exit(1)
            return cmd_webhook_test(api_url, api_token, extra[0])
        if command == 'webhook:delete':
            if not extra:
                print("webhook:delete requires <webhook_id>")
                sys.exit(1)
            return cmd_webhook_delete(api_url, api_token, extra[0])
        print(f"Unknown command: {command}")
        sys.exit(1)
    
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
            "prepared_date": prepared_date,
        },
        "documents": [{
            "name": docx_file,
            "file": docx_base64
        }],
        "submitters": [
            # {
            #     "role": "anggota",
            #     "email": "muhammad@aplindo.tech",
            #     "name": "Muhammad",
            #     "phone": "+6282112517078",
            #     # Role-scoped [[...]] keys (merged into substitution map by the API)
            #     "variables": {
            #         "Nama_Anggota": "Muhammad",
            #         "NRP_Anggota": "1234567890",
            #     },
            # }, 
            {
                "role": "Buyer",
                "email": "buyung@aplindo.tech",
                "name": "John Doe",
                "phone": "+62811192575",
                # Per-submitter message override (takes precedence over the
                # top-level `message` below). Useful when different roles need
                # different instructions. Uncomment to use.
                # "message": {
                #     "subject": "Action required: sign {template.name} as Buyer",
                #     "body": (
                #         "Hi {submitter.name},\n\n"
                #         "Please review and sign **{template.name}** as the Buyer.\n\n"
                #         "[Open the document]({submitter.link})\n\n"
                #         "Reply to this email if anything looks off.\n\n"
                #         "— {account.name}"
                #     ),
                # },
            },
            {
                "role": "Seller",
                "email": "anggit@aplindo.tech",
                "name": "Jane Smith",
                "phone": "+6281770938580"
            },
            {
                "role": "Owner",
                "email": "bahari.buyung@gmail.com",
                "name": "Dudung",
                "phone": "+6281770938806"
            }
        ],
        # Custom invitation email for every submitter (overridable per-submitter).
        # Only delivered when send_email is True. Body is Markdown and supports
        # merge tags: {template.name}, {submitter.name}, {submitter.email},
        # {submitter.link}, {account.name}, {submission.submitters}.
        "message": {
            "subject": "Please sign: {template.name}",
            "body": (
                "Hi {submitter.name},\n\n"
                "You've been invited by **{account.name}** to sign "
                "**{template.name}**.\n\n"
                "[Review and sign]({submitter.link})\n\n"
                "If you have any questions, just reply to this email.\n\n"
                "Thanks,\n"
                "{account.name}"
            ),
        },
        "send_email": False,
        "order": "preserved",
        # Custom branding (applied to signing UI, emails, and audit trail)
        "logo_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Google_2015_logo.svg/200px-Google_2015_logo.svg.png",
        "company_name": "TechVendor Inc.",
        # Custom stamp image (used in {{stamp}} fields in signed PDFs, falls back to logo_url)
        "stamp_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/2/2f/Google_2015_logo.svg/200px-Google_2015_logo.svg.png",
        # Template preferences (override account-level defaults)
        #   completed_notification_email_attach_audit: attach audit log PDF to the
        #     sender's completion-notification email
        #   documents_copy_email_attach_audit: attach audit log PDF to the
        #     signer copy email
        "preferences": {
            "completed_notification_email_attach_audit": True,
            "documents_copy_email_attach_audit": True
        }
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

    # Print the full payload (base64 file data truncated for readability)
    print()
    print("=== FULL PAYLOAD ===")
    payload_preview = json.loads(json_data)
    for doc in payload_preview.get("documents", []):
        file_b64 = doc.get("file", "")
        doc["file"] = f"{file_b64[:60]}...({len(file_b64)} chars)"
    print(json.dumps(payload_preview, indent=2, default=str))
    print("=== END PAYLOAD ===")
    
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
