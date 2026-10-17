# Vyapar import parity audit ? 10 October 2026

**Initial audit: FAIL. See the post-fix reconciliation below for current importer results.**

Compared the open Vyapar and Apex Books windows through the computer-use skill. Both selected Apex Integrations. Supplemented visual checks with a fresh import of the latest local backup into an isolated in-memory database, using the current importer and report sources. Neither app?s business records were edited during this audit.

## Source and reproducibility

Backup: `10-10-2026_03.39.15_Apex_Integrations_VypBackup.vyb` on the desktop. Source dates: 27 March?9 October 2026.

SHA-256: `a9d202072eae699323f6a1cc2afde96e848bc2ec3767a4625d3067a362f73aac`.

The open Apex Books window is **UI AUDIT ? Disposable sample books**, backed by `NativeDatabase.memory()` in `tool/ui_audit_app.dart`. Its imported session is not durable storage: closing/restarting that process discards those books. A normal application/database must be used for a persistent import.

`tool/import_reconciliation_test.dart` reads the path in `VYAPAR_AUDIT_BACKUP`, imports into memory, and writes all imported tables, party statement balances, and 46 report results for All Time and 1?10 October. Run with `flutter test tool/import_reconciliation_test.dart --no-pub`. A successful extraction run is **not** a parity pass; the discrepancies below remain.

Artifacts under `build/import-audit/`: `documents.csv` (all 58 document comparisons), `differences.json`, `imported.json`, `reconciliation.log`, `analysis.log`. The exported JSON contains local business data and is not intended for publication.

## What matches

| Check | Result |
|---|---|
| Document presence | 29 sales invoices, 25 quotations, 1 purchase bill, 3 purchase orders imported |
| Document dates | 58/58 match |
| Line presence and item name/quantity/rate | 113/113 match; does not imply each tax/discount/metadata field matches |
| Item quantities | All 76 source item quantities match imported current stock |
| Party master names | 18 business parties imported; 5 other source names are expense heads |
| Invoice-list outstanding | ?2,18,868 in both apps |
| October invoice | ?27,977 in both apps |
| Purchase bill | MC2025-26/7164, 27 March 2026, ?12,800, paid; matches |
| October GSTR-1 | Taxable ?23,709; CGST ?2,133.81; SGST ?2,133.81; IGST zero; invoice value ?27,977; matches |

## Blocking differences

| Priority | Area | Vyapar | Apex Books | Evidence / cause |
|---|---|---|---|---|
| P0 | Purchase-order advances | ?1,43,475.33 paid: bank ?1,35,947.83 + cash ?7,527.50 | Omitted | Four positive `txn_payment_mapping` entries on three orders are filtered out because orders are not ledger documents. Advances still move real money. |
| P0 | Bank account | DCB BANK, balance ?7,63,805.26 | No accounts yet; Bank Statement empty | Verified both account screens. Importer never creates bank-account rows or assigns payment account IDs. |
| P0 | Receipt modes | Three standalone receipts, ?74,251, DCB BANK | Cash | Standalone receipt path reads null transaction payment type instead of its BANK payment mapping. |
| P0 | Cash | Source cash account is ?20,327.50 credit/outflow | Trial balance ?61,451 debit; dashboard ?8.87 lakh ?Cash in hand? | Missing cash advance and misclassified bank receipts; dashboard also adds all payment modes together. |
| P1 | Quote 15 | ?1,26,861; UI status Deleted | ?1,13,361; confirmed/Expired | ?13,500 additional charge omitted; source closed/deleted state is not preserved. |
| P1 | Quote 16 | ?53,367.50 | ?46,168 | ?7,200 additional charge omitted, then whole-rupee rounding adds ?0.50. |
| P1 | Quotation aggregate | ?17,09,309.50 | ?16,88,610 | Net shortfall ?20,699.50. Source total includes its closed/deleted quotation rows, so both populations were compared. |
| P1 | Conversion history | Seven source conversion links; eight closed quote states including quote 15 | Zero converted-to-invoice links | Confirmed source UI shows converted invoice numbers; imported quotes show Expired. Do not treat all eight closed states as conversions. |
| P1 | Invoice totals | ?11,18,621.09 | ?11,18,621.00 | Invoice 11: ?2,666.80 ? ?2,667; invoice 20: raw ?17,796.288 (UI ?17,796.29) ? ?17,796. Whole-rupee recalculation changes source amounts. |
| P1 | Received total | ?8,99,753.09 | Invoice list ?8,99,753.00 | Payment records total ?8,99,753.09 but invoice headers use reconciled rounded paid amounts. |
| P1 | Party statements | Keystone ?2,18,868; Panjwani Food Products zero | Keystone ?2,18,868.20; Panjwani ??0.29 | All 18 statements were computed; these two differ. Combined debt ?2,18,867.91 also appears in trial balance, versus invoice-list ?2,18,868. |
| P1 | Purchase-order totals | Order 1 ?28,165.83; order 2 ?1,07,527.50 | ?28,166; ?1,07,528 | Recomputed whole-rupee totals. Order 3 ?7,782 matches. |
| P1 | Number presentation | Invoice 2026-27/29 in source list/GSTR-1 | 29 | Numeric reference imported without reproducing the source display prefix; inspect numbering settings before reuse. |
| P2 | October P&L | Net ?23,709.38 | Net ?23,709 | Vyapar includes invoice round-off in the result; Atria document P&L excludes it. This is a report-definition difference as well as a parity failure. |
| P2 | Stock valuation | ?10,847.46 in source P&L/stock value | Catalogue cost report ?5,047.46; dashboard/list use sale-value valuation around ??10.13 lakh | Quantities match. Canon NPG90 is negative one; source book value is zero, Atria cost report values it at ??5,800. Different valuation policies and dashboard sale-price valuation prevent equivalence. |
| P2 | All parties report | Actual debt ?2,18,868 | Catalogue ?Outstanding? aggregate ?9,37,136.27 | The source implementation intentionally computes taxable sales minus purchases without payments/history. Its footnote explains this, but it is not a receivables report or equivalent party-balance report. |
| P2 | Party groups | One group | Not imported | Explicit warning; group reports cannot preserve source grouping. |

The source bank balance reconciles exactly: **?8,99,753.09 receipts ? ?1,35,947.83 bank advances = ?7,63,805.26**. Source cash outflow reconciles as **?12,800 purchase + ?7,527.50 cash advance = ?20,327.50**.

The Atria trial balance displays ?Debits equal credits?, but that proves only internal double-entry balance. It does not prove parity: bank, cash, debtor and advance balances above still differ. Balance Sheet, Cash Flow, Day Book and All Transactions inherit these missing/misclassified payments and cannot receive a parity pass.

## Report coverage

Visual comparisons exercised sales, purchase, quotations, bank accounts, cash account, trial balance, October P&L, stock displays and October GSTR-1. Current-code report sources were executed for all 46 catalogue entries at All Time and October; all returned without throwing. This is **not** a claim that every report was visually compared row by row in both applications.

Eight catalogue reports are placeholders, so their empty results cannot count as matches: Expense, Expense Category, Expense Item, GST Report, Loan Statement, Sale/Purchase Orders, Sale/Purchase Order Item, TDS Receivable. Order reports are particularly material because this backup contains purchase orders and real advances.

Reports requiring a selected party/account or portal data cannot be certified from an unfiltered empty result. Party statements were additionally generated separately for every imported party. Annual GST, all HSN/rate breakdowns, item margins, groups, exports and printed/PDF output remain **not independently visually certified**. Recomputed taxes differ by small rounding amounts across full-history report paths; October?s matching GSTR-1 does not certify other periods.

## Correction order

1. Preserve account masters, every money movement (including order advances), account assignment and source payment modes.
2. Preserve source document charges, exact monetary totals/round-off, conversion links and closed/deleted meaning.
3. Reconcile invoice balances, party statements and accounting ledgers to the same settlement figures.
4. Agree stock and P&L policies; label sale-value stock separately from book/cost value; complete missing reports.
5. Repeat this comparison in a persistent normal build after correction, including all report periods and exports.

No importer or accounting fixes were applied in this verification pass. The added tool is an audit extractor. Source backup and live imported session were left intact.


## Post-fix reconciliation ? latest 10 October backup

The importer was corrected and rechecked using the exact backup SHA-256 above. This is a fresh isolated import; an already-imported firm is not retroactively repaired.

- All 58 supported documents preserve source totals to currency precision: 29 invoices, 25 quotations, one bill, three purchase orders. Invoice total: INR 1,118,621.09; received: INR 899,753.09; outstanding: INR 218,868.
- Additional quotation charges are included. Quotation totals: INR 1,709,309.50. Saved source rounding is retained rather than applying a new whole-rupee rounding rule.
- All 23 payments are present, including four purchase-order advance payment legs. Every leg is retained, even when an earlier leg is larger than a later one.
- Cash and bank accounts are imported and payments are linked to them. DCB: INR 763,805.26; Cash: INR -20,327.50; unused Razorpay account: zero.
- Advances post to separate advance accounts and do not settle trade bills/invoices. All 18 party statements reconcile; only Keystone has a closing debit balance, INR 218,868.
- Seven quotation conversion links and their dates are preserved. A closed quotation with no conversion is kept cancelled, preventing a new conversion of a source-deleted quotation.
- Explicit financial-year prefixes are retained and number counters advance from their numeric suffix.
- Trial balance: debit = credit = INR 2,187,450.62; closing difference zero. October P&L sales net of tax include source rounding, INR 23,709.38.
- Sync receives final reconciled document and line values after the repository draft inserts.

Regression coverage is in `test/vyapar_import_parity_test.dart`. The opt-in `tool/import_reconciliation_test.dart` now asserts source document totals, account balances, conversion count, payment count and party statements, as well as exporting report evidence. Business backup data remains local and is not added as a test fixture.

Remaining report gaps from the initial audit still apply: placeholder reports, party groups, differing stock valuation policies and the All Parties catalogue report's sales-minus-purchases definition. Nonzero bank opening balances are retained and flagged for opening ledger review; this exact backup has zero account openings. These are not evidence that every report is equivalent.


Native post-fix verification: launched `tool/vyapar_audit_app.dart` with this backup in an isolated in-memory Windows app. Visually verified the October dashboard invoice INR 27,977 and Bank & Cash rows (Cash -20,327.50; DCB 763,805.26; Razorpay 0). No writes were made to the user's open Vyapar or original Apex Books window. This check also exposed quotation expiry derived from Vyapar's generic due date; quotations now leave that field unset because the backup does not provide an explicit validity deadline. A regression assertion covers that mapping.


Validation at completion: 54 focused tests passed (`verified-import-tests.log`), including real-backup reconciliation, import regressions, ledger and sync roundtrip checks. Static analysis of the changed import/verification/header files found no issues (`verified-analysis.log`). The broader suite initially passed 1,144 tests and exposed one header-alignment failure; that failure was fixed and its targeted regression passed. A later broad rerun was stopped while another test process was running against the same workspace; no claim of a final complete suite pass is made.

## Review repairs and fresh builds — 10 October 2026

Fixed weighted-average stock valuation (including dashboard), negative-stock asset valuation, bank account reassignment, pending/bounced cheque balances, historical bank balances, idempotent payment delete/restore, and bank master sync. Schema 13 stores opening bank balances separately; existing v12 balances are migrated and derived balances are rebuilt from eligible payments after local writes and sync. Bank master edits preserve opening balances rather than overwriting receipts received while a dialog is open.

Native inspection of the disposable imported Windows books verified all 23 payments, Cash -20,327.50 and DCB 763,805.26. The imported payment editor correctly selected DCB but exposed an unsupported bank_transfer mode; the editor now includes that canonical mode and Other. No financial edits were saved during this inspection. Stock summary and category exports reconcile to book stock value 10,847.46; dashboard uses the same costing policy.

Verification: final full suite passed 1,151 tests; focused reconciliation/repair tests passed; final lib/test analysis reported no issues. The last payment-mode dropdown correction was included in fresh analysis and builds. Native checks used a disposable in-memory desktop harness, not an Android hardware device.

Eight report modules remain unimplemented and now explicitly show unavailable without exporting misleading empty reports. Earlier catalogue/report semantic gaps and nonzero opening ledger review limitations still apply. Android output is debug signed because no release signing configuration is present; current builds retain upstream Kotlin/Java warnings. These builds are not a claim that every unfinished module is production-ready.

Scale follow-up: the app root had stopped mounting InterfaceScale even though Settings still persisted the preference. Restored reactive scaling around the router and PIN gate. Added an actual AtriaApp regression changing 100% -> 130% -> 85% -> 100% and verifying the routed screen viewport changes immediately. All 16 scale/mobile tests passed; lib/test analysis clean. Windows release and Android debug packages rebuilt with the fix.
