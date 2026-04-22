#!/usr/bin/env python3
"""
Test DOCX Submission API with template_kopsyar.docx

Formulir Verifikasi Anggota Koperasi Karyawan Unit Syariah Astra Honda Motor.
This script hits POST /api/submissions/docx with the DOCX encoded in base64,
pre-fills the [[...]] text variables, and pre-fills the {{...}} form fields
for the "Petugas" (officer) role so a single click by the officer can finalize
the form. The "Pemohon" (applicant) only has to review and sign.

IMPORTANT: upload `template_kopsyar.fixed.docx`, NOT the original
`template_kopsyar.docx`. Microsoft Word split several {{...}} tags across
multiple <w:r>/<w:t> XML runs in the original file, which causes the tag
parser to render the raw text instead of a form field. Run this first:

    python3 fix_docx_tag_runs.py template_kopsyar.docx template_kopsyar.fixed.docx

then pass the fixed DOCX to this script. See fix_docx_tag_runs.py for the
full explanation.

Usage:
    python3 test_kopsyar_docx.py <docx_file> <api_url> <api_token> [command]

Commands:
    (default)         Create a DOCX submission for the Kopsyar form
    webhook:list      List existing outgoing webhooks
    webhook:create    Register a webhook URL. Extra args: <url> [event1,event2,...]
    webhook:test      Send a test form.completed event. Extra args: <webhook_id>
    webhook:delete    Delete a webhook. Extra args: <webhook_id>

Examples:
    python3 test_kopsyar_docx.py template_kopsyar.fixed.docx https://api.sealroute.com YOUR_TOKEN
    python3 test_kopsyar_docx.py _ https://api.sealroute.com YOUR_TOKEN webhook:list

Template variables ([[...]] replaced by API before rendering):
    [[nama_pemohon]]   Applicant full name (appears in body AND under signature)
    [[nrp]]            Employee ID (NRP)
    [[nama_petugas]]   Officer full name (appears under officer signature line)

Form fields ({{...}} interactive, pre-fillable via submitters[].values):

  Role "Pemohon" (applicant):
    SignPemohon                 (signature, required)

  Role "Petugas" (officer):
    -- membership status (checkbox group, tick ONE) --
    "Bukan Anggota koperasi"    (checkbox)   tick if NOT a member
    "Anggota Koperasi"          (checkbox)   tick if MEMBER
    -- obligation status (checkbox group, tick ONE) --
    "Tidak Punya Kewajiban"     (checkbox)   no outstanding obligations
    "Punya Kewajiban"           (checkbox)   has outstanding obligations
    -- Dana Anggota (member funds, rupiah amounts, text) --
    IuranPokok                  (text)   pokok contribution
    IuranWajib                  (text)   wajib contribution
    IuranSukarela               (text)   sukarela contribution
    IuranKhusus                 (text)   khusus contribution
    -- Kewajiban Anggota (obligation rows, description + nominal) --
    Kewajiban1                  (text)   obligation 1 description
    NilaiKwjbn1                 (text)   obligation 1 value
    Kewajiban2                  (text)
    NilaiKwjbn2                 (text)
    Kewajiban3                  (text)
    NilaiKwjbn3                 (text)
    -- Recommendation (checkbox group, tick ONE) --
    Direkomendasikan            (checkbox)   recommended
    Tidak_direkomendasikan      (checkbox)   not recommended
    -- Verification date + officer signature --
    TglVerifikasi               (date, DD/MM/YYYY)
    SignPetugas                 (signature, required)

Flow: Pemohon signs first, then Petugas reviews the pre-filled officer
section, ticks/edits any changes, adds their date + signature, and submits.
Set "order": "preserved" so the applicant cannot skip ahead.

Tip: to make the Petugas fill everything from scratch at signing time, drop
the "values" block from the Petugas submitter. The fields will render empty
for the officer to complete live.
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
    if len(sys.argv) < 4:
        print("Usage: python3 test_kopsyar_docx.py <docx_file> <api_url> <api_token> [command ...]")
        print("Example: python3 test_kopsyar_docx.py template_kopsyar.docx https://api.sealroute.com YOUR_TOKEN")
        print("See the module docstring for webhook subcommands.")
        sys.exit(1)

    docx_file = sys.argv[1]
    api_url = sys.argv[2].rstrip('/')
    api_token = sys.argv[3]

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

    print("=== SealRoute Kopsyar DOCX Submission Test (Python) ===")
    print(f"File: {docx_file}")
    print(f"API: {api_url}")
    print()

    print("Reading DOCX file...")
    try:
        with open(docx_file, 'rb') as f:
            docx_data = f.read()
    except FileNotFoundError:
        print(f"ERROR: File not found: {docx_file}")
        sys.exit(1)

    print(f"File size: {len(docx_data)} bytes")
    print(f"First 4 bytes: {list(docx_data[:4])}")

    if docx_data[:4] != b'PK\x03\x04':
        print("ERROR: File does not appear to be a valid DOCX (missing PK header)")
        sys.exit(1)

    print("Encoding to base64...")
    docx_base64 = base64.b64encode(docx_data).decode('ascii')
    print(f"Base64 length: {len(docx_base64)} characters")

    decoded_check = base64.b64decode(docx_base64)
    if decoded_check != docx_data:
        print("ERROR: Base64 encoding/decoding mismatch!")
        sys.exit(1)
    print("Base64 roundtrip verified OK")

    today_ddmmyyyy = datetime.now().strftime("%d/%m/%Y")
    submission_stamp = datetime.now().strftime("%Y%m%d-%H%M%S")

    # Sample applicant + officer identities (adjust freely)
    nama_pemohon = "Budi Santoso"
    nrp           = "AHM-20250012"
    nama_petugas  = "Siti Rahmawati"

    payload = {
        "name": f"Verifikasi Anggota Koperasi - {nama_pemohon} ({submission_stamp})",

        # [[...]] variables: substituted into the DOCX body before rendering.
        # These are top-level so both submitters see the same rendered copy.
        "variables": {
            "nama_pemohon": nama_pemohon,
            "nrp":          nrp,
            "nama_petugas": nama_petugas,
        },

        "documents": [{
            "name": docx_file,
            "file": docx_base64,
        }],

        # Sign order: Pemohon (applicant) first, then Petugas (officer) who
        # reviews + ticks the officer-side fields and signs last to approve.
        "submitters": [
            {
                "role":  "Pemohon",
                "email": "budi.santoso@example.com",
                "name":  nama_pemohon,
                "phone": "+6281234567890",
                # No values to pre-fill: the applicant only signs.
            },
            {
                "role":  "Petugas",
                "email": "siti.rahmawati@example.com",
                "name":  nama_petugas,
                "phone": "+6281200000001",

                # submitters[].values pre-fills {{...}} form fields. The officer
                # can still edit any of these at signing time before submitting.
                # Note: field names with spaces must match the DOCX tag exactly.
                "values": {
                    # --- membership status ---
                    "Bukan Anggota koperasi": False,
                    "Anggota Koperasi":       True,

                    # --- obligation status ---
                    "Tidak Punya Kewajiban":  False,
                    "Punya Kewajiban":        True,

                    # --- Dana Anggota (rupiah, text fields) ---
                    "IuranPokok":    "250.000",
                    "IuranWajib":    "1.200.000",
                    "IuranSukarela": "500.000",
                    "IuranKhusus":   "100.000",

                    # --- Kewajiban Anggota (obligation rows) ---
                    "Kewajiban1":  "Pinjaman Multiguna",
                    "NilaiKwjbn1": "3.500.000",
                    "Kewajiban2":  "Pinjaman Elektronik",
                    "NilaiKwjbn2": "1.250.000",
                    "Kewajiban3":  "",
                    "NilaiKwjbn3": "",

                    # --- Recommendation ---
                    "Direkomendasikan":       True,
                    "Tidak_direkomendasikan": False,

                    # --- Verification date (DD/MM/YYYY per the DOCX tag) ---
                    "TglVerifikasi": today_ddmmyyyy,
                },
            },
        ],

        # Custom invitation email (Indonesian). Body is Markdown and supports
        # {template.name}, {submitter.name}, {submitter.email}, {submitter.link},
        # {account.name}, {submission.submitters}.
        "message": {
            "subject": "Mohon tanda tangan: {template.name}",
            "body": (
                "Halo {submitter.name},\n\n"
                "Anda diundang oleh **{account.name}** untuk meninjau dan "
                "menandatangani dokumen **{template.name}**.\n\n"
                "[Buka dokumen dan tanda tangan]({submitter.link})\n\n"
                "Jika ada pertanyaan, silakan balas email ini.\n\n"
                "Terima kasih,\n"
                "{account.name}"
            ),
        },

        # Flip to True to send the email invitations. Leave False during dev
        # to inspect the returned embed_src signing URLs instead.
        "send_email": False,

        # Force applicant-then-officer order.
        "order": "preserved",

        # Optional branding (per-submission). Remove if you rely on account
        # defaults configured in the SealRoute admin settings.
        "company_name": "Koperasi Karyawan Unit Syariah AHM",
        # "logo_url":   "https://your-host/assets/kopsyar-logo.png",
        # "stamp_url":  "https://your-host/assets/kopsyar-stamp.png",

        # Attach audit-log PDF to completion emails for compliance.
        "preferences": {
            "completed_notification_email_attach_audit": True,
            "documents_copy_email_attach_audit": True,
        },
    }

    print()
    print("Variables being sent:")
    for key, value in payload["variables"].items():
        print(f"  {key}: {value}")

    print()
    print("Submitters:")
    for s in payload["submitters"]:
        print(f"  - {s['role']}: {s['name']} <{s['email']}>")
        if s.get("values"):
            print(f"    pre-filled values ({len(s['values'])} fields):")
            for k, v in s["values"].items():
                print(f"      {k!r}: {v!r}")

    json_data = json.dumps(payload).encode('utf-8')
    print()
    print(f"JSON payload size: {len(json_data)} bytes")

    print()
    print("=== FULL PAYLOAD (base64 file truncated) ===")
    payload_preview = json.loads(json_data)
    for doc in payload_preview.get("documents", []):
        file_b64 = doc.get("file", "")
        doc["file"] = f"{file_b64[:60]}...({len(file_b64)} chars)"
    print(json.dumps(payload_preview, indent=2, default=str))
    print("=== END PAYLOAD ===")

    print()
    print("Sending request to API...")

    url = f"{api_url}/api/submissions/docx"
    req = urllib.request.Request(
        url,
        data=json_data,
        headers={
            'Content-Type': 'application/json',
            'X-Auth-Token': api_token,
        },
        method='POST',
    )

    try:
        with urllib.request.urlopen(req, context=_ssl_ctx(), timeout=300) as response:
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
        except Exception:
            print(f"Response: {error_body}")
    except Exception as e:
        print()
        print(f"=== ERROR ===")
        print(f"Error: {type(e).__name__}: {e}")

    print()
    print("=== Done ===")


if __name__ == "__main__":
    main()
