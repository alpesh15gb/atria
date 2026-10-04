# TODO

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
- [ ] **Phase 3 — bulk actions.** In progress; commit when the suite is green.
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
- [ ] **Phase 5 — optional local PIN + roles.** Off must be indistinguishable
      from today. Off = no gate, no picker, every permission granted. Enforce in
      the repositories next to `assertDateEditable`, never in the UI. The gate
      is a **modal overlay on `MaterialApp.router.builder`**, not a router route
      — `resolveOnboardingRedirect`'s `refreshListenable` only pulses on
      `appInitializationProvider`. **`_neverExported` in
      `settings_repository.dart:155-172` is key-based and `firm_members` has no
      key column**, so the PIN hash/salt need a column-level strip on export.
      The `actor` param every repository already takes is always null, so a
      guard keyed on it is off until Phase 5 gives it a caller.
      - Copy must not oversell a 4-digit PIN as security.

## Open

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
