# Atria — Gap Analysis: what we're missing

_Read-only audit, 2026-09-27. Benchmark = Vyapar / Indian SMB GST apps._

---

## 1. Already known (from `.claude/STATE.md`, `.claude/TODO.md`, `.claude/memory/bugs.md`)

```
KNOWN-DEFERRED: godown/warehouse mgmt; Tally/Vyapar import; GSTR-2A live portal sync (GST API/OAuth);
                GSTR-9/9C; bank feeds/reconciliation.
KNOWN-PARTIAL : cloud sync = scaffolding only — sync_queue enqueued, never drained; Settings copy
                relabelled "EXPERIMENTAL / Coming soon — nothing leaves this device yet".
BUGS          : bugs.md — all previously logged CRITICAL/HIGH items closed (money formatting,
                double-counted discounts, lost per-line tax, double stock deduction, purchase edit
                UNIQUE, party statement date range).
OPEN TODO     : release builds (--release not done; APK signs with debug keys); `git init`;
                golden teardown hang for dashboard/settings; Kotlin-Gradle-plugin `*_plus` debt.
CURRENT       : 87/87 tests pass (goldens excluded), `flutter analyze` clean, debug artifacts only.
```

---

## 2. Actual feature surface

### 2.1 Routes — `lib/core/router/app_router.dart`
| Path | Screen |
|---|---|
| `/boot` | BootRoute (splash / `_BootFailure` recovery) |
| `/onboarding`, `/onboarding/firm-setup` | OnboardingScreen, FirmSetupScreen |
| `/payment-reminders` | PaymentRemindersScreen |
| **Shell 1** `/dashboard` | DashboardScreen |
| **2** `/sales` + `/new ?type=&from=&party=`, `/edit/:id`, `/detail/:id` | SalesList / SaleEditor / SaleDetail |
| **3** `/items` + `/new ?from=`, `/edit/:id` | Items / ItemEditor |
| **4** `/parties` + `/new ?type=`, `/edit/:id`, `/statement/:id` | Parties / PartyEditor / PartyStatement |
| **5** `/reports` | ReportsScreen |
| **6** `/purchase` + `/new ?type=`, `/edit/:id` | PurchaseList / PurchaseEditor |
| **7** `/payments` | PaymentsScreen |
| **8** `/expenses` + `/new ?type=`, `/edit/:id?type=` | Expenses / ExpenseEditor |
| **9** `/stock` | StockScreen |
| **10** `/gst-reports` | GstReportsScreen |
| **11** `/settings` + `/firm`, `/backup`, `/recycle-bin`, `/period-lock`, `/audit-log` | Settings family |
| `errorBuilder` | branded 404 |

### 2.2 Nav — `lib/core/navigation/nav_destinations.dart`
Primary (bottom bar 5): Dashboard, Sale, Items, Parties, Reports.
Secondary (rail + mobile "More" sheet 6): Purchase, Payments, Expenses, Stock, GST Returns, Settings.
11 branches total. `moreRoutePath = '/more'` (line 102) is declared but **no `/more` route exists** — dead constant.

### 2.3 Per-feature status
- **Dashboard:** firm switcher, cash/bank/paid-this-month KPIs, 6-month Sales vs Purchases chart, quick actions, recent invoices, Low stock + Overdue "Needs attention".
- **Sales:** 5 tabs — Invoices / Quotations / Sales Orders / Delivery Notes / Credit Notes; Vyapar-style table + TotalsCard; detail screen has Edit, Convert-to-invoice, Open PDF, Print (`Printing.layoutPdf`), Cancel, Delete, WhatsApp + share sheet.
- **Purchase:** 2 tabs — Bills / Debit Notes (no Purchase Orders).
- **Items:** grid, category + unit dropdowns (23 units + custom), barcode field, "Print barcode labels" (Code128 PDF), duplicate, danger-zone delete, stock adjust. **No images, no batch/expiry.**
- **Parties:** master-detail ≥840px, statement, call, WhatsApp; credit limit/days **captured** in the editor.
- **Payments:** in/out, cash/bank/cheque summary, UPI/NEFT/cheque modes, soft delete.
- **Expenses:** Expenses / Other Income tabs, edit + delete, Net P&L card.
- **Stock:** summary table, low-stock filter, movement log, adjustment dialog. No godown dimension.
- **Reports (60KB):** Sales vs Purchases, GST Summary, P&L, Receivables & Payables, Day Book, Stock Summary; period pills incl. FY.
- **GST Returns:** GSTR-1 JSON/CSV per table, GSTR-3B tables 3.1/3.2/4/5, GSTR-2A JSON import → matched / books-only / portal-only / value-mismatch.
- **Settings:** firm profile, numbering/prefixes (11 series), terms/notes, bank+UPI, recycle bin, period lock, audit log, local JSON backup/restore, CSV export, theme (system/light/dark), cloud-sync toggle (inert).

**Builds:** `android` + `windows` only. **No `.git`. No CI config of any kind.**

---

## 3a. Features present but incomplete / one-shot

_No `TODO`/`FIXME`/`UnsupportedError`/`unimplemented` in `lib/` at all — these stubs are **silent**, which is worse._

| # | Gap | Evidence |
|---|---|---|
| A1 | **"Show UPI QR code" toggle is inert** — nothing renders a QR anywhere (no qr package in `pubspec.yaml`; PDF only prints the UPI id as text, `invoice_pdf.dart:559`) | written `firm_settings_screen.dart:172,219,649-650`; read by no one outside generated code |
| A2 | **Firm logo upload doesn't exist** — `logoPath` column has zero writers/readers | `tables/firms.dart:20` |
| A3 | **TCS is dead schema** — column never computed by `GstEngine`, never set in UI, never printed; `firms.invoiceTcsRate` unread | `tables/sales_invoices.dart:47`; `tables/firms.dart:56` |
| A4 | **Credit limit / credit days are write-only** — captured in the party editor, never enforced/warned at billing, never shown in receivables | `tables/parties.dart:27-28` ↔ `party_editor_screen.dart:175-176,226-228` |
| A5 | **Wholesale price / MRP / weightPerUnit stored but never applied** — no price-level choice in the sale editor | `tables/items.dart:19-20,33`; readers only `barcode_labels.dart:78`, `csv_export.dart:82` |
| A6 | **CSV export has no import** — one-way; only importers are backup JSON and GSTR-2A JSON | `csv_export.dart`; `backup_restore_screen.dart:91`; `gst_reports_screen.dart:357` |
| A7 | **Cloud sync is enqueue-only** — 32 `enqueue(...)` call sites, **none passes `payload`** (no snapshot), nothing drains or prunes → unbounded growth | `sync_mixin.dart:11-27`; `sales_repository.dart:350,542,567,611,665,693` etc. |
| A8 | **Sync toggle persists a flag nothing reads** | `settings_screen.dart:164` → `SettingsRepository.kSyncEnabled` |
| A9 | **Delivery challan ≠ delivery note workflow** — delivery notes are stock-neutral and can't be converted to an invoice (only quote/order convert) | `sale_editor_screen.dart:111,441-445`; `sale_detail_screen.dart:133-138` |
| A10 | **WhatsApp is real, e-mail/SMS are not** — party `email` stored but never used to send | `sale_detail_screen.dart:178-221`; `payment_reminders_screen.dart:139` |
| A11 | **No PO → bill** — purchase side has only Bills + Debit Notes | `purchase_list_screen.dart:81-82` |
| A12 | `nav_destinations.dart:102 moreRoutePath` — declared, unused | single grep match |

---

## 3b. Missing entirely vs Vyapar / Books / GST apps

- **Invoice branding:** template choice, logo upload, per-doc colour themes, footer terms gallery, invoice QR (UPI/GSTIN), e-invoice QR — absent.
- **Compliance:** e-invoice / IRN / ACK-NO, e-way bill, TDS, TCS computation, GSTR-9/9C, live 2A sync — absent (2A = file import only; 9 = known-deferred).
- **Sending:** e-mail send, SMS, scheduled WhatsApp reminders (current reminders are manual one-tap) — absent.
- **Automation:** recurring invoices, auto payment reminders / dunning schedule, interest on overdue (the "Interest @18% p.a." string is **hard-coded PDF text** at `invoice_pdf.dart:606`, never computed) — absent.
- **Sales ops:** POS / quick-bill mode ✅ and thermal *label* printing (TSPL for TSC, ZPL for Zebra) ✅ — both shipped in §17. **Still absent:** ESC/POS *receipt* printing (a counter sale prints stickers, not a customer bill), barcode *scanning* (no camera package; the search box accepts a wedge scanner because it types into the focused field), price lists/price levels at billing. (Estimates/quotations **are** numbered — `quotationPrefix/quotationSequence` — ✅.)
- **Inventory:** multi-godown, batch/expiry, item images, unit conversion (kg↔g — `units.dart` has no conversion factor), stock valuation method (FIFO/weighted avg) — absent.
- **Purchases:** purchase orders, PO→bill, 2A auto-match → bill, purchase attachments — absent.
- **Parties/finance:** credit-limit enforcement, debit/credit ageing buckets, bank reconciliation (known-deferred), TDS party ledgers, payroll — absent.
- **Voucher extras:** attachments/photos on any voucher (no attachments table) — absent.
- **Data:** cloud/Google Drive backup, auto-backup schedule, import from Excel/Tally/Vyapar — absent (local JSON + CSV export only).
- **Reporting:** HSN-wise summary, item-wise sales report, cash/bank book, trial balance / balance sheet, voucher-wise GST reconciliation — absent (Reports = 6 cards; GST = 1/3B/2A).
- **UX:** Hindi/regional i18n (no `.arb`, no `l10n.yaml`, no `flutter_localizations`; `app.dart:21-25` pins `en_IN`), app lock / biometric (no `local_auth`), tablet-first layout.

---

## 3c. Engineering / production gaps

### Tests — 20 files in `test/` (117 `test(` + 7 golden; 87 pass excluding goldens)

Covered: gst_engine, document_numbering, validators, formatters/money/number_words, party/item/sale/purchase/expense repos (round-trip), sales+purchase edit path, payment repo + payments screen, gst_return_builder/gstr1_report/gst_export_service, soft delete/restore, CN/DN, csv_export, expense update, markConverted, stock adjustment, PeriodLock/AuditRepository, onboarding redirect, router boot, boot failure, nav shell, editor shell, item type-ahead, items/stock/parties screen regressions. Goldens: 6 light-mode, tagged `golden` (excluded by default), 800×600 only.

**Zero tests on the money-critical surfaces:**
- `lib/core/services/invoice_pdf.dart` (23KB — the artifact customers see)
- `lib/core/database/repositories/report_repository.dart` (22KB — P&L, day book, ageing) ← why the P&L double-count survived
- `barcode_labels.dart`, `demo_seeder.dart`, `settings_repository.dart` restore path (partial)
- **every editor's save-totals path** except shell/type-ahead: sale, purchase, item, party
- `gst_reports_screen`, `recycle_bin_screen`, `backup_restore_screen`, `firm_settings_screen`, `party_statement_screen`, `sale_detail_screen`, `transaction_list.dart`
- no `integration_test/` at all

### Other engineering gaps
1. **Not a git repo** — ~40 sessions of work unversioned. Root litter: `analyze*.txt` (4 files), `test_out*.txt`, `status.md`, `HANDOFF.MD`, `LEFTOFF.MD`, `build_out.txt`.
2. **No CI** — nothing runs `flutter analyze` / `flutter test` automatically.
3. **Debug-only Android signing** — `android/app/build.gradle.kts:36-39` uses the debug config + a TODO. Only debug APK (202MB) and debug Windows exe exist.
4. **No crash reporting / analytics.**
5. **No localization** — `supportedLocales` = `en_IN`/`en`, no `flutter_localizations`.
6. **No versioning/update channel** — `version: 1.0.0+1`, package_info only for the About label; Windows `Runner.rc` uses template placeholders.
7. **Assets thin:** `assets/images/` is **empty** yet declared in `pubspec.yaml:79`; only `assets/logo/atria_logo.svg` + Inter fonts. Stock launcher icons (0.4–1.4KB), template Windows icon → **unbranded app icon**.
8. **Platforms:** android + windows only. No deep-link/intent filters, no declared permissions, no `allowBackup`/data-extraction rules.
9. **Accessibility:** **zero** `Semantics` / `semanticLabel` / `Tooltip(` matches in `lib/`. Text scaling hard-clamped to 1.15 (`app.dart:38`).
10. **Theming:** dark theme genuinely implemented but **no dark-mode goldens**; no 360dp phone or 1600px desktop golden; 12 stale diff PNGs (~1.9MB) in `test/failures/`.
11. **Migrations:** `schemaVersion 3`, additive-only `onUpgrade` (`app_database.dart:50-77`). No `beforeOpen` integrity check, no pre-migration backup, no downgrade guard.
12. **Performance:** `ItemRepository.watchAll()` has **no limit** and is subscribed by both editors and the items screen → whole catalogue loaded + client-side filtering; parties `watchAll` likewise unlimited; `sync_queue` never drained; reports/aggregation run on the UI thread (no `compute`/isolate anywhere).
13. **Lint set is bare** `flutter_lints` defaults; `analysis_options.yaml` excludes `android/` + `windows/`.

---

## 3d. Top 15 gaps by user impact (Indian SMB)

| # | Gap | Status | Why it matters |
|---|---|---|---|
| 1 | **Shippable release: signed APK + release Windows build + `git init` + CI** | [missing] | Nothing distributable today; no version control, no gate |
| 2 | **E-invoice (IRN/QR) + e-way bill** | [missing] | Mandatory above ₹5cr turnover / ₹50k consignments — a wholesale trader can't comply |
| 3 | **Invoice branding: logo + QR + template choice** | [partial] | The "Show UPI QR code" toggle *looks* shipped but renders nothing — trust/demo damage |
| 4 | **Cloud / Google Drive backup + auto-backup** | [known-deferred] | Phone/PC loss = permanent book loss; biggest reason SMBs pay Vyapar — and the local backup path is currently broken (core audit C1) |
| 5 | **E-mail / SMS invoice delivery** | [partial] (WhatsApp done) | Party email captured but unused; B2B customers need e-mail |
| 6 | **Import from Tally / Vyapar / Excel** | [known-deferred] | Migration cost decides adoption; CSV is export-only |
| 7 | **Credit-limit & overdue-interest enforcement** | [partial] | Fields captured but nothing reads them; interest is a hard-coded PDF string |
| 8 | **Hindi / regional language (i18n)** | [missing] | A large share of target users are Hindi-first |
| 9 | **App lock / biometric** | [missing] | Books on a shared shop phone with no lock is a non-starter vs Vyapar |
| 10 | **Recurring invoices + scheduled reminders** | [missing] | Retainers/AMC/SaaS billing is common; reminders are manual taps |
| 11 | **TDS/TCS computation & reporting** | [missing] (dead columns) | Collecting TCS without computing it is a compliance risk |
| 12 | **POS / quick-bill + thermal printing** | [partial] ✅ §17 | Quick-bill and label printing shipped; **ESC/POS receipt printing still missing**, so a customer bill still goes through the OS dialog |
| 13 | **Multi-godown / batch-expiry / item images / unit conversion** | [known-deferred] / [missing] | Retail & pharma/food SMBs can't run stock without these |
| 14 | **Tests on money paths: `invoice_pdf.dart`, `report_repository.dart`, editor save-totals; plus CI** | [partial] | 87 tests but the printed PDF and every P&L/day-book number are unverified |
| 15 | **Performance: unbounded `watchAll`, never-drained `sync_queue`, UI-thread report aggregation** | [partial] | Degrades exactly when a real business gets big (1000+ items) |

**Runners-up:** purchase-order → bill · voucher attachments · HSN-wise & item-wise reports · trial balance/balance sheet · bank reconciliation `[known-deferred]` · dark-mode + phone/desktop goldens · branded launcher icons · crash reporting · accessibility (`Tooltip`/`Semantics` = 0) · GSTR-9 `[known-deferred]`.

---

## Related audit files
- `audit/01-core-logic-audit.md` — data-layer & business-logic bugs (backup data loss, P&L double-count, stock/payment integrity, GSTR computation).
- `audit/02-ui-ux-audit.md` — screen/widget-level UI and interaction bugs.

---

## RESOLUTION NOTES — 2026-09-27

**Done this pass** (94/94 tests, analyzer clean, committed to git):

| Gap | Status |
|---|---|
| A1 UPI QR inert | **Fixed** — `qr` package added; `lib/core/services/upi_qr.dart` builds `upi://pay` intents and paints the module matrix into the PDF; invoice PDFs show a scannable "Scan to pay via any UPI app" QR when `showQrOnInvoice` is on and UPI id is set (invoices only, not quotes). |
| A2 logo upload | **Fixed** — Firm Profile has a logo picker (file_picker, ≤2 MB, copied into `<docs>/logos/`, preview + remove); PDF header renders it (missing/corrupt file degrades gracefully). |
| A4 credit limit write-only | **Fixed** — sale editor loads party outstanding + credit limit and shows an advisory "Credit limit exceeded … You can still save." banner in the totals panel (Vyapar-style warn-don't-block). Credit *days* enforcement (due-date warning) still open. |
| A9 DN→invoice | **Fixed** — delivery notes now offer "Convert to invoice" in sale detail (convert pipeline was already generic). |
| A12 dead `/more` | **Resolved** — documented as sheet-only; More sheet highlights the active destination. |
| Hardcoded "Interest @18% p.a." | **Removed** — neutral fallback terms; real interest computation remains a feature request (3b). |
| Git + CI + litter | **Done** — `git init`, root litter deleted (12 files), full `.gitignore` (drift `.g.dart` files deliberately committed so CI can fail on stale generation), `.github/workflows/ci.yml` (pub get → build_runner staleness gate → analyze → tests), initial commit `c7b4305`. |
| Tests on money paths | **Partial** — new `test/audit_fixes_test.dart` covers UPI URI + WhatsApp link building; numbering deadlock regression test added. `invoice_pdf`/`report_repository` widget/DB tests still open. |
| Performance (gap 15) | **Partial** — `ItemRepository.watchAll` now capped (limit 1000). Sync-queue drain and isolate-based report aggregation still open. |

**Explicitly deferred** (large features / release engineering, each needs its own pass):
1. Release signing + versioning channel (gap 1 remainder — debug keystore TODO in `build.gradle.kts:36-39`).
2. E-invoice/IRN + e-way bill (2) — requires NIC/IRP integration.
3. Cloud/Drive backup + auto-backup (4) — depends on sync scaffolding decision.
4. E-mail/SMS delivery (5), Tally/Vyapar/Excel import (6) — format + UX design needed.
5. Hindi/regional i18n (8) — `.arb` + `l10n.yaml` scaffolding.
6. App lock/biometric (9) — `local_auth` integration.
7. Recurring invoices + scheduled reminders (10), TDS/TCS computation (11), ESC/POS receipt printing for the counter screen (12, the remainder of §17).
8. Multi-godown / batch-expiry / unit conversion (13) — schema work.
9. Branded launcher icons — assets exist (`assets/logo/atria_logo.svg`) but rasterizing SVG → mipmaps needs a tool run (`flutter_launcher_icons`); current icons are stock.
10. Dark-mode goldens, 360dp/1600px goldens, integration_test/, accessibility Semantics/Tooltip sweep (audit L-series partial: tooltips added where touched).
11. Remaining watchAll limits (parties), sync_queue payload + drain (A7/A8).
