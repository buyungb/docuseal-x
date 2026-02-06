# Phone OTP Webhook (2FA SMS Verification)

This webhook enables you to send phone-based two-factor authentication (2FA) OTP codes via your own SMS provider. When a submitter with `require_phone_2fa: true` tries to access the signing form, DocuSeal will call your webhook endpoint with the OTP code instead of sending it directly.

## Use Cases

- Use your own SMS gateway (Twilio, AWS SNS, etc.)
- Custom SMS branding and formatting
- Cost control over SMS sending
- Integration with existing notification systems

## Configuration

### Via Settings UI

1. Go to **Settings** → **Phone OTP Webhook**
2. Enter your webhook URL
3. Optionally add a Bearer token for authentication
4. Save

### Environment/Admin API

The webhook is stored in `EncryptedConfig` with key `phone_otp_webhook`:

```json
{
  "url": "https://your-server.com/webhooks/phone-otp",
  "bearer_token": "your-secret-token"
}
```

## Webhook Payload

When a submitter needs phone verification, DocuSeal sends a POST request:

```json
{
  "phone_number": "+628123456789",
  "otp": "123456",
  "timestamp": "2026-02-06T10:30:00Z",
  "submitter_id": 123,
  "submitter_email": "john@example.com",
  "submitter_name": "John Doe",
  "submission_id": 456,
  "template_name": "Contract Agreement"
}
```

### Payload Fields

| Field | Type | Description |
|-------|------|-------------|
| `phone_number` | string | Submitter's phone number (E.164 format) |
| `otp` | string | 6-digit OTP code to send via SMS |
| `timestamp` | string | ISO 8601 timestamp when the OTP was generated |
| `submitter_id` | integer | Unique identifier of the submitter |
| `submitter_email` | string | Submitter's email address (if provided) |
| `submitter_name` | string | Submitter's name (if provided) |
| `submission_id` | integer | Unique identifier of the submission |
| `template_name` | string | Name of the template |

### Request Headers

```http
POST /webhooks/phone-otp HTTP/1.1
Content-Type: application/json
Accept: application/json
Authorization: Bearer your-secret-token
```

The `Authorization` header is only included if you configured a bearer token.

## Expected Response

Your webhook should return a `2xx` status code to indicate success:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"status": "sent"}
```

If your webhook returns a non-2xx status, DocuSeal will log the failure and the OTP will not be considered delivered.

## OTP Validity

- OTP codes are valid for **10 minutes** (drift behind window)
- OTP codes are **6 digits**
- Generated using TOTP (Time-based One-Time Password) algorithm with SHA1
- A new code is generated every 30 seconds (standard TOTP interval)

## Enabling Phone 2FA in API

To require phone verification for a submitter, use the `require_phone_2fa` parameter:

### Create Submission with Phone 2FA

```bash
curl -X POST "https://api.docuseal.com/submissions" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "template_id": 123,
    "submitters": [
      {
        "role": "Signer",
        "email": "signer@example.com",
        "phone": "+628123456789",
        "require_phone_2fa": true
      }
    ]
  }'
```

### Using /api/submissions/docx

```bash
curl -X POST "https://api.docuseal.com/api/submissions/docx" \
  -H "X-Auth-Token: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "My Document",
    "documents": [{"name": "doc.docx", "file": "BASE64_ENCODED_DOCX"}],
    "submitters": [
      {
        "role": "Signer",
        "email": "signer@example.com",
        "phone": "+628123456789",
        "require_phone_2fa": true
      }
    ]
  }'
```

## Submitter Parameters for 2FA

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `require_phone_2fa` | boolean | false | Require phone OTP verification to access documents |
| `require_email_2fa` | boolean | false | Require email OTP verification to access documents |
| `phone` | string | - | Phone number (required if `require_phone_2fa: true`) |
| `email` | string | - | Email address (required if `require_email_2fa: true`) |

## Example Webhook Handler (Python)

```python
from flask import Flask, request, jsonify
import requests

app = Flask(__name__)

@app.route('/webhooks/phone-otp', methods=['POST'])
def handle_phone_otp():
    data = request.json
    
    phone_number = data['phone_number']
    otp_code = data['otp']
    submitter_name = data.get('submitter_name', 'User')
    
    # Send SMS via your provider (e.g., Twilio)
    message = f"Your verification code is: {otp_code}"
    
    # Example with Twilio
    # from twilio.rest import Client
    # client = Client(TWILIO_SID, TWILIO_TOKEN)
    # client.messages.create(
    #     body=message,
    #     from_='+1234567890',
    #     to=phone_number
    # )
    
    print(f"Sending OTP {otp_code} to {phone_number}")
    
    return jsonify({"status": "sent"}), 200

if __name__ == '__main__':
    app.run(port=5000)
```

## Example Webhook Handler (Node.js)

```javascript
const express = require('express');
const app = express();

app.use(express.json());

app.post('/webhooks/phone-otp', (req, res) => {
    const { phone_number, otp, submitter_name, template_name } = req.body;
    
    console.log(`Sending OTP ${otp} to ${phone_number}`);
    
    // Send SMS via your provider
    // Example with Twilio:
    // const twilio = require('twilio')(TWILIO_SID, TWILIO_TOKEN);
    // await twilio.messages.create({
    //     body: `Your verification code is: ${otp}`,
    //     from: '+1234567890',
    //     to: phone_number
    // });
    
    res.json({ status: 'sent' });
});

app.listen(5000);
```

## Security Considerations

1. **Validate Bearer Token**: Always verify the `Authorization` header matches your configured token
2. **Use HTTPS**: Ensure your webhook endpoint uses HTTPS
3. **Rate Limiting**: Implement rate limiting on your webhook endpoint
4. **Logging**: Log all OTP requests for audit purposes
5. **Don't Store OTPs**: Never store OTP codes; they're time-based and will expire

## Troubleshooting

### Webhook Not Being Called

1. Check that the Phone OTP Webhook URL is configured in Settings
2. Verify the submitter has `require_phone_2fa: true`
3. Ensure the submitter has a valid phone number

### OTP Verification Failing

1. OTP codes expire after 10 minutes
2. Ensure the user enters the code exactly as received (6 digits)
3. Check server time synchronization (NTP)

### Webhook Returning Errors

Check the submission events for `send_2fa_phone` event type which includes:
- `webhook_status`: HTTP status code returned
- `webhook_success`: Boolean indicating success

## Related

- [Form Webhook](./form-webhook.md) - Form events (viewed, started, completed)
- [Submission Webhook](./submission-webhook.md) - Submission lifecycle events
- [Template Webhook](./template-webhook.md) - Template events
