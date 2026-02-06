#!/usr/bin/env python3
"""
Test DOCX Submission API for Surat Keterangan Domisili V2 (DocuSeal)

Reference: test_docx_python.py (DocuSeal /api/submissions/docx flow)

Usage:
    python3 test_surat_domisili_docx.py <docx_file> <api_url> <api_token>

Example:
    python3 test_surat_domisili_docx.py Surat_Keterangan_Domisili_Kop_V2_Docuseal_Tags.docx https://your-docuseal.com YOUR_TOKEN

Template Variables (UPPERCASE) expected in the DOCX:
    [[KOP_SURAT]]
    [[NOMOR_URUT]]
    [[RT]], [[RW]]
    [[DESA]], [[KEC]], [[TYPE_KAB]], [[KAB]], [[PROV]]
    [[IDENTITAS]], [[NO_IDENTITAS]]
    [[NAMA_TERMOHON]], [[TEMPAT_LAHIR]], [[TTG_TERMOHON]]
    [[GENDER_TERMOHON]], [[KERJA_TERMOHON]], [[AGAMA_TERMOHON]]
    [[MARITAL]], [[NEGARA]], [[ALAMAT_TERMOHON]]
    [[KEPERLUAN]]
    [[KAB_RW]], [[CURRENT_DATE_RW]]
    [[KAB_RT]], [[CURRENT_DATE_RT]]
    [[MENGETAHUI_RW]], [[MENGETAHUI_RT]]
    [[KETUA_RW]]
    [[PEJABAT_RW]], [[PEJABAT_RT]]

Form Fields expected in the DOCX:
    {{TTD;type=signature;role=Signer;required=true}}

Notes:
- This template has ONE signer with role "Signer"
- All variables use UPPERCASE names
"""

import sys
import json
import base64
import urllib.request
import urllib.error
import ssl
from datetime import datetime


def build_payload(docx_file: str, signer_email: str = "signer@example.com", 
                  signer_name: str = "Penandatangan", signer_phone: str = "+628111111111") -> dict:
    now = datetime.now()
    
    # Format date in Indonesian
    months_id = {
        1: "Januari", 2: "Februari", 3: "Maret", 4: "April",
        5: "Mei", 6: "Juni", 7: "Juli", 8: "Agustus",
        9: "September", 10: "Oktober", 11: "November", 12: "Desember"
    }
    current_date_id = f"{now.day} {months_id[now.month]} {now.year}"

    # Variables matching the DOCX template (UPPERCASE)
    variables = {
        # Header
        "KOP_SURAT": "PEMERINTAH KOTA JAKARTA SELATAN\nKELURAHAN KEBAYORAN BARU\nRUKUN TETANGGA (RT) / RUKUN WARGA (RW)",
        "NOMOR_URUT": f"SKD/{int(now.timestamp()) % 10000}/{now.strftime('%m')}/{now.year}",
        
        # Location
        "RT": "005",
        "RW": "003",
        "DESA": "Kebayoran Baru",
        "KEC": "Kebayoran Baru",
        "TYPE_KAB": "Kota",
        "KAB": "Jakarta Selatan",
        "PROV": "DKI Jakarta",
        
        # Identity
        "IDENTITAS": "NIK",
        "NO_IDENTITAS": "3174012345678901",
        
        # Personal data of the applicant (termohon)
        "NAMA_TERMOHON": "Budi Santoso",
        "TEMPAT_LAHIR": "Jakarta",
        "TTG_TERMOHON": "01 Januari 1990",  # Tanggal lahir termohon
        "GENDER_TERMOHON": "Laki-laki",
        "KERJA_TERMOHON": "Karyawan Swasta",
        "AGAMA_TERMOHON": "Islam",
        "MARITAL": "Kawin",
        "NEGARA": "WNI",
        "ALAMAT_TERMOHON": "Jl. Sudirman No. 123",
        
        # Purpose
        "KEPERLUAN": "Pengurusan Administrasi Kependudukan",
        
        # RW Section
        "KAB_RW": "Jakarta Selatan,",
        "CURRENT_DATE_RW": current_date_id,
        "MENGETAHUI_RW": "Mengetahui,",
        "KETUA_RW": "Ketua RW. 003",
        "PEJABAT_RW": "H. Ahmad Suryadi",
        
        # RT Section
        "KAB_RT": "Jakarta Selatan,",
        "CURRENT_DATE_RT": current_date_id,
        "MENGETAHUI_RT": "Yang Menerangkan,",
        "PEJABAT_RT": "Drs. Bambang Wijaya",
    }

    # Read and base64 encode DOCX
    with open(docx_file, "rb") as f:
        docx_data = f.read()

    if docx_data[:4] != b"PK\x03\x04":
        raise ValueError("File does not appear to be a valid DOCX (missing PK header).")

    docx_base64 = base64.b64encode(docx_data).decode("ascii")

    payload = {
        "name": f"Surat Keterangan Domisili - {variables['NOMOR_URUT']}",
        "variables": variables,
        "documents": [{
            "name": docx_file,
            "file": docx_base64
        }],
        "submitters": [
            {
                "role": "Signer",  # Must match {{TTD;type=signature;role=Signer}}
                "email": signer_email,
                "name": signer_name,
                "phone": signer_phone
            }
        ],
        "send_email": False,
        "order": "preserved"
    }

    return payload


def main():
    if len(sys.argv) < 4:
        print("Usage: python3 test_surat_domisili_docx.py <docx_file> <api_url> <api_token> [signer_email] [signer_name] [signer_phone]")
        print()
        print("Example:")
        print("  python3 test_surat_domisili_docx.py Surat_Keterangan_Domisili_Kop_V2_Docuseal_Tags.docx https://your-docuseal.com YOUR_TOKEN")
        print()
        print("With custom signer:")
        print("  python3 test_surat_domisili_docx.py template.docx https://api.com TOKEN john@example.com 'John Doe' +628123456789")
        sys.exit(1)

    docx_file = sys.argv[1]
    api_url = sys.argv[2].rstrip("/")
    api_token = sys.argv[3]
    
    # Optional signer info
    signer_email = sys.argv[4] if len(sys.argv) > 4 else "signer@example.com"
    signer_name = sys.argv[5] if len(sys.argv) > 5 else "Penandatangan"
    signer_phone = sys.argv[6] if len(sys.argv) > 6 else "+628111111111"

    print("=== DocuSeal DOCX Submission Test (Surat Keterangan Domisili V2) ===")
    print(f"File: {docx_file}")
    print(f"API:  {api_url}")
    print(f"Signer: {signer_name} <{signer_email}> {signer_phone}")
    print()

    try:
        payload = build_payload(docx_file, signer_email, signer_name, signer_phone)
    except FileNotFoundError:
        print(f"ERROR: File not found: {docx_file}")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR building payload: {type(e).__name__}: {e}")
        sys.exit(1)

    # Quick summary
    print("Variables being sent:")
    for k, v in payload["variables"].items():
        sv = str(v)
        print(f"  {k}: {sv[:60]}{'...' if len(sv) > 60 else ''}")

    print()
    print("Submitters:")
    for s in payload["submitters"]:
        print(f"  - {s['role']}: {s['name']} <{s['email']}>")

    # Convert payload to JSON
    json_data = json.dumps(payload).encode("utf-8")
    print()
    print(f"JSON payload size: {len(json_data)} bytes")
    print("Sending request to API...")

    url = f"{api_url}/api/submissions/docx"
    req = urllib.request.Request(
        url,
        data=json_data,
        headers={
            "Content-Type": "application/json",
            "X-Auth-Token": api_token
        },
        method="POST"
    )

    # Disable SSL verification for self-signed certs (same approach as reference)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, context=ctx, timeout=300) as response:
            result = response.read().decode("utf-8")
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
            print(json.dumps(data, indent=2, ensure_ascii=False))

    except urllib.error.HTTPError as e:
        print()
        print("=== ERROR ===")
        print(f"HTTP Error: {e.code}")
        error_body = e.read().decode("utf-8")
        try:
            error_json = json.loads(error_body)
            print(json.dumps(error_json, indent=2, ensure_ascii=False))
        except Exception:
            print(error_body)

    except Exception as e:
        print()
        print("=== ERROR ===")
        print(f"Error: {type(e).__name__}: {e}")

    print()
    print("=== Done ===")


if __name__ == "__main__":
    main()
