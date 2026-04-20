# frozen_string_literal: true

class PagesController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check

  USE_CASES = {
    'developers' => {
      title: 'For Developers',
      subtitle: 'Embed e-signatures into your product with a single API call.',
      icon: 'api',
      accent: 'from-indigo-500 to-purple-500',
      hero: 'Ship signing in days, not quarters.',
      intro: 'SealRoute gives engineering teams a clean REST API, webhooks, and a DOCX template pipeline — so you can embed contracts, consents, and signed PDFs directly into your product without gluing together five vendors.',
      scenarios: [
        { title: 'Programmatic document creation', body: 'Generate signed contracts from your backend by POSTing a DOCX with [[variables]] and {{FieldTags}}. SealRoute returns signing URLs for every signer.' },
        { title: 'Webhook-driven workflows', body: 'Listen for form.completed and submission.completed events to kick off billing, provisioning, or downstream notifications.' },
        { title: 'White-label signing', body: 'Drop your logo, stamp, and colors in via API. The signing page looks like your product, not a third-party tool.' },
        { title: 'Self-hosted, on your infrastructure', body: 'Keep PII, PHI, and regulated documents behind your VPC. No data ever leaves your cloud.' },
        { title: 'Audit-ready verification', body: 'Every signed PDF ships with a tamper-evident digital signature and a separate audit trail PDF for compliance reviews.' }
      ],
      features: ['REST API', 'Webhooks', 'DOCX → signed PDF', 'Role-scoped variables', 'Consent capture', 'PDF signature verification']
    },
    'hr' => {
      title: 'For Human Resources',
      subtitle: 'Offer letters, NDAs, onboarding, and policy sign-offs — sent and signed in minutes.',
      icon: 'users',
      accent: 'from-rose-500 to-orange-500',
      hero: 'From offer letter to first day, zero paperwork bottlenecks.',
      intro: 'HR teams use SealRoute to get new hires, contractors, and existing employees through required paperwork quickly — without chasing signatures over email.',
      scenarios: [
        { title: 'Offer letters', body: 'Send an offer with salary, start date, and role pre-filled. Track opens, acceptance, and expiration dates.' },
        { title: 'Employment contracts & NDAs', body: 'Reusable templates for full-time, part-time, contractor, and intern agreements. Sign in-person on a tablet or remotely on mobile.' },
        { title: 'Onboarding packets', body: 'Bundle tax forms, direct-deposit authorizations, handbook acknowledgments, and IT policies into a single signing flow.' },
        { title: 'Policy acknowledgments', body: 'Annual code of conduct, security policy, or harassment training sign-offs — mass-send to the whole company and track completion.' },
        { title: 'Performance reviews & PIPs', body: 'Signed review documents with manager, employee, and HR signatures in a preserved signing order.' }
      ],
      features: ['Bulk sending', 'Reminders & expirations', 'Role-scoped variables', 'Mobile signing', 'Audit trail', 'Document archive']
    },
    'procurement' => {
      title: 'For Procurement',
      subtitle: 'Vendor contracts, purchase orders, and supplier agreements with a full audit trail.',
      icon: 'clipboard',
      accent: 'from-emerald-500 to-teal-500',
      hero: 'Close supplier paperwork without chasing vendors.',
      intro: 'Procurement teams use SealRoute to standardize vendor agreements, track PO approvals, and keep a defensible record of every signed commitment.',
      scenarios: [
        { title: 'Purchase orders', body: 'Auto-populated POs with line items, totals, and delivery dates. Route to approver → finance → vendor in sequence.' },
        { title: 'Master Service Agreements', body: 'Template MSAs with configurable addendums. Negotiated once, reused forever.' },
        { title: 'Vendor onboarding', body: 'W-9/W-8 equivalents, code of conduct acknowledgments, banking info forms — all collected at once.' },
        { title: 'NDAs with suppliers', body: 'Bilateral NDAs generated from a template with vendor name, jurisdiction, and effective dates filled in.' },
        { title: 'Change orders', body: 'Amendments that reference the original contract with a full audit chain.' }
      ],
      features: ['Preserved signing order', 'BCC copies for archives', 'Role-scoped variables', 'Tables in DOCX', 'Reminders', 'Audit trail PDF']
    },
    'finance' => {
      title: 'For Finance',
      subtitle: 'Invoices, payment authorizations, loan agreements, and audit-ready document archives.',
      icon: 'credit_card',
      accent: 'from-amber-500 to-yellow-500',
      hero: 'Financial documents, signed and filed before the close window ends.',
      intro: 'Finance teams use SealRoute for any document that needs a verifiable signature with full audit trail — from payment authorizations to loan packages.',
      scenarios: [
        { title: 'Payment authorizations', body: 'Dual-signature approvals for wire transfers, ACH payments, and vendor disbursements above threshold.' },
        { title: 'Loan agreements & promissory notes', body: 'Pre-filled agreements with principal, interest rate, and repayment schedule. Borrower and co-signer sign in order.' },
        { title: 'Expense policy acknowledgments', body: 'Annual policy sign-offs with a verifiable audit trail to satisfy auditors.' },
        { title: 'Audit and compliance sign-offs', body: 'Attestations, internal-control confirmations, and auditor management letters.' },
        { title: 'Corporate resolutions', body: 'Board and shareholder resolutions with preserved signing order and digital signatures on the final PDF.' }
      ],
      features: ['PDF signature verification', 'Preserved signing order', 'Audit trail PDF', 'Retention-friendly archive', 'Consent capture', 'Webhook to ERP']
    },
    'legal' => {
      title: 'For Legal',
      subtitle: 'Contract lifecycle management with templated clauses, consent capture, and verifiable signatures.',
      icon: 'certificate',
      accent: 'from-slate-500 to-gray-600',
      hero: 'Contracts executed with the same rigor as wet ink — without the wait.',
      intro: 'Legal teams use SealRoute to standardize contract execution, capture informed consent, and produce court-ready records every time.',
      scenarios: [
        { title: 'Client engagement letters', body: 'Scope, fee structure, and conflict waivers generated from a template. Client signs online, firm signs last.' },
        { title: 'Settlement agreements', body: 'Multi-party settlements with preserved signing order, signer verification, and consent capture.' },
        { title: 'Powers of attorney', body: 'Notarial or in-person signing with stamp fields pre-filled. Audit PDF records timestamp, IP, and user agent.' },
        { title: 'Privacy/data-processing consents', body: 'GDPR-style consent flows with a shown-and-accepted terms document, timestamped per signer.' },
        { title: 'Assignment & licensing agreements', body: 'IP assignments and licenses with party-scoped variables so each signer only sees their own details.' }
      ],
      features: ['Digital signatures (PAdES)', 'Tamper-evident PDFs', 'Consent checkbox + URL', 'Audit trail', 'Multi-signer roles', 'Preserved order']
    },
    'sales' => {
      title: 'For Sales',
      subtitle: 'Quotes, MSAs, and order forms closed on any device — no lost deals to paperwork friction.',
      icon: 'arrow_up_right',
      accent: 'from-sky-500 to-blue-600',
      hero: 'Close deals on the call. Sign before the prospect cools off.',
      intro: 'Sales teams use SealRoute to send quotes, order forms, and contracts that sign on phone, tablet, or laptop in minutes — and push the won deal straight into the CRM.',
      scenarios: [
        { title: 'Quotes & order forms', body: 'Auto-populated quotes with line items, discounts, and totals. Prospect signs from any device.' },
        { title: 'MSA + Order Form combos', body: 'Bundle a reusable MSA with a deal-specific order form in a single signing flow.' },
        { title: 'Renewals & upsells', body: 'Pre-fill the incumbent contract with new pricing and terms. One-click sign for the customer.' },
        { title: 'Partner & reseller agreements', body: 'Channel agreements with standardized terms, co-branded with your logo and stamp.' },
        { title: 'Pilot / POC agreements', body: 'Fast-path, short-form agreements to unblock trials and proof-of-concepts.' }
      ],
      features: ['Mobile-first signing', 'CRM webhooks', 'Redirect after sign', 'Custom branding', 'Reminders', 'Completed-at metrics']
    },
    'operations' => {
      title: 'For Operations & Admin',
      subtitle: 'SOPs, equipment checkouts, facility access, and any internal form that needs a signature.',
      icon: 'settings',
      accent: 'from-fuchsia-500 to-pink-500',
      hero: 'Every internal form, signed and filed — no paper, no lost binders.',
      intro: 'Ops teams use SealRoute as the signature layer for every process that used to live in a shared folder of DOCX files.',
      scenarios: [
        { title: 'Equipment checkout forms', body: 'Laptop, phone, and badge assignments with signed acknowledgment of the asset policy.' },
        { title: 'Facility access & visitor logs', body: 'Contractor site-access agreements with timestamped signatures stored per visit.' },
        { title: 'Incident & safety reports', body: 'Structured incident forms with a supervisor countersignature and a verifiable audit trail.' },
        { title: 'SOP & SLA acknowledgments', body: 'Annual review cycles with reminders until every required signer has completed.' },
        { title: 'Travel & expense approvals', body: 'Pre-travel approvals and post-trip expense forms with multi-level sign-off.' }
      ],
      features: ['Unlimited templates', 'Bulk send', 'Reminders', 'Mobile signing', 'Folders & permissions', 'Search across submissions']
    },
    'cooperatives' => {
      title: 'For Cooperatives & Associations',
      subtitle: 'Membership forms, consent to data processing, and AGM resolutions — localized and accessible.',
      icon: 'users_plus',
      accent: 'from-green-500 to-lime-500',
      hero: 'Member-friendly signing, localized and accessible.',
      intro: 'Cooperatives, credit unions, and associations use SealRoute to onboard members, capture data-use consent, and record AGM resolutions with full legal weight.',
      scenarios: [
        { title: 'Membership enrollment', body: 'Member data form with NRP/ID, auto-populated member number, and a data-processing consent acknowledgment.' },
        { title: 'Savings & loan agreements', body: 'Pre-filled loan contracts with installment schedules, co-signers, and witness signatures.' },
        { title: 'AGM resolutions', body: 'Resolutions signed by chair, secretary, and required members in preserved order — archived with the audit PDF.' },
        { title: 'Policy & privacy consents', body: 'Localized (Bahasa Indonesia, English, and more) consent flows satisfying UU PDP / GDPR-style requirements.' },
        { title: 'Committee meeting minutes', body: 'Minutes signed by attending officers and stored with the signed PDF for the audit record.' }
      ],
      features: ['Multi-language UI', 'Consent capture', 'Role-scoped variables', 'DOCX templates', 'Audit trail PDF', 'Self-hosted option']
    }
  }.freeze

  def api_docs
    serve_markdown_doc('API.md', html_title: 'API documentation')
  end

  def template_tags_docs
    serve_markdown_doc('TEMPLATE_TAGS.md', html_title: 'Template tags')
  end

  def pricing; end

  def use_cases_index
    @use_cases = USE_CASES
  end

  def use_case
    slug = params[:slug].to_s
    @use_case_slug = slug
    @use_case = USE_CASES[slug]

    return render 'use_cases/show' if @use_case

    raise ActionController::RoutingError, 'Use case not found'
  end

  private

  def serve_markdown_doc(filename, html_title:)
    mtime = Docs::RenderMarkdown.mtime(filename)
    raise ActionController::RoutingError, I18n.t('not_found') unless mtime

    return unless stale?(etag: "\"docs-#{filename}-#{mtime.to_i}\"", last_modified: mtime, public: true)

    raw_html = Docs::RenderMarkdown.call(filename)
    @html_title = html_title
    @sanitized_html = Docs::HtmlSanitize.call(raw_html).html_safe
    render :api_docs
  end
end
