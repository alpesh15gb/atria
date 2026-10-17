# Document formats — 11 October 2026

## Customer controls

Open **Settings → Document formats** (desktop: the Business section). Company profile also includes the same chooser.

Choose **Default for all documents** to set the shared format. Choose **Invoices**, **Purchases**, or **Quotations** to set a separate format. Turn **Use shared default** on to remove that override. Save applies the choices to subsequent previews, printing, sharing and PDF exports; saved transaction amounts are unchanged.

The five choices are:

1. **Classic** — the existing Apex Books layout, retained.
2. **Ledger** — reference 1: boxed title/company/customer header, tax-rate and unit columns, totals in the item grid, HSN summary, bank/QR and signatory block, split notes/terms.
3. **Clean** — reference 2: open company/document header, bill/ship address columns, ruled item grid, bank/QR beside totals, open notes and signatory.
4. **Business** — reference 3: open company header, boxed customer and dispatch metadata, compact item table, words/payment block beside totals, HSN summary and notes/signatory.
5. **Detailed** — reference 4: boxed header, spacious item grid with taxable/tax columns, totals below, HSN summary, bank/QR and signatory, split notes/terms.

Typography, rules and section placement follow the supplied layouts. Spacing adapts to actual line lengths, tax slabs and page breaks. The seller's own logo and details are used. Reference company logos, signatures, invented IRNs/e-way bills and the false claim “digitally signed” are not copied. The current data model supports a signatory name, not a signature-image upload or e-invoice compliance fields; those elements cannot be reproduced from real data yet.

## Persistence and accounting

The existing synchronized `firms.pdf_template` preference stores either a legacy ID or a versioned JSON document containing the shared default and three overrides. No schema migration or backend deployment is required. Old Modern/Minimal preferences still print through their old renderers, while the chooser offers the requested five formats.

The shared reference renderer consumes saved document amounts. It preserves GST/non-GST behavior, stored tax amounts, mixed tax rates, HSN grouping, cess, discounts, freight, other purchase charges, TCS, TDS deductions, round-off, payment status and cancellation. A quotation never asks for payment. QR requests use an unpaid invoice's remaining balance; purchases never use the buyer's collection QR. Printed files do not mutate the source records.

## Verification

- Full Flutter suite: **1,172 passed**.
- Analyzer across `lib`, `test` and the audit renderer: **no issues**.
- Chooser interaction at 360×640 and 1280×850 verifies default inheritance, separate choices, resetting an override and correct document previews.
- Local two-device journal test verifies all three format preferences arrive unchanged on a fresh device.
- All 15 format/document combinations rendered and text bounds checked. New reference samples fit on one page; the existing Classic renderer retains its previous pagination.
- All 100 sale and purchase line labels verified in each reference layout, alongside GST/non-GST, paid, cancelled and quotation checks.
- Rendered sample pages visually inspected, including the two-level HSN tax headings, item wrapping and footer sections. Audit PDFs/PNGs are under `build/import-audit/document-formats/`; sample PDFs are under `output/pdf/`.

## Local builds

- `dist/ApexBooks-Windows-2026-10-11-formats.zip` — complete Windows release package.
- `dist/ApexBooks-Android-debug-2026-10-11-formats.apk` — Android debug build.

No deployment or live business-data changes were performed. Android remains debug-signed; no Android hardware pass is claimed.
