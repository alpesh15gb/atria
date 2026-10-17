# Document, reporting and workflow repairs

## Fixed

- Sales and purchase Convert now use `convertFrom`, and Duplicate uses `from`. The real sales conversion route loads saved lines. Conversion keeps source tax rates, modes, precision and place of supply.
- Sales invoice creation and estimate source-linking now commit together. A second editor trying to convert the same source cannot leave another invoice behind.
- Opening a quotation no longer replaces its saved GST rates with current item-master defaults. Quantity, rate and discount inputs retain stored precision. Saving without editing preserves its total.
- Estimates have no Balance column/amount in desktop lists and no collection balance in their detail hero. They remain paper-only documents in settlement logic.
- Open estimates display Open rather than Paid; their zero settlement balance no longer determines the workflow badge.
- Desktop transaction pages use the available width. Invoice details no longer have a 1080px content cap or an empty expanded header.
- `MoneyText(shrinkToFit: true)` now contains the amount widget. This repairs blank invoice totals and other fitted currency values.
- Every reference document item table now has horizontal item separators, matching the already-bordered standard templates.
- Report Excel/CSV/PDF/JSON exports use Save As instead of launching the system viewer. GST Excel has an explicit Save workbook action. Cancellation does not copy a destination file.

## GSTR2 purchase books

Reports → GSTR2 Purchase Report produces an Excel workbook based on the supplied Vyapar file's sections: `GSTR2 Report`, `b2b`, `b2bur`, `cdnr`, `cdnur`, `hsnsum`, `itemSummary`, plus review sheets for imports, advances, exempt classifications and reversals that ordinary bill records cannot establish.

This supports arbitrary book date ranges and shows supplier invoice references and separate tax heads. It is not an official GSTR-2B statement, a certified upload template or an automatic ITC entitlement decision. GST portal GSTR-2B is generated from supplier filings: [official FAQ](https://tutorial.gst.gov.in/userguide/returns/FAQ_gstr2b.htm).

## Bank reconciliation

Settings → Bank & Cash → Reconcile statement.

1. Choose a bank account and import a CSV or PDF.
2. CSV recognises Date/Transaction Date/Value Date, Description/Narration/Particulars, Debit/Withdrawal, Credit/Deposit and reference/UTR headings. Dates accept ISO, DD/MM/YYYY and DD-MMM-YYYY.
3. Text-based PDF extraction runs locally. Bank PDF layouts differ: the current preview exposes extracted text and requires the user to arrange/verify transaction CSV fields before matching. Image-only/scanned PDFs need OCR or a bank CSV export. Automatic bank-specific PDF column mapping remains unverified without a representative statement.
4. Suggestions use party names/fragments, invoice references, amount, date and user-confirmed aliases. Unique strong suggestions are selected in the preview; ambiguous or weak matches remain unselected. `Key` alone is insufficient; a confirmed alias can associate it with Keystone. Aliases are scoped to the business on this device.
5. Confirm the selected rows to create payments and update linked invoices/bills in one database transaction. Partial payments remain partial. Stale/overpaid selections fail and roll back. Repeat rows use stable account/transaction fingerprints and deterministic payment IDs; already-recorded matching payments require review rather than duplicate posting. Do not reconcile the same account simultaneously on disconnected devices.

The current workflow links each bank row to one invoice/bill. Split allocations across multiple documents, bank charges, transfers and on-account receipts need a separate allocation workflow; unmatched rows can be left unselected.

## WhatsApp sharing

On Windows, invoice/quotation Share opens a visible WhatsApp Web panel using WebView2. Scan the QR through WhatsApp Linked devices; open the customer chat, copy the PDF path, attach that file using WhatsApp's picker, and press Send yourself. The app does not automate sending or upload the WhatsApp session to the accounting server. The local browser profile persists on the Windows user account; log out inside WhatsApp on shared computers.

The maintained Windows WebView package builds successfully with this toolchain. Live WhatsApp QR linking and attachment behavior still require testing with the user's account. WhatsApp may change embedded-browser compatibility. Microsoft Edge WebView2 Runtime is required; a browser fallback is available. Mobile uses the system share sheet.

References: [WhatsApp linked devices](https://faq.whatsapp.com/378279804439436/), [WebView2 package requirements](https://pub.dev/packages/webview_flutter_windows).

## Auto-sync verification

Existing auto-sync debounces saves, polls every five seconds, listens for remote changes, resumes immediately after foregrounding and retains offline changes for retry. Regression coverage includes non-overlapping runs, fresh-device discovery, edit/delete round trips, linked payment settlement and derived bank balances. A live simultaneous mobile/desktop test against the deployed server has not been performed here; server version, credentials and connectivity still matter.

## Native PDF compatibility

`pdfrx_engine` 0.4.4 is vendored with two Dart 3.13 null-promotion assertions. Its MIT license and the patch explanation are preserved in `third_party/pdfrx_engine`. Newer releases require archive 4, while the Excel library currently requires archive 3. A native PDF extraction test uses the built Windows `pdfium.dll` and confirms text extraction.
