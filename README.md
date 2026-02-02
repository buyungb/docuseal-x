<h1 align="center" style="border-bottom: none">
  <div>
    <a href="https://www.docuseal.com">
      <img  alt="DocuSeal" src="https://github.com/docusealco/docuseal/assets/5418788/c12cd051-81cd-4402-bc3a-92f2cfdc1b06" width="80" />
      <br>
    </a>
    DocuSeal
  </div>
</h1>
<h3 align="center">
  Open source document filling and signing
</h3>
<p align="center">
  <a href="https://hub.docker.com/r/docuseal/docuseal">
    <img alt="Docker releases" src="https://img.shields.io/docker/v/docuseal/docuseal">
  </a>
  <a href="https://discord.gg/qygYCDGck9">
    <img src="https://img.shields.io/discord/1125112641170448454?logo=discord"/>
  </a>
  <a href="https://twitter.com/intent/follow?screen_name=docusealco">
    <img src="https://img.shields.io/twitter/follow/docusealco?style=social" alt="Follow @docusealco" />
  </a>
</p>
<p>
DocuSeal is an open source platform that provides secure and efficient digital document signing and processing. Create PDF forms to have them filled and signed online on any device with an easy-to-use, mobile-optimized web tool.
</p>
<h2 align="center">
  <a href="https://demo.docuseal.tech">✨ Live Demo</a>
  <span>|</span>
  <a href="https://docuseal.com/sign_up">☁️ Try in Cloud</a>
</h2>

[![Demo](https://github.com/docusealco/docuseal/assets/5418788/d8703ea3-361a-423f-8bfe-eff1bd9dbe14)](https://demo.docuseal.tech)

## Features
- PDF form fields builder (WYSIWYG)
- 12 field types available (Signature, Date, File, Checkbox etc.)
- Multiple submitters per document
- Automated emails via SMTP
- Files storage on disk or AWS S3, Google Storage, Azure Cloud
- Automatic PDF eSignature
- PDF signature verification
- Users management
- Role-based access control (Admin, Editor, Viewer)
- **Conditional fields and formulas**
- **2FA verification** via webhook (integrate with SMS, WhatsApp, Telegram, email, or any service)
- **Signing invitations** via webhook (SMS, WhatsApp, email services, or any custom integration)
- **Email reminders configuration** (requires scheduled job setup)
- Consent document requirement before signing
- Mobile-optimized
- 7 UI languages with signing available in 14 languages
- API and Webhooks for integrations
- Easy to deploy in minutes

## Pro Features (Official DocuSeal Pro)
- Company logo and white-label
- User roles
- Automated reminders (fully managed)
- Bulk send with CSV, XLSX spreadsheet import
- SSO / SAML
- Template creation with HTML API ([Guide](https://www.docuseal.com/guides/create-pdf-document-fillable-form-with-html-api))
- Template creation with PDF or DOCX and field tags API ([Guide](https://www.docuseal.com/guides/use-embedded-text-field-tags-in-the-pdf-to-create-a-fillable-form))
- Embedded signing form ([React](https://github.com/docusealco/docuseal-react), [Vue](https://github.com/docusealco/docuseal-vue), [Angular](https://github.com/docusealco/docuseal-angular) or [JavaScript](https://www.docuseal.com/docs/embedded))
- Embedded document form builder ([React](https://github.com/docusealco/docuseal-react), [Vue](https://github.com/docusealco/docuseal-vue), [Angular](https://github.com/docusealco/docuseal-angular) or [JavaScript](https://www.docuseal.com/docs/embedded))
- [Learn more](https://www.docuseal.com/pricing)

## Deploy

|Heroku|Railway|
|:--:|:---:|
| [<img alt="Deploy on Heroku" src="https://www.herokucdn.com/deploy/button.svg" height="40">](https://heroku.com/deploy?template=https://github.com/docusealco/docuseal-heroku) | [<img alt="Deploy on Railway" src="https://railway.app/button.svg" height="40">](https://railway.app/template/IGoDnc?referralCode=ruU7JR)|
|**DigitalOcean**|**Render**|
| [<img alt="Deploy on DigitalOcean" src="https://www.deploytodo.com/do-btn-blue.svg" height="40">](https://cloud.digitalocean.com/apps/new?repo=https://github.com/docusealco/docuseal-digitalocean/tree/master&refcode=421d50f53990) | [<img alt="Deploy to Render" src="https://render.com/images/deploy-to-render-button.svg" height="40">](https://render.com/deploy?repo=https://github.com/docusealco/docuseal-render)

#### Docker

```sh
docker run --name docuseal -p 3000:3000 -v.:/data docuseal/docuseal
```

By default DocuSeal docker container uses an SQLite database to store data and configurations. Alternatively, it is possible use PostgreSQL or MySQL databases by specifying the `DATABASE_URL` env variable.

#### Docker Compose

Download docker-compose.yml into your private server:
```sh
curl https://raw.githubusercontent.com/docusealco/docuseal/master/docker-compose.yml > docker-compose.yml
```

Run the app under a custom domain over https using docker compose (make sure your DNS points to the server to automatically issue ssl certs with Caddy):
```sh
sudo HOST=your-domain-name.com docker compose up
```

#### Updating Docker Deployment

When updating to a new version, pull the latest image and run database migrations:

```sh
# Pull the latest image
docker pull docuseal/docuseal

# Restart the container (or use docker compose pull && docker compose up -d)
docker compose up -d
git 
# Run database migrations (app is located in /app directory)
docker exec -it -w /app <container_name> bundle exec rails db:migrate
```

> **Why run migrations?** Database migrations apply schema changes required by new features (new tables, columns, indexes). Without running migrations after an update, new features may not work correctly or the application may encounter errors when accessing updated database structures.

## Custom Features

### Conditional Fields and Formulas

This fork enables conditional fields and formulas in the template builder:

- **Conditional Fields**: Show or hide fields based on other field values. Click on a field and look for the "Conditions" option in field settings.
- **Formulas**: Create calculated number fields based on other field values. Useful for totals, tax calculations, etc.

### Email Reminders

Configure automatic email reminders in **Settings > Notifications**:
- Set up to 3 reminder intervals (first, second, third reminder)
- Available durations: 1 hour to 30 days

> **Note**: The reminder configuration UI is enabled, but automatic sending requires setting up a scheduled job (cron/sidekiq-scheduler) to process pending reminders.

### 2FA Verification Webhook

Send signing invitations and OTP verification codes via webhook to any messaging service. Configure in **Settings > 2FA Webhook**:

- **Webhook URL**: Your messaging service endpoint (SMS gateway, WhatsApp API, Telegram bot, email service, etc.)
- **Bearer Token**: Optional authentication token

**Supported integrations:**
- SMS gateways (Twilio, Vonage, MessageBird, etc.)
- WhatsApp Business API
- Telegram Bot API
- Email services (SendGrid, Mailgun, etc.)
- Any custom webhook endpoint

#### Invitation Webhook
When a submitter has a phone number, the system sends an invitation webhook:
```json
{
  "event_type": "invitation",
  "phone_number": "+1234567890",
  "sign_url": "https://your-domain.com/s/abc123",
  "timestamp": "2024-01-15T10:30:00Z",
  "submitter_id": 123,
  "submitter_email": "user@example.com",
  "submitter_name": "John Doe",
  "submission_id": 456,
  "template_name": "Contract Template",
  "template_id": 789,
  "message": "You have been invited to sign: Contract Template. Click here to sign: https://..."
}
```

Your webhook endpoint can use the `phone_number`, `submitter_email`, or `submitter_name` to route the message to SMS, WhatsApp, email, or any other channel.

#### 2FA OTP Webhook
When 2FA is enabled for a template, the system sends an OTP verification code:
```json
{
  "event_type": "otp_verification",
  "phone_number": "+1234567890",
  "otp": "123456",
  "timestamp": "2024-01-15T10:30:00Z",
  "submitter_id": 123,
  "submitter_email": "user@example.com",
  "submitter_name": "John Doe",
  "submission_id": 456,
  "template_name": "Contract Template"
}
```

### 2FA for Templates

Require verification before signers can access the signing form:

1. Go to **Template > Preferences > Form Preferences**
2. Enable "Require phone 2FA to open" or "Require email 2FA to open"
3. Signers will receive an OTP code via your configured 2FA webhook (SMS, WhatsApp, email, etc.) before accessing the form

### Consent Document Requirement

Require signers to acknowledge terms and conditions before signing. Configure at two levels:

1. **Account Level** (Settings > Consent Document): Set default consent URL and text
2. **Template Level** (Template > Preferences > Form Preferences): Enable/disable per template with optional overrides

When enabled, signers must view the document and check the consent checkbox before accessing the signing form.

### Role-Based Access Control

Three user roles with different permissions:
- **Admin**: Full access to all resources
- **Editor**: Can manage their own templates and submissions
- **Viewer**: Read-only access to shared resources

Templates and folders can be shared between users for collaboration.

### DOCX Dynamic Content Variables API

Create personalized documents from DOCX templates with dynamic content variables. Send a DOCX file with variables to auto-generate submissions.

**API Endpoint:** `POST /api/submissions/docx`

**Variable Syntax:**
- Simple variables: `[[variable_name]]`
- Conditionals: `[[if:is_vip]]VIP content[[else]]Regular content[[end]]`
- Loops: `[[for:items]][[item.name]] - [[item.price]][[end]]`

**Example Request:**
```javascript
const response = await fetch('/api/submissions/docx', {
  method: 'POST',
  headers: {
    'X-Auth-Token': 'YOUR_API_KEY',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    name: 'Sales Contract',
    variables: {
      customer_name: 'John Doe',
      is_vip: true,
      items: [
        { name: 'Product A', quantity: 2, price: '100.00' },
        { name: 'Product B', quantity: 1, price: '50.00' }
      ]
    },
    documents: [{
      name: 'contract.docx',
      file: '<base64-encoded-docx>'
    }],
    submitters: [{
      role: 'Customer',
      email: 'john@example.com'
    }]
  })
});
```

### PDF Embedded Text Tags API

Create fillable forms from PDFs containing embedded text tags. Tags are automatically converted to interactive form fields.

**API Endpoint:** `POST /api/submissions/pdf`

**Tag Syntax:** `{{FieldName;type=signature;role=Signer;required=true}}`

**Supported Field Types:**
- `text`, `signature`, `initials`, `date`, `datenow`
- `image`, `file`, `checkbox`, `select`, `radio`, `multiple`
- `phone`, `number`, `stamp`, `verification`, `kba`

**Tag Attributes:**
- `type`: Field type (default: text)
- `role`: Signer role name
- `required`: true/false (default: true)
- `readonly`: true/false (default: false)
- `default`: Default value
- `options`: Comma-separated options for select/radio
- `format`: Date format (e.g., DD/MM/YYYY) or signature format
- `width`, `height`: Field dimensions in pixels

**Example Tags in PDF:**
```
Customer Name: {{Customer Name;type=text;required=true}}
Signature: {{Sign;type=signature;role=Customer}}
Date: {{Date;type=datenow;readonly=true}}
Agreement: {{Agree;type=checkbox}}
Plan: {{Plan;type=select;options=Basic,Pro,Enterprise}}
```

**Example Request:**
```javascript
const response = await fetch('/api/submissions/pdf', {
  method: 'POST',
  headers: {
    'X-Auth-Token': 'YOUR_API_KEY',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    name: 'Agreement',
    documents: [{
      name: 'agreement.pdf',
      file: '<base64-encoded-pdf>'
    }],
    submitters: [{
      role: 'Customer',
      email: 'customer@example.com'
    }]
  })
});
```

## For Businesses
### Integrate seamless document signing into your web or mobile apps with DocuSeal

At DocuSeal we have expertise and technologies to make documents creation, filling, signing and processing seamlessly integrated with your product. We specialize in working with various industries, including **Banking, Healthcare, Transport, Real Estate, eCommerce, KYC, CRM, and other software products** that require bulk document signing. By leveraging DocuSeal, we can assist in reducing the overall cost of developing and processing electronic documents while ensuring security and compliance with local electronic document laws.

[Book a Meeting](https://www.docuseal.com/contact)

## License

Distributed under the AGPLv3 License. See [LICENSE](https://github.com/docusealco/docuseal/blob/master/LICENSE) for more information.
Unless otherwise noted, all files © 2023 DocuSeal LLC.

## Tools

- [Signature Maker](https://www.docuseal.com/online-signature)
- [Sign Document Online](https://www.docuseal.com/sign-documents-online)
- [Fill PDF Online](https://www.docuseal.com/fill-pdf)
