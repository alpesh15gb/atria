# Atria — Core Business Logic / Data Layer Audit

_Read-only audit, 2026-09-27. Baseline verified this session: `flutter analyze` → No issues found; `flutter test` → 87/87 passing (goldens excluded)._

_Findings marked **[verified]** were re-confirmed by direct file inspection in this session; the rest were produced by the deep-dive pass over `lib/core/**`._

---

## CRITICAL

### C1 — Backup export writes every column as `null`; restore either always fails or silently wipes the database **[verified]**
- `lib/core/database/repositories/settings_repository.dart:100-104` — `_rowToMap` keeps a value only `if (expr is Constant)`.
- Reality: generated `toColumns()` returns `Variable<T>` for every column (`lib/core/database/app_database.g.dart:1447` onward); `Constant` and `Variable` are unrelated classes in drift.
- `export()` (`:106-178`) emits rows whose every field is `null` while the UI shows "Backup created" (`lib/features/settings/backup_restore_screen.dart:78-80`).
- `_restore()` (`:222-247`) binds `null` to `id` → `NOT NULL constraint failed` → transaction rolls back → restoring your own backup can never succeed.
- Worse: `importFromJson()` (`:197-220`) calls `_clearAll()` (`:249-264`) **before** validating the payload, and the UI never checks `app`/`version` (`backup_restore_screen.dart:99-127`). A foreign/empty JSON object with no `firms` key clears every table, `_restore` returns `0` for non-lists, and the transaction **commits**.
- **Impact:** users believe they have backups; restoring an unrelated `.json` permanently destroys all firms, items, invoices and settings.
- **Verify:** Settings → Backup → export, inspect the JSON (all fields `null`); restore that file (fails); restore any other JSON object file (data gone, "Restored 0 records").

### C2 — Profit & Loss net profit double-counts sales and purchases **[verified]**
- `lib/core/database/repositories/report_repository.dart:452, 476-479` — `grossProfit = salesTaxable - purchaseTaxable`, `totalIncome = salesTaxable + otherIncome`, `totalExpenses = purchaseTaxable + otherExpenses`, then `netProfit = grossProfit + totalIncome - totalExpenses`.
- The algebra resolves to `2·sales − 2·purchases + income − expenses`. Rows at `:469/:473` are correct; only the `netProfit` line is wrong.
- **Impact:** P&L "Net Profit" is overstated by exactly the gross profit — wrong tax-season/investor numbers.
- **Verify:** one invoice ₹1000 taxable, one bill ₹600 taxable, no expenses → app shows Net Profit ₹800 instead of ₹400.

### C3 — Sales returns (credit notes) never move stock; purchase returns (debit notes) do **[verified]**
- `lib/features/sales/sale_editor_screen.dart:100-101` — `_affectsStockAndBalances` excludes `credit_note`, so `SalesRepository.save` is always called with `affectStock: false` (`:509`).
- `lib/core/database/repositories/sales_repository.dart:326-343` contains the `sign = credit_note ? +1 : −1` logic and `restore()` (`:594-610`) only re-posts for `docType == 'invoice'` — dead paths. The comment at `sale_editor_screen.dart:99` ("credit notes reverse an invoice on their own") has no implementation; there is no schema link from a credit note to an original invoice.
- Purchase side does the opposite: `lib/features/purchase/purchase_editor_screen.dart:365` always passes `affectStock: true`; `purchase_repository.dart:250-257` posts `−qty` for `debit_note`.
- **Impact:** goods physically returned by customers are never added back to stock; returns are invisible to the stock ledger and stock report while purchase returns do adjust stock — asymmetric inventory.
- **Verify:** sell 5 of a tracked item, issue a credit note for 5 → stock stays reduced; issue a debit note for 5 → stock moves.

### C4 — Deleting or restoring a payment never updates the invoice's paidAmount / balanceDue / paymentStatus **[verified]**
- `lib/core/database/repositories/payment_repository.dart:157-183` (`softDelete`) and `:186-210` (`restore`) only flip `isDeleted`; the doc comment at `:155-156` explicitly promises "the invoice's balance is recomputed on restore" but no such code exists. `delete()`/`deleteForever()` (`:146-153`, `:221-234`) don't either. The file contains no reference to `paidAmount`/`balanceDue` at all.
- Only writers of those columns: `SalesRepository.save` (`sales_repository.dart:263-281`), `SalesRepository.applyPayment` (`:675-700`), purchase equivalents (`purchase_repository.dart:206-208`, `:457-472`).
- **Impact:** delete a payment from the recycle bin → the invoice still shows **Paid**, `balanceDue = 0`; dashboard receivable, party outstanding and the party statement all disagree.
- **Verify:** record a full payment (invoice shows Paid), delete the payment in Settings → Recycle Bin → invoice still shows Paid / ₹0 due.

---

## HIGH

### H1 — Invoice number minting is racy, unenforced, gapped, and never resets per financial year
- `lib/core/database/repositories/firm_repository.dart:127-149` — non-transactional read-modify-write (`getById` → `+1` → whole-row `replace`) despite the comment at `:124-126`; concurrent callers can mint the same number; `replace` can clobber unrelated firm fields.
- No uniqueness anywhere: no table in `lib/core/database/tables/*.dart` declares `unique` or `@TableIndex` (only `primaryKey => {id}`).
- `lib/features/sales/sale_editor_screen.dart:448-450` mints the number **before** `sales.save` at `:509` → a failed save (e.g. period lock, `sales_repository.dart:249`) permanently burns a number.
- The sequence never resets per financial year although `DocumentNumbering.format` embeds the FY (`document_numbering.dart:65+`).
- **Impact:** duplicate or gapped invoice numbers on documents filed with the tax department.
- **Verify:** `SELECT number, COUNT(*) FROM sales_invoices GROUP BY number HAVING COUNT(*)>1;`; check numbering after a save that fails the period lock.

### H2 — Period lock is bypassed by restores, payment/expense creation, and status changes
- Missing `assertDateEditable`: `sales_repository.dart:583-623` (`restore`) vs `:558/:640` which do check; `purchase_repository.dart:315-355` (`restore`) vs `:290/:370`; `payment_repository.dart:16-67` (`create`), `:186-210` (`restore`), `:146-153` (`delete`), `:221-234` (`deleteForever`); `payment_repository.dart:246-286`/`369-391` (`ExpenseRepository.create/update/delete`); `sales_repository.dart:536-549` (`markCancelled`), `:659-672` (`markConverted`).
- **Impact:** after locking books through a date, users can add payments/expenses dated inside the locked period, restore documents into it, and cancel/convert — locked-period reports can still change.
- **Verify:** lock books through yesterday → create a payment dated last week (accepted), create an invoice dated last week (rejected).

### H3 — Party outstanding includes cancelled invoices
- `lib/core/database/repositories/party_repository.dart:228-247` sums `balanceDue` filtered only by `firmId`/`partyId`/`docType`/`isDeleted` — no `status != 'cancelled'`.
- Every other consumer filters cancelled (`report_repository.dart:238, 268, 289, 435, 440, 529, 533, 543, 617, 627`).
- **Impact:** parties screen receivable/payable disagrees with the statement and dashboard; `markCancelled` also leaves `paidAmount`/`balanceDue` populated (`sales_repository.dart:536-549`).

### H4 — Restoring a deleted debit note does not re-post its stock
- Save posts stock for `debit_note` (`purchase_repository.dart:250-257`), `softDelete` reverses it (`:286-294`), but `restore` only re-posts when `bill.docType == 'bill'` (`:326-342`).
- **Impact:** delete + restore a purchase return and stock stays permanently inflated by that quantity; the ledger shows an orphaned reversal.
- **Verify:** receipt of 10, debit note of 4, delete it (stock +4), restore it (stock stays +4 instead of −4).

### H5 — Stock posted for service/untracked items; can go negative; silent no-ops when the item row is missing
- No `stockType`/`isService` check in `sales_repository.dart:326-343`, `purchase_repository.dart:250-257`, `sales_repository.dart:740-769`, or `item_repository.dart:210-255`. No negative-stock guard anywhere.
- Silent skips: `sales_repository.dart:753` (`if (item == null) return`) and `:782` (`continue`) post/reverse nothing with no error or audit entry.
- The seeder demonstrates it: `demo_seeder.dart:218-219` creates `stockType: 'untracked', isService: true` items which are then sold → `currentStock` goes negative while `stockValue()` (`item_repository.dart:276-281`) skips them.
- **Impact:** service invoices write meaningless stock movements; negative stock goes unnoticed; a missing item silently corrupts the ledger.

### H6 — GSTR-1 / GSTR-3B contain structurally and numerically wrong filing data
- `lib/core/reports/gst_return_builder.dart:44` — B2CL uses `grandTotal >= 250000` (gross, incl. tax, `>=`); rule is taxable value **exceeding** ₹2.5 lakh.
- `:41-51` — `isExport` never consulted, so zero-rated/SEZ exports fall into B2CS/B2CL; GSTR-3B export row adds `grandTotal` not `taxableValue` (`:444`).
- `:133` — `cdnur.addAll(itms)` pushes raw line items as top-level CDNUR rows: no note number, date, value or note type → invalid Table 10.
- `:141-163` — HSN summary (Table 12) built from invoices only, credit notes excluded; `:181` doc-issue (Table 13) only `docType: 'invoice'`; `:245-253` counts cancelled in `total` with lexicographic `from`/`to`.
- GSTR-3B: credit notes excluded from outward (`:431-436`), `reverseChargeTax` hardcoded `0` (`:488`) despite the stored `reverseCharge` column, unregistered-supplier purchases routed to `inwardNil` (`:471-474`), `inwardNonGst` declared (`:469`) never accumulated, `nilRated` hardcoded `0` (`:487`).
- **Impact:** returns prepared from the app will be rejected by the offline utility or filed with wrong tax.

### H7 — GSTR-2A reconciliation matches on invoice number only; totals don't match rows
- `gst_return_builder.dart:626-646` keys both sides by `_normalize(number)` alone — supplier GSTIN ignored, so two suppliers with the same invoice number cross-match.
- Duplicate keys overwrite the map entry while `portalTax`/`booksTax` keep accumulating → header totals can exceed the sum of displayed rows (`:687-688`).

### H8 — PDF decides IGST vs CGST/SGST differently from the engine
- `lib/core/services/invoice_pdf.dart:300-301` — `interState = invoice.isInterState && hasGstin`, whereas engine/repo derive the split purely from `isInterState` (`sales_repository.dart:225`, `gst_engine.dart:28`).
- **Impact:** inter-state sale to an unregistered buyer prints `-` in CGST/SGST columns and omits IGST, while totals include IGST — a document that doesn't add up, printed and shared with the customer.

### H9 — Inclusive-priced invoices print a phantom "Discount" row equal to the tax
- `gst_engine.dart:269-277` — `resolvedInvoiceDiscount = subTotal − itemDiscount − taxableValue`; for inclusive lines `subTotal` is tax-inclusive while `taxableValue` is exclusive → the difference is the tax itself even with no discount.
- Consumed at `invoice_pdf.dart:437-446` and `lib/features/sales/sale_detail_screen.dart:711-728`.
- **Verify:** one line, rate ₹100 inclusive, 18% GST, no discounts → PDF shows "Discount - ₹15.25".

### H10 — Sync outbox collapses insert/update/delete into one row and carries no payload
- `lib/core/database/repositories/sync_mixin.dart:19` — id is `'${entity}_${entityId}_$operation'`, written with `InsertMode.insertOrReplace` at `:26`; an insert followed by an update replaces the `insert` row. `payload` is never set by any caller.
- **Impact:** when sync is enabled it would send `update`/`delete` for records the server never received, with no data.

---

## MEDIUM

| # | Finding | Location |
|---|---|---|
| M1 | Silent row caps: `list` default 500, `watchList` default 100, sales list passes `limit: 200` — no "showing X of Y" | `sales_repository.dart:434,488`; `sales_list_screen.dart:156` |
| M2 | Stock value/summary truncate at 1000 items; `lowStock()` has no `isDeleted` filter → recycle-binned items counted on dashboard | `item_repository.dart:97-120,286-292`; `report_repository.dart:231-232,307,669` |
| M3 | Report queries are N+1 and load up to 1,000,000 rows into Dart to sum; sums in `double` | `report_repository.dart:360,213-231,313-335` |
| M5 | Shipping added after round-off; round-off inferred back from stored value (`applyRoundOff` flipped off if exactly 0) | `sales_repository.dart:233,419` |
| M6 | `applyPayment` has no lock, no cancelled/deleted guard, permits overpayment (guard exists only in UI) | `sales_repository.dart:675-700`; `purchase_repository.dart:457-472` |
| M7 | Edit branch can produce negative balance; `getById` doesn't filter `isDeleted` → re-saving a binned doc rewrites lines and re-posts stock | `sales_repository.dart:263-281,361-365` |
| M8 | `purge` never verifies soft-delete and never calls `reverseStockForSource` → purging a live doc leaves its stock deduction | `sales_repository.dart:636-655`; `purchase_repository.dart:366-385` |
| M9 | CSV exports inconsistent on soft-deleted rows: sales/purchases filter, parties/items/expenses don't | `csv_export.dart:49,68,92,115,135` |
| M10 | GSTR-1 CSV writes only b2b/b2cs/hsn (b2cl/cdnr/cdnur missing); export folder keyed by `fp` alone → two firms overwrite each other | `gst_export_service.dart:29-31,125-127` |
| M11 | GSTR-1 JSON lacks `version`/`hash`/`gtin` → not accepted by the GST offline utility despite "upload-ready" claim | `gstr1_report.dart:30-56` |
| M12 | `booksLockedUpto` uses `getSingleOrNull()` on a key that can match both a global and a firm row → StateError aborts every save | `repository_extensions.dart:51-56` |
| M13 | `PaymentRepository.delete` / `ExpenseRepository.delete` skip lock, recycle bin and audit (currently uncalled) | `payment_repository.dart:146-153,384-391` |
| M14 | Audit coverage contradicts its own contract: no audit on sales/purchase/item save, item restore, party deleteForever, payment/expense create, firms/settings | `tables/settings.dart:36-40` vs repos |
| M15 | Party hard-delete only checks sales references — purchase/payment/expense references allow purge → dangling `partyId` | `party_repository.dart:209-218` |
| M16 | Barcode fallback is the first 12 chars of a UUIDv7 = millisecond timestamp; no uniqueness on `items.barcode` | `barcode_labels.dart:95-99`; `tables/items.dart:31` |
| M17 | Demo seeder: duplicate document numbers, repeated payment sequences, seeded invoice numbers never advance `firm.invoiceSequence` | `demo_seeder.dart:496-512,339-365,284-292` |
| M18 | `Money.parse` silently converts malformed input to 0 → a typo becomes a ₹0 record (item prices, expense amounts) | `money.dart:35-36` |
| M19 | **No indexes at all** — every list filters on `firmId`/`date`/`number`/`partyId` and sorts by date → full scans | all table files |
| M20 | FKs only on `firmId` and parent/child doc rows; `partyId`, `itemId`, `payments.linkedInvoiceId` unconstrained despite `PRAGMA foreign_keys=ON` | `app_database.dart:89` + tables |

---

## LOW

- **L1** Amount-in-words drops paise, uses `double` (`number_words.dart:43-62`) — ₹1,234.56 prints "…Thirty Four only".
- **L2** Dead "State:" block in PDF — always called with `null` (`invoice_pdf.dart:242-296,224,234`); `_stateName` unreferenced.
- **L3** PDF items table width map off by one: 9 cells vs 6+1 widths (`invoice_pdf.dart:305-313`).
- **L4** Half-rate label rounds odd rates: 0.25% goods prints `0.13%` (`invoice_pdf.dart:353,357,396-400`).
- **L5** Stock reversal dated `now`, not the document date (`sales_repository.dart:796`).
- **L6** Overdue reminders only consider `status == 'confirmed'` (`sales_repository.dart:468-480`).
- **L7** Day-book/dashboard windows use `23:59:59` + `DateTime.now()` (`report_repository.dart:602,210`).
- **L8** Party statement opening row dated `DateTime(2000)`; falls back to `0.0` for orphan partyId (`report_repository.dart:565-574,509`).
- **L9** Duplicate helpers with divergent behaviour: `repository_extensions.dart:63-73` vs `PeriodLock.assertDateEditable` (`audit_repository.dart:107-135` — never called); `all(lowStockOnly:)` vs `lowStock()`.
- **L10** `FirmRepository.delete` cascades the whole firm — no recycle bin, no confirm, no audit (uncalled) (`firm_repository.dart:117-122`).
- **L11** GST rate lookup uses `double ==` (`gst.dart:27-31`) → float noise returns null.

---

## Correct but fragile (works today, easy to break)

- drift `where()` is AND-accumulating — every repo builds sequential `query.where(...)`; correct under drift, would silently drop `firmId` under any other query builder.
- `app_settings` duplicate-row defence (delete-before-insert + `updatedAt` ordering) exists because the composite PK contains a nullable column.
- `Money.div` / `Decimal.round` verified correct (HALF_UP; `toBigInt: (v) => v.round()`). `_splitTax` rounds one half and gives the remainder to the other so CGST+SGST always sums exactly — but the printed halves can differ by a paisa.
- Inclusive mode + cess computes cess on the exclusive base and adds it on top of an "inclusive" price → customer pays more than the entered rate (field comment says intentional; worth confirming with the business).
- Inclusive divisor built from `double` (`gst_engine.dart:294`) — safe for the fixed rate set only.
- Invoice discount ratio applied uniformly charges correctly, but the *reported* `invoiceDiscount` is on a mixed basis (feeds H9).
- `Money.over100` deliberately unrounded → line discounts can carry >2 dp; residue lands in `resolvedInvoiceDiscount`.

---

## Dead / duplicate code

| # | Item |
|---|---|
| D1 | `PaymentRepository.delete` — no callers; hard delete, no lock/audit/balance recompute |
| D2 | `ExpenseRepository.delete` — no callers, same hazards |
| D3 | `FirmRepository.delete` — no callers; cascades entire firm |
| D4 | `DocumentNumbering.nextSequence` / `parseSequence` — no callers |
| D5 | `ItemRepository.all(lowStockOnly:)` — no callers, wrong semantics |
| D6 | `PeriodLock.assertDateEditable` + `PeriodLockedException` — never called; repos use the duplicate in `repository_extensions.dart` |
| D7 | `markConverted`/`markCancelled` skip audit+lock while siblings enforce both |
| D8 | `Gstr3bReport.inwardNonGst` never accumulated; `nilRated`/`reverseChargeTax` always zero |
| D9 | Duplicate movement-id generators (`sales_repository.dart:729-736` ≡ `item_repository.dart:351-357`) with independent counters → same id in the same ms → PK collision rollback |
| D10 | Duplicate numbering/lock message strings |

## Swallowed errors

- `money.dart:29` — `catch (_) → null` in `Money.tryParse` (feeds M18).
- `sale_detail_screen.dart:205-209` — `catch (_)` around `launchUrl` (WhatsApp failures invisible).
- All other `catch` sites surface via SnackBar or re-complete init; no empty catch blocks.
- More dangerous than catches: **silent no-returns** — `sales_repository.dart:753,782,557,586`, `item_repository.dart:212` bail without logging when a row is missing.
- Stale artefacts, not defects: `analyze.txt`, `analyze_out.txt`, `current_analyze.txt` at repo root are historical dumps for code that no longer exists.

---

## Suggested fix order
1. C1 (data loss) → C2 (money) → C4 (money) → C3/H4 (inventory).
2. H1/H2 (documents filed with the tax authority + lock integrity) → H6/H7/H8/H9 (filing & printed documents).
3. H3/H5/H10, then the M cluster (silent caps and truncation are the most user-visible).
