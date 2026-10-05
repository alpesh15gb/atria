# TODO

## The reporting build (2026-10-04)

Plan: `C:\Users\Administrator\.claude\plans\woolly-pondering-gray.md`.
**47 reports across 9 categories**, one shared export path (CSV + Excel + PDF
+ print), `/reports` becoming a categorized menu with today's card dashboard
kept as an "Overview" entry. Costing is **weighted moving average**; the schema
gaps (party groups, bank accounts, loans, godowns, TDS detail) get real tables
so nothing ships as a stub.

- [x] **Phase 0 — one date window.** Shipped. `ReportWindow` +
      `ReportWindowPreset` in `lib/core/reports/window/report_window.dart`;
      `ReportPeriodToolbar` and `AtriaDatePill` in `lib/shared/widgets/`;
      `PeriodRange.toWindow()`/`fromWindow()`. The three duplicate date-range
      implementations are gone (private `_Period`/`_DateRange` in
      `reports_screen.dart`, `_DatePill` in `period_selector.dart`,
      `DateTimeRange?` in `ledger_reports_screen.dart`).
      `test/report_window_test.dart` (30), six proven to fail against reverted
      code. Suite **754 / 0 failed**. **No behaviour change**, deliberately.
      - The quarter-end regression is now a *property of the type*, not of one
        call site — `resolve` is the only place a window is ever built, and a
        named window closes at its own fixed end. Only `thisMonth` ends at the
        wall clock, and only at day granularity.
      - **The asymmetry is load-bearing and easy to "fix" wrongly:** the six
        list screens' named windows stay open at the top (`to == null`) so a row
        saved ten seconds ago is not filtered out by its own period. The
        reports screen's close at 23:59:59. `toWindow()` preserves the list
        behaviour; do not unify the two.
      - `ReportWindow` deliberately has **two** labels. `label` is the preset's
        name; `spanLabel` is always the days. Report subtitles print
        `spanLabel` — "This Quarter" beside a number tells the reader nothing
        about which three months it covers.
- [x] **Phase 1 — schema v11: costing, godown, party groups.** Built and
      tested. `stock_movements.unitCost`/`sourceLineId`/`godownId`,
      `items.costingMethod`/`defaultGodownId`, `parties.categoryId`, the
      `godowns` table, WMA in `lib/core/database/costing/moving_average.dart`,
      stamped in **all three** movement writers, and
      `ItemRepository.backfillUnitCosts()` running at launch from `lib/app.dart`.
      `test/costing_test.dart` (25). Suite **779 / 0 failed**.
      - **A new table goes in three places or loses data silently:**
        `settings_repository.export`/`import`/`_clearAll` *and*
        `firm_repository.purge`. Both backup tests find tables by reading the
        schema, so a miss fails on the day it is made.
      - **`test/helpers/schema_rollback.dart`** now carries one block per schema
        version. Every migration test must call the newest block and re-assert
        the version, or the chain dies on `duplicate column name` and it reads
        as a broken migration.
      - **Three movement writers, not one:** `_recordMovement`, the
        `sales_repository.stockMovementsInsert` extension, and
        `reverseStockForSource`. Only the last was obvious; it copies the
        cost/line/godown of the row it reverses, because re-valuing a reversal
        at today's average leaks cost on every document edit.
      - **Oversold stock carries its liability.** 10 @ 20, sold 15, then 10
        bought @ 30 leaves 5 units at **40**, not 30.
- [x] **Phase 2 — schema v12: bank accounts, loans, TDS metadata.** Built and
      tested. `lib/core/database/tables/banking.dart` — `BankAccounts`,
      `Loans`, `LoanTransactions`, `Gstr9Adjustments`; plus
      `purchase_bills.deducteePan`/`tdsSection`/`tdsSectionRate`,
      `payments.bankAccountId`, `expenses.itemId`. All four tables in
      `settings_repository.export`/`import`/`_clearAll` **and**
      `firm_repository.purge`. `test/migration_v12_test.dart` (2).
      Suite **782 / 0 failed**.
      - **A rollback that DROPs a table cannot assert that table's rows
        survive.** My first version seeded the new tables, rolled back (which
        drops them), and asserted the rows returned — the test was deleting the
        data it checked. "Rows survive" belongs on the additive columns only;
        the new tables get "exists, is empty, and a full row round-trips
        through it".
      - **Revert-proofing `_clearAll` needed a new test, not a new
        assertion.** Export and restore were covered; the wipe was not, so a
        missing delete was invisible. The new test asserts *no old id
        remains* — counts would pass on a merge.
      - `BankAccounts.type` includes `cash` deliberately: the Bank Statement
        report lists cash beside the bank accounts, and cash as the absence of
        a row would make the accounts list a lie.
      - TDS/interest fields are **snapshotted**, never re-derived. A 26Q filed
        against a guessed PAN is a notice, and a mid-term rate change must not
        rewrite what a February repayment was worth.
- [x] **Phase 3 — the framework.** Built and tested. `spec/report_spec.dart`;
      `engine/{report_result,report_runner,report_source,report_providers}.dart`;
      `catalogue/report_catalogue.dart` (9 categories, **46** definitions);
      `export/{report_export_service,report_pdf_builder}.dart`;
      `shared/widgets/report_data_table.dart`;
      `features/reports/{report_view_page,report_document_view}.dart`.
      `test/report_framework_test.dart` (25) + `report_export_test.dart` (21) +
      `report_pdf_test.dart` (10) + `report_widget_test.dart` (13).
      Suite **851 / 0 failed**, analyzer clean.
      - **The grand total is summed from the GROUPS, never the rows**, so
        `assertIntegrity` can check one against the other instead of trusting
        either. It has **three** invariants (column coverage, subtotals-vs-total
        in both directions, a declared column nothing ever filled), each
        individually revert-proven — the plan asked for one.
      - **`ReportCatalogue` registers 46, not 47.** The plan said 47; the
        reference menu lists GSTR 2, which no application can produce (the
        portal populates it). That slot ships as **"GSTR-2A Reconciliation"**,
        which is real work the app already does.
      - **The export button is unconditional** — it is the single line that
        makes "every report has an export affordance" true rather than
        aspirational.
      - [x] **The bespoke `ReportDocumentView` bodies** landed with Phase 4a.
            Four of the nine are done — P&L, Trial Balance, Balance Sheet, Cash
            flow, in `lib/features/reports/documents/`, behind a plain map in
            `document_registry.dart`. Dart has no top-level statements, so a
            document file **cannot self-register on import**; a lazy static would
            mean a builder is missing until something touches it, which is a
            blank screen on one report and no error. The map is exhaustive at
            compile time. The other five land with their categories.
      - [ ] **Still open:** the route wiring for `ReportViewPage(reportId:)` into
            `/reports` is Phase 5.
- [ ] **Phase 4 — the 47 reports**, one commit per category.
      - [x] **4a Transaction (9).** All nine shipped. Sale · Purchase · Day book ·
            All Transactions · P&L · Bill Wise Profit · Cash flow · Trial Balance
            · Balance Sheet, plus four bespoke documents.
            `test/report_transaction_test.dart` (54) + `report_document_test.dart`
            (10). Suite **915 / 0 failed**, analyzer clean. **Seven real product
            defects found and fixed**, each proven by reverting it and observing
            the failure — the worst being that month grouping never worked at all
            (every month-grouped report collapsed into one `?` heading), that
            All Transactions silently dropped every hand-keyed voucher, and that
            `CallbackReportSource` never overrode `build` so *every*
            callback-sourced report threw. Details in `.claude/STATE.md`.
      - [x] **4b Party (6).** All six shipped. Party Statement · Party wise P&L ·
            All parties · Party Report By Item · Sale Purchase By Party · Sale
            Purchase By Party Group, plus the **filter bar the six needed** —
            `ReportFilterBar` in `lib/shared/widgets/`, wired into
            `ReportViewPage`. `test/report_party_test.dart` (31) + 2 in
            `report_framework_test.dart`. Suite **946 / 0 failed**.
            - **A spec is a `const` and cannot hold the party's id.** The firm
              adds a customer and the spec does not know. So the filter declares
              itself and the source answers it: `ReportSource.optionsFor` +
              `CallbackReportSource.options`, with a named top-level
              `partyOptions` because a `const` definition cannot contain a
              closure calling `Future.value`. Both halves stay testable alone.
            - **`reportFilterOptionsProvider` is separate from
              `reportResultProvider` on purpose** — the party list changes when a
              customer is added, and folding it into the result would re-run a
              5,000-row report on every keystroke in the picker.
            - **A filter back at "All" REMOVES its key, not nulls it.** The key
              goes into `ReportQuery.cacheKey`; nulling it would make an
              untouched filter and a reset one differ, re-running the whole
              report to produce the same answer.
            - **Three real defects found, all the same shape.** A credit note
              stores its **tax columns positive**, and so do its **discount
              columns** — the engine took a positive discount off a line whose
              quantity was already reduced, so each number is positive alone and
              only their combination carries the sign. Summing either unsigned
              reports 180+72 for a ₹1,000 sale with a ₹400 return. Output tax
              then exceeds what was ever collected. Both now group by `docType`
              as well as party and sign in Dart, because the `SUM` arrives with
              the document's identity detached and `SUM(CASE…)` would put an
              accounting rule inside a SQL string no test can read.
              `ledgerSignFor` — a second sign rule with no report to govern —
              was removed rather than shipped.
            - **`ReportGroupBy.category` reads the `category` cell**; the group
              source emits `group`. Every row read as missing and landed in one
              bucket named `?`, collapsing six rows into a single subtotal band
              sorted by value. Now passes `groupKey` explicitly.
            - **Party Statement totals on `grandTotal`, deliberately and alone**,
              because what a party owes includes tax. It will not foot against
              the P&L and that is correct.
      - [x] **4c Item/Stock (11).** Shipped. All eleven registered in
            `ReportCatalogue`; sources in
            `lib/core/reports/sources/item_stock/`; `StockDetail` gets a
            bespoke `ReportDocumentView` (a running balance is not readable in
            a grid). `test/report_item_test.dart` (22),
            `test/item_common_test.dart`. Suite **990 / 0 failed**.
            - **Three real defects, each revert-proven.**
              `stock_detail` accumulated the running balance **only inside the
              window**, so the opening balance — which *is* the sum of the
              out-of-window rows — was skipped, and a June sale after a January
              purchase reported a balance of −2. Every movement moves the
              balance; the out-of-window rows are carried for exactly this.
              `item_common.marginPercent` called `Rational.toDecimal()` with no
              scale, which **throws** on a non-terminating ratio — 66.67% of
              three-quarters was a crash, not a number. `toDecimal` also
              *truncates*, so converting straight to 2 places gives 66.66 where
              `Money.round2` gives 66.67; the fix converts at scale 6 then
              rounds once.
              `item_wise_discount`'s `gross` omitted the document allowance, so
              `gross − discount ≠ net` on every row the reader was invited to
              check.
            - **The invoice-discount share is read back from the books, not
              apportioned a second time.** `GstEngine` apportions the header
              allowance for tax and then *discards* the per-line result — but
              since `taxableValue = round2(base.taxable − share)`, the share is
              recoverable exactly. Dividing again in the report means a second
              apportionment that must agree with the first to the paisa, and the
              bills that divide badly (three of the same thing — the commonest
              bill there is) are precisely the ones that come out wrong.
              The *base* comes from `GstEngine.computeLine`, not a second copy
              of its arithmetic: a line discount can be a percentage, an
              amount, or both with clamping, and inclusive lines **back-calculate**
              `taxable`. Proven: with a naive `gross − discount` base an
              inclusive line's share reads 280 instead of 100 — ₹100 of
              discount inflated by the ₹180 of tax the customer paid on it.
              - **`gross − discount == net` is an exclusive-line identity
                only.** On an inclusive line the gross carries the tax, so it
                reconciles to the taxable *through* the tax. Asserting it there
                would be asserting the bug the delegation exists to avoid.
            - **`ItemRepository` is write-only** — no `get`. Fixtures read
              `db.select(db.items)`. Use a `patchItem(id, change)` helper: the
              `put((await storedItem(id)).copyWith(…))` shape has two `await`s
              and only one on a Future, which the analyzer rightly flags every
              time.
            - **Nothing in `lib/` writes `transfer_in`/`transfer_out`.** The
              godowns table and `godownId` column exist (v11) and Stock Transfer
              reads them, but there is no transfer entry UI. The test writes
              movements straight to the table and says so — the missing piece
              is the screen, not the report.
      - [x] **4d GST (6).** All six shipped. GSTR-1 / GSTR-3B / GSTR-9 read
            `GstReturnBuilder` — the same code that generates the portal JSON, so
            screen and upload agree by construction rather than by two
            implementations coinciding. GSTR-9 had no builder and sums the
            year's monthly 3Bs, because an annual return is the filed returns
            added up, not a second opinion about the year. Sale Summary By HSN
            and SAC Report read line rows. `test/report_gst_test.dart` (29).
            Suite **1032 / 0 failed**, Android debug APK green.
            - **The GST rate is derived from each line's own tax, never the item
              master.** An inclusive line and a discount both move the rate a
              line was actually taxed at; the master holds the rate for the
              *next* invoice, so reading it rewrites the history of everything
              filed at the old one. `Decimal /` returns a `Rational` whose bare
              `toDecimal()` throws on a non-terminating fraction — convert at
              scale 6, round HALF_UP once.
            - **A credit note and a debit note are negative.** Both are stored
              with positive tax columns; the sign belongs to the doc type.
              Summing either as stored overstates outward supply and input
              credit, and the portal computes the liability from the figure
              filed.
            - **An unregistered firm files no return**, so every GST source
              returns no rows and says why. Most firms here are in that
              position, and a return-shaped document that reads like a filed
              liability is worse than an empty screen.
            - **Six defects found and fixed, each revert-proven by in-place
              mutation** (the sources were untracked, so git stash could not
              reach them):
              - GSTR-1 invented a Table 7 document count. The portal aggregates
                Table 7 by place and rate, so there is none — the cell is a dash
                now, because a zero would claim nothing was sold.
              - GSTR-1 filed the invoice's face value as the taxable value,
                inflating Table 4 by exactly the tax charged. It sums item rows.
              - The 2A file was keyed by firm alone, so a clean April would be
                reconciled against May's file. Keyed per return period; the test
                imports May, asks for April, and asserts April finds nothing
                while May finds its own.
              - GSTR-9 ignored `direction`, so a reduction stored as a positive
                amount was *added* to the figure it corrected.
              - Every GST report defaulted the nullable window differently, so
                an open-ended window read a different period per report.
                `windowFrom` / `windowTo` in `gst/gst_common.dart` decide once.
      - [ ] **4e Business Status + Taxes (8)** — 2 of 8 shipped.
            - [x] **Discount Report** (Business Status) and **GST Rate Report**
                  (Taxes) — `e7d5e3f`. Sources in
                  `lib/core/reports/sources/business_status/`;
                  `test/report_business_status_test.dart` (17). Suite
                  **1049 / 0 failed**.
                  - **Both read what was filed, not what is configured.** The
                    rate comes from each line's own tax; `items.gstRate` is the
                    rate for the *next* invoice, so reading it would erase every
                    month sold at the old one.
                  - **The invoice allowance's per-line share is recovered from
                    the books**, as `item_wise_discount` already does. A test
                    splits a ₹10 allowance across three equal lines and asserts
                    the shares sum to exactly 10 — largest remainder gives
                    3.33/3.33/3.34, and any straight division produces a
                    different set, which is exactly where the reader's own
                    `gross − discount == net` check would fail by a paisa.
                  - **Two defects, each proven by mutating the source in place:**
                    a **percentage discount reported as zero** (the stored
                    `discountAmount` column holds only the amount half;
                    `discountPercent` is separate, so the report said "no
                    discount given" about an invoice showing ₹500 off — the line
                    discount now comes from `GstEngine.computeLine`, the same
                    call the tax was computed from), and the **rate report merged
                    services into goods** by reading the HSN rather than
                    `items.isService`.
            - [x] **Bank Statement** (`76655a0`) — the last of Business Status,
                  so that category is finished. `test/report_bank_statement_test.dart`
                  (14). **The opening balance is derived, not assumed**:
                  `bank_accounts.currentBalance` is the balance *now* and
                  already contains the period, so the report subtracts the
                  period's movements back out to reach the opening. Adding
                  instead of subtracting is a report whose last line is
                  `currentBalance` **plus** the period — out by exactly the
                  activity the reader came to check, and the tests caught it on
                  the first run with the fixture asserting the right answer.
                  Cash in hand is a real `BankAccounts.type` row and is listed
                  beside the bank accounts; an uncleared cheque is not money; an
                  account with no movement still gets a row.
            - [x] **TDS Payable, Form No. 27EQ, TCS Receivable** (`841cf3e`) —
                  `test/report_taxes_test.dart` (14). Suite **1079 / 0 failed**.
                  - **The write path was missing and had to be built first.**
                    `purchase_bills.deducteePan` / `tdsSection` /
                    `tdsSectionRate` have existed since v12 and **nothing wrote
                    them** — a column that passes a schema test and means nothing.
                    `PurchaseDraft` now carries all three; `save` stamps them,
                    taking the PAN from the supplier's party when the caller does
                    not supply it (that is where the purchase editor has it), and
                    **only when a deduction was actually made**.
                  - **Every field is a snapshot and is read as one.** The amount
                    is the stored `tds`, never the rate re-multiplied — what was
                    deducted is a function of that bill's taxable value.
                  - **27EQ aggregates the way the form is filed** — one line per
                    deductee per section, where TDS Payable is one row per bill.
                    Keyed on PAN + section, not the party id.
                  - A missing PAN or section reads **"Not recorded"** rather than
                    blank: a quarter filed without one of those lines is a short
                    return, and the reader must see it is *their* missing field.
            - [ ] **GST Report** and **TDS Receivable** stay placeholders
                  **on purpose.** `sales_invoices.tcs` is tax collected *from* a
                  customer, so it is the TCS report and nothing else; tax a
                  customer deducted *from us* is a different fact on a different
                  line of the return and **no column stores it** (needs schema
                  v13). TDS Receivable was written once, found to be
                  byte-for-byte the TCS report, and deleted — two
                  identically-worded reports reading one column is worse than an
                  honest empty one. **Do not "fix" either by wiring an existing
                  column.** GST Report is the monthly GST summary and GSTR 3B
                  already answers it.
      - [ ] **4f Expense (3) + S/P Order (2) + Loan (1)** — **next**, all six
            still placeholders. `expenses.itemId` exists so Expense Item Report
            can span purchases *and* expenses without matching a typed
            description; null-`itemId` expenses must still appear. Loan
            Statement needs `principalAmount` **and** `amount` — interest does
            not reduce principal, which is what separates paying off the loan
            from paying this month's interest. A purchase order is not a bill and
            a sales order is not money: `kSalesDocTypes` / `kPurchaseDocTypes`
            exclude them deliberately, and a report that ignores that disagrees
            with the Trial Balance by every pending order.
- [ ] **Phase 5 — retire the dashboard** to the menu + Overview entry.
      `gst_reports_screen.dart` **stays**; `/gst-reports` keeps a `redirect`.
      Also registers the two new document-shaped GST reports in
      `lib/features/reports/document_registry.dart`.

## The agreed six-phase build (2026-10-04)

Plan: `C:\Users\Administrator\.claude\plans\woolly-pondering-gray.md`.
**One piece per commit.** Each is verified (analyzer clean, full suite green,
new tests proven to fail against reverted code) before its commit.

- [x] **Phase 0 — PDF template system.** Shipped. `firms.pdfTemplate` (schema
      v8), `PdfTemplateStyle` (classic / modern / minimal), `InvoicePdf` is now
      an instance class reading `style.*`, Firm Settings swatch picker,
      `test/pdf_template_test.dart` (5). **This is the enabling refactor** —
      everything below inherits the style system.
- [x] **Phase 1 — purchase-side PDFs.** Shipped `7bf9a6b`. `PurchasePdf`
      (bill / purchase order / debit note / payment voucher), the row-menu gate
      widened to purchases + payments, Preview kept sales-and-invoice only.
      Party roles invert, TDS is a deduction, no collect QR.
      `test/purchase_pdf_test.dart` (11).
- [x] **Phase 2 — paid / balance due / PAID stamp + the UPI QR bug.** Shipped
      `bd860de`. The QR now encodes the balance, not the grand total, and both
      it and the bank block disappear when nothing is outstanding. Amount Paid /
      Balance Due print below the grand total via `totalsTable`'s new
      `afterGrand`; the header carries PAID IN FULL / CANCELLED. Purchase bills
      too. `test/invoice_settlement_pdf_test.dart` (12); six of them confirmed
      failing against reverted code.
- [x] **Rename to Apex Books.** Shipped. Brand strings, Android `applicationId`
      (`com.apexbooks.app`), Windows binary + version resource, installer, and
      the `apexbooks` export/book folder. Old books folder is moved across on
      first launch (Windows only — see `DECISIONS.md`);
      `test/app_data_dir_migration_test.dart` (10). **Left as `Atria` on
      purpose:** Dart package name, `Atria*` classes, `atria_*.dart` filenames,
      the `.atriabak` constant, the server's `ATRIA_*` env vars.
- [x] **Phase 3 — bulk actions.** Shipped `8f9f1fc`.
      - [x] `confirmDestructive` extracted (**11** call sites, not 8).
      - [x] `BulkSelection` + `bulkSoftDelete`/`bulkRestore` in
            `lib/core/bulk/bulk_actions.dart`.
      - [x] `SalesRepository.softDelete`/`restore` now return `Future<bool>` —
            a delete that changed nothing must be reported, not counted.
      - [x] `CsvExport` — all five methods take `{Set<String>? ids}`.
      - [x] `BulkSalesActions` + `BulkPdfShare` (share seam injected).
      - [x] `SelectionBar`.
      - [x] Wired into the Sales list: `_SelectionBox` pinned to the table's
            fixed 50px leading slot (the card list keeps the doc glyph beside the
            checkbox; the table list drops the glyph rather than drift every
            flexed column), selection reconciled into a local in `build`.
      - [ ] **Still open:** items / parties / expenses / purchases lists are
            unwired. The plan named the Sales list specifically, and the point
            that matters — a selection that prunes itself against what is on
            screen — is proven there first. Do not spread it until the pattern
            survives a real session.
      - [ ] `parties_screen.dart:340-343`'s private selection highlight was
            **not** extracted to a shared widget. Duplicated rather than
            generalised: one caller is not an abstraction yet. Revisit if a
            second list needs it.
- [x] **Phase 4 — quotation lifecycle.** Shipped. `convertedToInvoiceId` +
      `convertedAt` added at schema v9; `markConverted` now records the link and
      leaves `status` alone; one `DocumentStatus` enum replaces `StatusChip.doc`
      and the list's private pair; `expired` is computed from "Valid till";
      a status filter on the sales list whose value is in the stream cache key.
      - **Corrections from the plan review, all applied:** `'converted'` rows are
        kept as `convertedLegacy` — not migrated, because the linked invoice id
        was never stored and rewriting them re-enables double conversion on
        real data. `markCancelled` now refuses them. `watchOverdue`'s
        `!= 'converted'` clause left alone (harmless; `docType` is pinned to
        `invoice` there, so it was always dead). `db.assertDateEditable` still
        throws bare `Exception`, not `PeriodLockedException` — **pre-existing,
        still open**, see below.
      - The stream cache key did gain the filter, as it must.
- [x] **Phase 5 — optional local PIN + roles.** Shipped. Off is
      indistinguishable from today: `MemberSession.off` grants every
      permission, so nothing in the write path can tell "off" from "no such
      feature". Schema v10 adds `pinHash`/`pinSalt`/`isActive`;
      `MembersRepository` salts and iterates per user and **returns null** on a
      wrong PIN rather than throwing; enforcement lives in **nine
      repositories** beside `assertDateEditable`, never in the UI; the gate is
      a **modal overlay on `MaterialApp.router.builder`**, not a route, and
      returns its child untouched when off. Deep routes are blocked by a
      `redirect` too — hiding nav entries is one URL away from useless.
      `test/member_roles_test.dart` (39) + `test/pin_gate_widget_test.dart`
      (10); every one revert-proofed. Suite **723 / 1 skipped**.
      - The export strip had to become **column-level**: `_neverExported` is
        key-based and `firm_members` has no key column. The first version wrote
        `"pin_hash": null` — omitting the key is the point, and naming it in the
        JSON is not omitting it.
      - `signIn`/`signOut`/`disable` each write **both** the controller state and
        `AppDatabase.session`. An overlay hidden over an app that is still
        filtering writes by a stale role is the worst outcome available.
      - Copy does not oversell a 4-digit PIN as security.
      - [ ] **Manual pass still owed** — no one has signed in through the gate
            or exercised a role on hardware. The highest-risk regression is the
            gate appearing for a firm that never asked for one.

## Open

- [ ] **Mobile: bottom-sheet pickers in the editors.** The reference uses
      full-width `⊕ Select Customer` / `⊕ Select Products` rows under grey section
      headings rather than dropdowns; Apex's sale, purchase and expense editors
      still open dialogs on a phone. The largest remaining gap between Apex and
      the reference on a handset, and it touches three editors, so it wants doing
      properly rather than as a side-effect.
- [ ] **A test that asserts a desktop widget under `flutter test` proves
      nothing.** The runner defaults `defaultTargetPlatform` to **android**, so
      any width-based assertion in a test that has not declared its platform is
      exercising the phone widget and passing anyway. This has now bitten this
      repo **three times**: seven tests in `53b2ba2`, two more in
      `settings_widescreen_test.dart`, and the mobile work above. Every widget
      test that says "desktop" sets
      `theme: AppTheme.light().copyWith(platform: TargetPlatform.windows)`;
      tests whose subject *is* the phone layout say `android` explicitly.
- [ ] **A test that re-pumps with a different `ThemeData` needs
      `pumpAndSettle`, not `pumpWidget`.** `MaterialApp` **animates** a theme
      change, so a second `pumpWidget` renders one frame of the *previous* theme.
      A test that pumped the phone platform and then the desktop one read the
      phone's colours twice and concluded the platform gate did nothing — a test
      shaped exactly like one checking the gate. `test/mobile_list_grammar_test.dart`
      documents this at its `pumpAt` helper.
- [ ] **`test/le_trust_store_live_test.dart` is excluded from default runs**
      (`live-tls` tag, needs the internet and hits production). Run it
      deliberately with `flutter test --tags live-tls` after any change to the
      API layer's TLS handling. It also needs `openssl` on PATH, which Git for
      Windows does not provide — it ships one under `usr/bin` — so the test
      looks it up in the usual install locations and skips with a reason rather
      than failing as a broken trust store.
- [ ] **Confirm the sync fix against the real server.** The line-item loss is
      fixed and regression-tested against a faithful fake (`ec7df48`), but the
      device that reported it still needs a real `.vyb` re-import + sync +
      phone pull. Until that happens the fix is proven in a harness, not in the
      user's hands.
- [ ] **HIGH — non-atomic page apply in `PullApplier`.** A pull applies changes
      one at a time and advances the cursor regardless of failures, so a single
      rejected change (e.g. an FK orphan — `PRAGMA foreign_keys=ON` in
      production, OFF in the in-memory test DB, which is why no test catches the
      class) is counted `skipped` and lost permanently and invisibly. The
      batch-size bug above lived in the same file's neighbourhood.
- [ ] **HIGH — `UnsavedGuard` is dead on both nav rails.** `adaptive_nav_shell`
      calls `context.go(entry.route)` at :588 and :634; `go` bypasses
      `PopScope`, so a rail click leaves a half-typed invoice with no prompt and
      no guard. All 8 guarded editors affected. Needs `canPop` consulted before
      navigating (or `goBranch` semantics matched to `PopScope`).

- [ ] **MEDIUM — editing a payment breaks the cheque-state invariant.**
      `payments_screen.dart` ~845–867 keeps `chequeStatus` when the mode
      changes: cheque→cash leaves a stale `pending`/`cleared` on a cash
      payment, cash→cheque leaves `chequeStatus` null so the cheque never
      appears in "Cheques to deposit". The last real correctness item from the
      2026-10-03 audit. Test to write: flip the mode both ways and assert the
      stored `chequeStatus` matches the mode.
- [ ] **Exports / SEZ supplies cannot be recorded at all** — nothing in `lib/`
      sets `isExport`, and `exportType` (`wp`/`wop`) is persisted but read
      nowhere. This is what blocked the two GST "HIGH" findings as unreachable.
      A feature addition (a WP/WOP choice in the sale editor + EXPWP/EXPWOP
      tables in `gstr1_report`), not a calculation fix. Decide as
      post-launch scope.
- [ ] Rebuild + install debug APK on the Android device to confirm the route
      fix on hardware (pure-Dart change; gradle surface untouched).
      **Builds are green as of 2026-10-05** — `flutter build apk --debug` →
      `build/app/outputs/flutter-apk/app-debug.apk` (203 MB) and
      `flutter build windows --debug` → `build/windows/x64/runner/Debug/apex_books.exe`.
      Both succeed on this machine. **Neither has been run on the target
      hardware**, and a build that compiles is not evidence the menu works.
- [ ] **Compare the app against the top accounting apps** (asked 2026-10-05).
      Gap analysis against Vyapar / Khatabook / Zoho Books / TallyPrime / Busy /
      WinApp. Not yet done.
- [ ] Release builds: `--release` for Windows and APK (APK needs a signing
      config; the template signs with debug keys today).
- [ ] The three `*_plus` plugins still apply the Kotlin Gradle Plugin; a future
      Flutter will refuse `build apk` until they migrate to built-in Kotlin.

## Done

- [x] **Android "items don't render in saved bills" — root cause found and
      fixed (`ec7df48`).** Push batches were sized by row count, not bytes; the
      server refuses >256KB whole, so the header rows went through and the line
      rows were thrown away — the phone pulled bills with totals and no items.
      Also fixed: unsendable rows were marked *sent* and then pruned (data
      existed nowhere while sync reported clean), and "Re-send all books" was a
      no-op on any row already parked. Four new tests in
      `test/vyapar_sync_roundtrip_test.dart` reproduce the real `.vyb` →
      server → phone pipeline. Suite 574/1 skipped. Full write-up in
      `.claude/STATE.md`.

- [x] **Go-live verification pass (2026-10-03):** four real bugs found and
      fixed, each with a test proven to fail when the fix is reverted —
      (1) the account-ledger Balance column was not a running balance;
      (2) Indian-grouped amounts ("1,00,000") silently parsed as 0 in the
      journal editor and the chart of accounts; (3) **party opening balances
      never reached the books**, so Sundry Debtors disagreed with every
      customer statement by exactly the opening; (4) the Payments cards
      disagreed with the ledger because they summed payment rows alone.
      Suite **439 passed / 1 skipped / 0 failed**, `flutter analyze lib/ test/`
      clean. See `.claude/memory/bugs.md` (items 34–37).
- [x] **Android + Windows alignment pass (2026-10-03):** pumped every tab at
      360×640 and the dashboard/sales list at 1920×1080 with the app's real
      Inter registered, and fixed the thirteen layout defects that surfaced
      (pill-label overflow, dashboard trend bars, the POS pane squeezing the
      cart, `EmptyState` in a flex parent, ledger column headers and running
      balance, sale-detail meta chips and table floor, list trailing slots,
      journal/chart/ledger ellipsis, payments summary cards, the reports rate
      table's misaligned amounts). `contentMaxWidth` was dead code — now used
      by `AtriaListPage`, plus a new `AtriaContentWidth` for the four settings
      screens that stretched full-width. Five new test files, each verified to
      fail without its fix. Suite **435 passed / 1 skipped / 0 failed**,
      `flutter analyze lib/ test/` clean. See `.claude/STATE.md` and
      `.claude/memory/bugs.md` (2026-10-03 sections).
- [x] Editor screens revamped (2026-09-26):** shared EditorShell chrome
      (exit ✕ / title / Save & New / Save + sticky totals panel on desktop,
      `editor_shell.dart` + `editor_totals.dart`); sale editor gained Save &
      New, Mark-as-fully-paid settlement on save, dashed Add-Item strip,
      collapsible Notes/Charges; purchase editor same treatment; item/party/
      expense got the EditorAppBar. Tests `editor_shell_test.dart` (2).
      Suite 69/69, analyzer clean.
- [x] **List screens revamped (2026-09-26):** shared transaction toolkit
      (`transaction_list.dart`: TotalsCard, search field, unified rows with
      kebab actions, desktop table grid); sales/purchase/expenses rebuilt on
      it; convert-to-invoice from quote/order rows; expenses search + Net-P&L
      card; shared Period pills everywhere. Goldens regenerated. 67/67.
- [ ] Golden teardown: dashboard/settings captures hang after writing their
      PNG (pre-existing, capture-only; others settle). Investigate drift
      stream teardown on those two screens when convenient.
- [x] **Android "route /onboarding/firm-setup does not exist" fixed
      (2026-09-26):** single app-lifetime router with `/boot` splash route
      (park-and-resume relaunch locations, refreshListenable pulse), branded
      recoverable 404 page; bonus fix: firm-setup no longer a dead end once a
      firm exists ("Add another business" worked before). Root cause was the
      boot-router swap meeting Android's restored launch route. Regression:
      `test/router_boot_regression_test.dart` (gate-held executor). 67/67.
- [x] **Vyapar-inspired feature pass (2026-09-26):** credit/debit/delivery
      notes (tabs + editors + numbering), recycle bin with guarded
      delete-forever, CSV export with BOM, payment reminders with WhatsApp
      nudge, barcode label PDFs, schema v2 migration. Fixed: build_runner
      zero-builder pubspec trap, stale-snapshot numbering race.
      64/64 tests, analyzer clean.

- [x] **Missing features & UX pass (2026-09-26):** expense/income editing
      (route + editor + tappable rows), real WhatsApp deep-link share, item
      delete & duplicate, quotation/order → invoice conversion with converted
      status, stock adjustment dialog, per-tab sales FAB label, Ctrl+S on all
      editors, shared PeriodPillRow with ripple, unused deps removed.
      56/56 tests, analyzer clean.

## Later

- [ ] Cloud sync is deliberately relabelled EXPERIMENTAL, not implemented. If/when the
      user wants it real: add `Supabase.initialize` + a worker draining `sync_queue`
      (all 7 entities already enqueue insert/update/delete), and revert the Settings copy.
- [ ] Remove stale repo-root artifacts (`analyze*.txt`, `test_out.txt`, `build_out.txt`,
      `HANDOFF.MD`, `LEFTOFF.MD`, `status.md`).
- [ ] Fix remaining deprecations noted in `status.md` (`withOpacity` -> `withValues`).

## Completed

- [x] **Bug hunt finished (2026-09-26).** Every CRITICAL and HIGH item in
      `.claude/memory/bugs.md` is fixed and regression-tested: invoice/purchase
      edit corruption, double stock deduction, per-line tax never persisted,
      invoice discount double-count, boot-failure recovery, unsaved-changes
      guards on all four editors, GSTIN validation, dashboard KPI staleness,
      cancelled-invoice chip, editor/footer totals mismatch.
      `dart analyze lib/` clean; `flutter test --exclude-tags golden` 44/44.
- [x] Eyeball all 6 light-mode goldens — dashboard, sales, parties, items, reports,
      settings all render legibly (2026-09-25). Regenerated after the blue rebrand.
- [x] Relabel Cloud Sync "EXPERIMENTAL / Coming soon" in Settings at the user's request —
      the toggle persisted a flag nothing reads, which was the one fake feature left (2026-09-25).
- [x] Stop the golden suite failing `flutter test`: `@Tags(['golden'])` on `library;` +
      `exclude_tags: golden` in `dart_test.yaml` + a 2-minute per-test timeout (2026-09-25).

## Completed (earlier)

- [x] Add persistent Claude Code memory.
- [x] Add 128k-safe context recovery workflow.
- [x] Fix all 67 compile errors across 11 files (2026-09-24).
- [x] Clear all analyzer warnings — `flutter analyze` reports no issues (2026-09-25).
- [x] Verify `flutter test` passes — now 22/22 with goldens excluded by default.
- [x] Unblocked all native builds: vendor-patched phosphor_flutter, fixed Android
      compileSdk 36 + Kotlin incremental cache issue (2026-09-25).
      `build windows --debug` and `build apk --debug` both succeed.
- [x] Fix "Get Started"/"Skip" doing nothing — root cause was a `FutureProvider`
      onboarding flag the router redirect cached forever, which made *every* button
      in the app look dead (2026-09-25). Now synchronous `StateNotifier` state.
- [x] Fix opening stock double-counting in `ItemRepository.create` (2026-09-25).
- [x] Rebrand primary colour green -> blue across theme, logo, PDF, avatar palettes
      (2026-09-25).
- [x] Light-mode contrast fixes: overdue-hero gradient no longer fades to pale pink
      under white text; `outline` strengthened from 1.23:1 to ~1.7:1 (2026-09-25).
- [x] Test coverage 11 -> 22: onboarding redirect regression tests, persistence
      round-trip tests for parties/items/sales/purchases/expenses, light-mode goldens
      (2026-09-25).
