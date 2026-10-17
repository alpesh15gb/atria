# Reporting and GST preparation

All 46 catalogue reports resolve through `/reports/:reportId`. They run against the active business and selected date window and export native Excel workbooks. GST reports also link to the GST preparation workspace.

## Filing periods

Choose Monthly or QRMP quarterly in GST Reports. Quarterly GSTR-1 and GSTR-3B include the complete calendar quarter and use its ending month for `fp`/`ret_period` (`062026` for April–June 2026). This is quarterly return preparation, not an IFF or PMT-06 payment workflow. GSTR-2A statements remain keyed to individual months and businesses.

## Files and formats

- GSTR-1: JSON preparation data, section CSVs and an Excel workbook with B2B, B2CL, B2CS, registered/unregistered notes, exports, HSN and documents sheets. Invoice value drives B2CL classification; the limit changes from ₹2.5 lakh to ₹1 lakh in August 2024. HSN JSON separates B2B/B2C from May 2025 and retains rate and UQC distinctions.
- GSTR-3B: JSON preparation data using `gstin`, `ret_period`, `sup_details`, `inter_sup`, `itc_elg` and `inward_sup`; Excel sheets cover supplies, interstate supplies, ITC and inward supplies. IGST/CGST/SGST/cess are separate. Supplier notes net against ordinary ITC, without inventing Rule 42/43 reversals. Reverse-charge liability is independent of credit eligibility.
- GSTR-2A: import downloaded JSON, a ZIP containing JSON parts, or invoice-level B2B XLSX. Imports persist locally per business/month. JSON recipient and period mismatches are rejected. Reconciliation compares supplier GSTIN, invoice number, document kind, taxable value and individual tax heads. JSON credit/debit notes are included. Export Excel, CSV or reconciliation JSON working papers.

## Review before filing

These are preparation workbooks, not the GST offline utility's macro-enabled Excel templates. JSON acceptance by the current GST portal utility has not been verified. The exporter does not invent a GSTN version/hash envelope. Use the current official utility and its validation before upload.

Books cannot determine every statutory adjustment. Review imports, ISD credits, reversals/reclaims, ineligible ITC, expenses whose GST tax heads were not recorded, ECO supplies, amendments, nil/non-GST classification, interest and payment-ledger adjustments. GSTR-2A XLSX import currently covers invoice-level B2B; other statement sections require review. GSTR-2B and eligibility checks are required for ITC preparation; a missing 2A match alone is not an automatic credit decision. Net payable shown from books is an estimate, not a GST cash-ledger settlement.

## Sources checked

- [GST Portal: GSTR-1 preparation](https://tutorial.gst.gov.in/userguide/returns/Creation_of_Outward_Supplies_Return_in_GSTR-1.htm): B2CL cutoff and HSN B2B/B2C changes.
- [GST Portal: Returns Offline Tool manual](https://tutorial.gst.gov.in/downloads/invoiceuploadofflineutility.pdf): official utility and quarter-ending filing period; IFF is separate.
- [GST Portal: GSTR-3B guidance](https://tutorial.gst.gov.in/userguide/returns/GSTR3B.htm): return tables, net ITC and adjustments.
- [GST Portal: GSTR-2B FAQs](https://tutorial.gst.gov.in/userguide/returns/FAQ_gstr2b.htm): ITC statement and downloaded Excel/JSON.
- [GSTZen GSTR-3B save API](https://my.gstzen.in/docs/api/gstr3b-api/gstr3b-retsave/): technical field reference, used alongside official return guidance; not portal acceptance certification.

## Verification

Automated tests resolve every catalogue route, run every source against an isolated database, decode exported Excel files, check GST period/recipient validation, parse ZIP/Excel imports, reconcile notes, verify tax-head serialization and exercise quarterly aggregation. These checks verify application behavior; they do not replace live GST utility validation.
