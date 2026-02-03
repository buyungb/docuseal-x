#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to generate sample sales_contract.docx template
# Run: ruby docs/samples/generate_sales_contract.rb

require 'docx'

output_path = File.join(__dir__, 'sales_contract.docx')

# Create a new DOCX document
Docx::Document.open(nil) do |doc|
  # Unfortunately the docx gem doesn't support creating from scratch easily
  # We'll create a text file template instead
end

# Since creating DOCX from scratch is complex, let's create a text template
# that can be copied into Word/Google Docs

template_content = <<~TEMPLATE
                        SALES AGREEMENT
                        Contract #: [[contract_number]]
                        Date: [[contract_date]]

  ═══════════════════════════════════════════════════════════════════════

  SELLER INFORMATION
  ───────────────────────────────────────────────────────────────────────
  Company: [[company_name]]
  Address: [[company_address]]
  Contact: [[sales_rep_name]] | [[sales_rep_email]]

  BUYER INFORMATION
  ───────────────────────────────────────────────────────────────────────
  Name: [[customer_name]]
  Company: [[customer_company]]
  Address: [[customer_address]]
  Phone: [[customer_phone]]
  Email: [[customer_email]]

  ═══════════════════════════════════════════════════════════════════════

  PRODUCTS/SERVICES

  [[for:items]]
  ┌─────────────────────────────────────────────────────────────────────┐
  │ [[item.name]]                                                       │
  │ Description: [[item.description]]                                   │
  │ Quantity: [[item.quantity]] × $[[item.unit_price]]                  │
  │ Subtotal: $[[item.subtotal]]                                        │
  └─────────────────────────────────────────────────────────────────────┘
  [[end]]

  ═══════════════════════════════════════════════════════════════════════

  PRICING SUMMARY
  ───────────────────────────────────────────────────────────────────────
                                              Subtotal: $[[subtotal]]
  [[if:has_discount]]
                                Discount ([[discount_percent]]%): -$[[discount_amount]]
  [[end]]
                                        Tax ([[tax_rate]]%): $[[tax_amount]]
                                              ────────────────────────
                                              TOTAL: $[[total]]

  ═══════════════════════════════════════════════════════════════════════

  PAYMENT TERMS
  ───────────────────────────────────────────────────────────────────────
  [[if:payment_installment]]
  Payment Plan: [[installment_count]] monthly payments of $[[installment_amount]]
  First Payment Due: [[first_payment_date]]
  [[else]]
  Payment Due: Net [[payment_days]] days from contract date
  [[end]]

  ═══════════════════════════════════════════════════════════════════════

  TERMS AND CONDITIONS
  ───────────────────────────────────────────────────────────────────────

  1. Delivery will be completed within [[delivery_days]] business days.
  2. Warranty period: [[warranty_months]] months from delivery date.
  3. This agreement is governed by the laws of [[jurisdiction]].

  [[if:special_terms]]
  SPECIAL TERMS:
  [[special_terms]]
  [[end]]

  ═══════════════════════════════════════════════════════════════════════

  SIGNATURES

  By signing below, both parties agree to the terms stated above.


  BUYER                                         SELLER
  ─────────────────────────────────────         ─────────────────────────────────────


  {{BuyerSign;type=signature;role=Buyer}}       {{SellerSign;type=signature;role=Seller}}


  Name: {{BuyerName;type=text;role=Buyer}}      Name: {{SellerName;type=text;role=Seller}}


  Date: {{BuyerDate;type=datenow;role=Buyer}}   Date: {{SellerDate;type=datenow;role=Seller}}


  Initials: {{BuyerInit;type=initials;role=Buyer}}   {{SellerInit;type=initials;role=Seller}}

  ═══════════════════════════════════════════════════════════════════════
TEMPLATE

# Write the text template
text_output = File.join(__dir__, 'sales_contract_template.txt')
File.write(text_output, template_content)
puts "Created: #{text_output}"
puts "\nTo create DOCX:"
puts "1. Open Microsoft Word or Google Docs"
puts "2. Copy the content from sales_contract_template.txt"
puts "3. Save as sales_contract.docx"
puts "\nOr use the online converter at https://cloudconvert.com/txt-to-docx"
