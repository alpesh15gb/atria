# Project State

_Last updated: 2026-09-27 (hotfix pass: Payments Decimal crash + Parties overflow)

## Current objective

Bring Atria to a clean, production-ready baseline: zero analyzer issues, passing tests,
and building binaries for every target. Then fix the functional/UX bugs the user reported.

## Current implementation state

- Working:
  - Full Flutter app: GST invoicing, purchases, parties, stock, expenses, reports, PDF.
  - `dart analyze lib/` → **No issues found!**
  - `flutter test --exclude-tags golden` → **87/87 passing** (up from 84).

## Closed this session (2026-09-27, hotfix pass #2)

User screenshots showed two bugs against the fresh build; both fixed + regression-tested.

- **Payments screen crashed: 3 red error cards** (`type 'Decimal' is not a
  subtype of type 'num'`). Cause: `_SummaryCard.value` was declared `dynamic`
  and call sites passed `Money.of(...)` (a `Decimal`); the card body did
  `Formatters.money(value is Money ? value : Money.of(value))`, whose implicit
  dynamic→num downcast threw at runtime. Fix: field typed `Decimal`, body is
  `Formatters.money(value)`. `lib/features/payments/payments_screen.dart`.
- **Parties row overflow (22px)** in the master pane: the GSTIN + phone line
  under the party name had no ellipsis. Fix: both `Text`s wrapped in
  `Flexible` with `maxLines: 1` + ellipsis, GSTIN gap 8→6, avatar gap 12→10
  (letterSpacing 0.4 restored; a bad edit that set it to 0.12 was reverted).
  `lib/features/parties/parties_screen.dart` `_rowBody`.
- **New tests (3)**: `test/payments_screen_test.dart` — summary cards render
  real money (`₹1,330.00` / `− ₹4,500.00`, `takeException` null) and row-kebab
  Delete soft-deletes (`getById().isDeleted`, live list empties; NOTE: assert
  with `getById`, not `watchDeleted().first` — awaiting a drift watch stream
  inside widget-test fake-async hangs). `test/parties_master_detail_test.dart`
  — GSTIN+phone row renders with `takeException` null at 1600x1000.
- Verified: analyzer clean (lib+test), full suite **87/87**, Windows Debug exe
  + debug APK rebuilt (both exit 0).

## Closed this session (2026-09-27, GST & controls pass)

- **SCHEMA v3** (`AppDatabase` schemaVersion 3, migration `from < 3`):
  `deletedAt` added to sales_invoices/purchase_bills/payments/expenses (document
  recycle bin) + new `AuditLogs` table (append-only: action/entity/entityId/
  summary/details/actor). build_runner regenerated.
- **GST returns (researched: GST portal v1.1 JSON schema)**:
  `core/reports/gstr1_report.dart` (models + portal JSON: b2b/b2cl/b2cs/cdnr/
  cdnur/hsn/doc_issue; fp=MMYYYY, dates DD-MM-YYYY, rchrg/inv_typ fields),
  `gst_return_builder.dart` (GSTR-1 computation grouped from invoice lines +
  `buildGstr3b` tables 3.1/3.2/4/5 + GSTR-2A import/reconcile),
  `gst_export_service.dart` (JSON + BOM'd Excel-openable CSVs into
  Documents\atria\gst\<fp>\). Screen: `features/reports/gst_reports_screen.dart`
  at `/gst-reports` (period stepper, per-table views, export buttons, 2A JSON
  import → matched/books_only/portal_only/value_mismatch with totals).
  GSTR-2A reconcile = invoice-number-normalized matching vs purchase bills.
- **Payments In/Out UI** (`features/payments/payments_screen.dart` at
  `/payments`, in the secondary nav): cash-in-hand / bank / cheques-to-deposit
  summary, filter chips, search, add-payment bottom sheet (segmented in/out,
  party autocomplete, mode incl. UPI/NEFT/cheque, reference), soft delete.
- **Document recycle bin**: `softDelete/restore/watchDeleted/purge` on sales,
  purchases, payments, expenses repositories (stock reversed on delete,
  re-applied on restore). Recycle bin screen now 5 tabs (Invoices & Docs /
  Purchases / Payments / Parties / Items). Delete wired into sales list rows
  (both variants) + sale detail menu + purchase rows + expenses (was
  hard-delete) + payments.
- **Audit logs**: `AuditRepository` (append-only, rowid tiebreaker), hooks on
  party create/update/delete/restore and all document delete/restore/purge;
  viewer screen at `/settings/audit-log` with entity filter.
- **Period locking**: `PeriodLock` (settings key `books_locked_upto`, firm-
  scoped) + `db.assertDateEditable` enforced in sales.save, purchase.save and
  every softDelete/purge. Settings UI at `/settings/period-lock` (lock through
  a date / unlock; lock+unlock actions are audited).
- **Party ledger surfaced**: statement button in the master-detail header
  (screen + repo + route pre-existed; `/parties/statement/:id`).
- **Fidelity**: `nav_shell_regression_test` needed `ensureVisible` (10 rail
  entries scroll; off-screen taps silently miss); stock-movement ids now use a
  monotonic counter (multi-line invoices posted several movements in the same
  microsecond → UNIQUE PK collision flake); `_PurchaseRow/Table` became
  ConsumerWidget for the delete action.
- Tests: `test/gst_returns_test.dart` (4: B2B JSON shape incl. DD-MM-YYYY +
  camt/samt split, 3B aggregation/netPayable, export-to-disk round-trip with
  mocked path_provider, 2A matched/books_only/portal_only),
  `test/period_lock_audit_test.dart` (3: locked-period save refusal + unlock,
  soft-delete/restore round-trip, audit ordering). Suite 84/84.
- Both artifacts rebuilt 04:59–05:00.

### Deferred (honest gaps; not built this pass)
- **Godown/warehouse management**: schema has no godown dimension; needs
  tables + stock movement source dimension + picker in editors + godown-wise
  stock report. Real feature, sizable.
- **Tally / Vyapar import-export**: needs format specs (Tally XML for vouchers
  & masters; Vyapar CSV/Excel templates) and a mapping layer; recommend
  building against a sample export from the user's Tally first.
- **GSTR-2A live portal sync**: only JSON file import (needs GST API creds &
  OAuth — a server-side job, not client-only).
- **GSTR-9/9C annual return**: yearly aggregation over 12 GSTR-1/3B periods
  plus ITC register; format is large — do after monthly filing is battle-
  tested.
- **Bank feeds / reconciliation statements**: payments carry mode + reference
  + clearance date; a proper bank reconciliation statement needs imports of
  bank statements.

  - Light-mode goldens regenerated after the list-screen revamp (2026-09-26).
  - **`flutter build windows --debug` → SUCCESS (2026-09-27 00:49)** —
    `build/windows/x64/runner/Debug/atria.exe` (1.3 MB). A running `atria.exe` locks the
    link output — kill it first.
  - **`flutter build apk --debug` → SUCCESS (2026-09-27 01:36)** —
    `build/app/outputs/flutter-apk/app-debug.apk` (202 MB, debug keys)
- **User-reported "saved item not showing" / "items blank" FIXED (2026-09-27).**
  REAL root cause (found after the editor-picker fix above): `_itemsGrid` in
  `items_screen.dart` built each grid row as `Row(crossAxisAlignment: stretch)`
  directly under a SliverList — slivers hand rows unbounded height, `stretch`
  forwarded that infinity to the cards → "BoxConstraints forces an infinite
  height" killed the frame the moment ONE item existed. The pane went fully
  blank (no app bar, no stats, no cards; FAB stayed). IntrinsicHeight instead
  caused an INFINITE RELAYOUT LOOP (test hung >2 min mid-frame) — the fix is
  plain `CrossAxisAlignment.start`. Empty-list layout (all goldens, all prior
  tests) never built a row, which is why nothing caught it. Regression:
  `test/items_visibility_regression_test.dart` (seeds firm+item, mounts
  ItemsScreen, asserts chrome + item card + no exception). Tear-down gotcha:
  with a non-empty watched drift query, `db.close()` hangs unless the test
  pumps the fake clock in >=1s steps after container.dispose(). Earlier fix
  same day still applies: sale/purchase editors now subscribe to
  `itemRepo.watchAll()` so items saved after opening appear in the line picker
  (`tool/inspect_items.dart` = read-only live-DB dump used for diagnosis).
  Analyzer clean, 70/70 tests pass, both artifacts rebuilt 01:36 (Windows exe
  mtime stays old on Dart-only changes — check
  `data/flutter_assets/kernel_blob.bin`).
- The full bug list in `.claude/memory/bugs.md` is now closed: every CRITICAL and HIGH
  item is fixed and regression-tested, and the agent claims that were verified false are
  recorded as do-not-fix.
- Partially implemented:
  - Cloud sync is scaffolding only: `sync_queue` is enqueued across all 7 entities but
    never drained. No `Supabase.initialize`, no sync worker. App is 100% offline today.
    The Settings UI now says so honestly (see below).

## Closed this session (2026-09-27, evening batch)

- **Stock Summary blank → same crash class as Items.** The table's
  `Column(crossAxisAlignment: stretch)` sat under a HORIZONTAL scroll view,
  which hands children unbounded width; stretch forwarded infinity into the
  Expanded rows → frame died the moment one tracked item existed
  (`ConstrainedBox(minWidth:)` did NOT bound it — SizedBox(width:) does).
  Regression: `test/stock_screen_regression_test.dart`.
- **Invoice editor party dropdown overflow** ("BOTTOM OVERFLOWED BY 13
  PIXELS"): the closed dropdown view is single-line height but the item
  rendered a two-line Column (name + GSTIN/phone). Dropdown now single-line;
  GSTIN/phone moved to the info panel below (address line before it).
- **Type-ahead item picker** (`shared/widgets/item_type_ahead.dart`,
  RawAutocomplete bound to the line's own TextEditingController): typing
  filters the catalogue; committing an UNKNOWN name fires onCreateItem once
  (case-insensitive de-dupe) and the editor silently saves the item and links
  the line — Vyapar flow, no dialog. Wired in sale + purchase editors; new
  items from the sale side default stockType untracked (services/AMC), from
  purchase side tracked. Tests: `test/item_type_ahead_test.dart` (5).
- **GST inclusive/exclusive toggle** (`shared/widgets/tax_mode_toggle.dart`,
  SegmentedButton "Incl./Excl. GST"): per line in sale + purchase editors
  (seeds from the item's taxMode, drives GstEngine.computeLine), and in the
  item editor which previously hard-coded taxMode:'exclusive' on save.
- **Parties master-detail (desktop ≥ 840px)**, Vyapar reference: party list
  (~340px) left, selected party's header + live transactions right
  (`party_transactions_pane.dart`; `SalesRepository.watchForParty` added).
  Tap selects; right-click/long-press still opens the action sheet. Phones
  keep the old action-sheet list. `/sales/new?party=<id>` preselects the
  customer (new `SaleEditorScreen.presetPartyId`). Test:
  `test/parties_master_detail_test.dart`.
- **Light-mode ghost text FIXED app-wide**: `listTileTheme.titleTextStyle /
  subtitleTextStyle`, `chipTheme.labelStyle` and `tabBarTheme` label styles
  were RAW colorless styles that replace M3 defaults wholesale → titles/
  subtitles rendered unresolved (Settings' Data & backup card was nearly
  invisible). All now carry explicit onSurface / onSurfaceVariant colors.
  Goldens regenerated (02:45) — dashboard/settings captures still hang in
  drift teardown after writing (pre-existing, capture-only).
- Both debug artifacts rebuilt 02:51–02:52 with all of the above.

## Closed this session (2026-09-26)

- **Editor screens revamped to the Vyapar-style layout (user showed the
  Create Sales Invoice reference; refine, don't copy).** New shared chrome:
  `editor_shell.dart` — [EditorShell] action bar (exit ✕ · title · Save & New
  tonal · Save filled, mirroring the reference's top bar; phone keeps Save
  only) + [EditorShellBody] (desktop: form left / STICKY totals panel right,
  phone: stacked + FAB) + lighter [EditorAppBar] for the simple editors;
  `editor_totals.dart` — [EditorTotalsPanel] (breakdown rows, bold Total
  Amount, footer slot) and [EditorLinkSection] (collapsed "Add Notes"-style
  links that expand in place). Rewired: SALE editor (Save & New resets lines/
  notes/charges but keeps the customer; **Mark as fully paid** checkbox in
  the panel records a payment_in for the saved balanceDue on save — same
  plumbing as the detail screen's Record payment; dashed ＋Add Item strip;
  Notes + Discount&Charges became collapsible links; dead gradient
  _TotalsCard deleted), PURCHASE editor (same shell + Save & New keeps
  supplier/inter-state, round-off switch lives in the panel footer, lines
  render straight in the form with a dashed Add-line strip), ITEM / PARTY /
  EXPENSE editors (EditorAppBar with exit + Save identity). Tests:
  `test/editor_shell_test.dart` (shell mounts + link expand/collapse).
  Suite 69/69, analyzer clean.
- **List screens revamped to the shared "transactions" look (user showed a
  Vyapar-style reference and asked for cleaner, not copied).** New toolkit
  `lib/shared/widgets/transaction_list.dart`: `TotalsCard` (one wide card,
  heading amount + divider-separated secondary figures — Total/Received/
  Balance for invoices, Purchases/Payable, Net/Expenses/Income),
  `TransactionSearchField`, `TransactionRow` + `RowActionsButton` (kebab:
  Edit / Convert to invoice / Delete per doc type), `LeadingGlyph`, and a
  desktop-only aligned `TransactionTableHeader`/`TransactionTableRow` grid
  (Date | No. | Party | Status/Ref | Amount | Balance | ⋮) shown at ≥
  Breakpoints.compact. Sales/purchase/expenses all rebuilt on it:
  period pills now shared `Period`/`PeriodPillRow` everywhere (sales dropped
  its private `_PeriodFilter`/`_PeriodPicker`), expenses got a search field
  (vendor/category/mode/amount) and one Net-P&L card instead of three summary
  boxes, swipe-to-delete preserved, sales gained Convert-to-invoice directly
  from list rows for quotes/orders (uses existing `?from=` route).
  Goldens regenerated (`dart_test.yaml` must be temporarily moved aside —
  `exclude_tags: golden` beats a CLI `--tags golden` include). NOTE:
  dashboard/settings captures complete and write their PNGs but their
  post-capture drift teardown now hangs past even 5 minutes; pre-existing
  pathology (goldens are capture-only), sales/parties/items/reports settle.
  Analyzer clean; 67/67 tests pass.
- **Android "The route /onboarding/firm-setup does not exist" — fixed.**
  Root cause: `AtriaApp` swapped `routerConfig` between a splash-only boot
  router (routes: only `/`, NO errorBuilder) and the real router once
  `appInitializationProvider` resolved. On Android the engine re-delivers the
  last route after process death as `platformDispatcher.defaultRouteName`,
  and go_router 14.8.1's `_effectiveInitialLocation` honours that OVER
  `initialLocation` — so the boot router was asked to match
  `/onboarding/firm-setup`, could not, and rendered go_router's DEFAULT error
  page (hence the exact copy the user saw). Windows cold starts always see
  `/`, which is why it never reproduced there. Fix: ONE router for the app's
  whole lifetime — splash is now the `/boot` route inside `appRouterProvider`;
  the redirect parks every location on `/boot` until init resolves (pulsed
  via `refreshListenable` — the router is NEVER rebuilt), remembers the
  parked launch location in a closure variable, and resumes it when the gate
  opens; unknown routes get a branded "Page not found" screen with a
  "Go to dashboard" exit. BONUS bug found by the redirect extraction:
  `resolveOnboardingRedirect` treated `/onboarding/firm-setup` as a dead end
  once a firm existed, so Settings → "Add another business" had ALWAYS
  bounced to the dashboard; firm-setup is now deliberately reachable while
  `/onboarding` stays a dead end. Files: `lib/app.dart` (boot router
  deleted), `lib/core/router/app_router.dart` (`/boot`, `BootRoute`,
  `_RouteNotFound`, launch-location resume),
  `test/router_boot_regression_test.dart` (gate-held executor makes the
  splash observable; relaunch-park-and-resume, error-page recovery,
  firm-setup-reachable). Suite now 67/67, analyzer clean.
- **Vyapar-inspired feature pass (user provided the installed Vyapar Electron
  app as reference; ASAR extracted and feature surface mapped).**
  - **Schema v2** (additive migration): `isDeleted`+`deletedAt` on parties &
    items; `creditNote/DebitNote/DeliveryNote` prefix+sequence on firms.
    CRITICAL FIX: `build_runner`/`drift_dev` were ONLY in
    `dependency_overrides`, so the build plan had zero builders and codegen
    silently wrote 0 outputs — they are now real dev_dependencies.
  - **Returns suite:** Credit Notes (sales returns, restore stock, no
    receivable) and Delivery Notes tabs in Sales; Debit Notes (purchase
    returns) tab in Purchase. Editors are docType-aware (titles, FAB labels,
    DocSequence). Delivery notes are stock-neutral (repo guard).
  - **Recycle bin** (`/settings/recycle-bin`): soft delete for parties &
    items (watchers filter `isDeleted`), restore, delete-forever guarded —
    refuses when documents reference the party or stock history exists.
  - **CSV export** (Settings → Data): parties/items/sales/purchases/expenses
    as RFC-4180 files with UTF-8 BOM, timestamped under
    Documents/atria/exports. `CsvExport.setBaseDirectory` for tests.
  - **Payment reminders** (`/payment-reminders`, dashboard Overdue card
    routes here): overdue invoices with one-tap WhatsApp nudge (pre-filled
    message, days late) and call shortcut; `watchOverdue()` stream.
  - **Barcode labels**: Code128 PDF via the pdf package (item name, price,
    MRP struck through, scannable code from `barcode` or id) from the item
    editor's QR action; saved to Documents/atria/labels.
  - **Bug found by tests:** `nextNumber` minted numbers from the caller's
    potentially-stale firm snapshot — now re-reads the row first.
  - Tests: `test/vyapar_features_test.dart` (8: soft delete/restore,
    deleteForever guards, CN stock restore, delivery-note neutrality,
    independent numbering, CSV escaping + BOM). Suite now 64/64, analyzer
    clean.
- **Missing-features & UX pass (user approved full scope).**
  - Expense/income editing: `ExpenseEditorScreen(editId:)`, route
    `/expenses/edit/:id?type=`, rows now tap-to-edit (swipe still deletes).
    `ExpenseRepository.update` was added to the LIVE class in
    `payment_repository.dart` — the dead duplicate file
    `expense_repository.dart` (second class with the same name!) was deleted.
  - WhatsApp share is real: sale detail launches `wa.me/91<digits>?text=` via
    url_launcher (external app), then still opens the share sheet with the PDF.
  - Items: delete via a danger zone in the editor (confirm dialog; FK errors
    surfaced), duplicate via long-press on a tile → `/items/new?from=<id>`
    pre-filled (name + " (copy)", stock zeroed). `AtriaCard` gained onLongPress.
  - Quotation/order → invoice: `SaleEditorScreen(convertFromId:)`, route
    `/sales/new?type=invoice&from=<id>`, "Convert to invoice" menu item on
    quote/order detail (hidden when already converted/cancelled);
    `SalesRepository.markConverted` flags the source after a successful save.
  - Stock adjustments: `stock_adjustment_dialog.dart` (item picker, counted
    qty, live delta, reason), AppBar tune-icon button + long-press on a table
    row; posts `applyStockEffect(kind:'adjustment')` and invalidates summary.
  - Sales FAB label follows the active tab (New Invoice/Quotation/Order).
  - `SaveShortcut` (Ctrl+S / Cmd+S) wraps all four editors.
  - `PeriodPillRow` + `periodStart`/`periodLabel` in
    `shared/widgets/period_selector.dart` replace three copy-pasted copies
    (purchases, expenses migrated; parties filter pills also got InkWell ripple).
  - Dropped unused deps `device_info_plus` + `image_picker`.
  - Tests: `test/missing_features_test.dart` (6 tests: expense update NULL
    clearing, type separation, markConverted idempotency, conversion flow,
    negative & positive adjustments). Suite now 56/56.
- **All editor buttons dead (sale invoice / add item / parties / purchase /
  expenses).** `AdaptiveNavShell` received the go_router `StatefulNavigationShell`
  from the `StatefulShellRoute.indexedStack` builder but never mounted it — it
  rendered a hand-built list of const list screens instead. Branch navigators
  (which host `/sales/new`, `/items/new`, `/parties/new`, `/purchase/new`,
  `/expenses/new`, every detail route) existed in the router but were never on
  screen, so every editor push changed the URL while rendering nothing. Tab
  switching still worked because the shell faked it with index-based children.
  Fix: the shell now mounts `navigationShell` directly (its `children` param was
  removed; router passes only the shell). Bonus fix found while writing the
  regression test: the 9-destination `NavigationRail` overflowed on short
  windows (its internal Expanded can't sit in a scroll view), so both rails are
  hand-rolled and scrollable. Tests: `test/nav_shell_regression_test.dart`
  (stub-branch shell tests; full-app pumpAndSettle is not usable here — see
  gotcha below).

- **Boot-failure recovery.** The two startup controllers completed their readiness
  futures in a `finally`, so a database that would not open still counted as ready and
  the app crashed on its first query. `initError` + `completeError` now propagate;
  `_AtriaSplash` renders a `_BootFailure` screen with a Retry that invalidates both
  controllers and the gate. Tests: `test/boot_failure_test.dart`.
- **Unsaved-changes guards** on all four editors (sale, purchase, item, party) via the
  new `lib/shared/widgets/unsaved_guard.dart`.
- **Purchase editor totals matched the saved bill**, not the draft: `_LineState.isValid`
  now filters both `_totals` and `_save`.
- **GSTIN validation**: required for registered/composition/sez, optional for overseas;
  new `Validators.gstinStateMismatch` cross-checks the GSTIN's state prefix against the
  selected state; the state dropdown requires a state when a GSTIN is mandatory.
- **Cancelled invoices no longer render "Unpaid"** in the dashboard's recent list.

1. **Cloud sync relabelled, not implemented.** The user chose "relabel as experimental"
   over building the Supabase worker. `settings_screen.dart` `_syncSection()` now carries an
   amber `EXPERIMENTAL` pill and the subtitle "Coming soon — nothing leaves this device yet"
   instead of "Sync books across devices via Supabase". The toggle still persists
   `kSyncEnabled` — leave that wiring intact so the future worker can read it.
2. **Golden suite excluded from CI, not deleted.** The 6 light-mode captures are a manual
   visual audit tool, not a regression gate: their value is the PNG a human eyeballs, and
   their drift-stream teardown takes minutes. Controlled three ways:
   - `@Tags(['golden'])` on `library;` in the test file
   - `exclude_tags: golden` in `dart_test.yaml` (a **string**, not a list)
   - Per-test `Timeout(Duration(minutes: 2))` so a stuck teardown fails fast

## Important gotchas (expensive to rediscover)

- **`@Tags` has `@Target({TargetKind.library})`.** On `main()` it is *silently ignored* —
  the analyzer only catches it if `library;` is also misplaced. The tag must sit above
  `library;`, which must precede all imports.
- **`dart_test.yaml` `exclude_tags` takes a comma-separated string**, not a YAML list.
- **The golden tests' "10-minute timeouts" were self-inflicted.** Running several
  `flutter test` processes concurrently made them contend for `sqlite3.dll` and starve.
  Run serially: kill lingering `dart`/`flutter_tester` first, then one suite at a time.
- **`PackageInfo.fromPlatform()` has no platform handler under `flutter_test`** and hangs
  `SettingsScreen._loadSettings` forever. The golden suite mocks the
  `dev.fluttercommunity.plus/package_info` channel's `getAll` call.
- **Do not pumpAndSettle the full app (AtriaApp) in widget tests.** The
  indexed stack keeps all 9 branch navigators alive, so the reports shimmer
  (`..repeat(reverse: true)`) and hidden spinners never settle, drift stream
  teardown schedules zero-duration timers that trip the pending-timer invariant,
  and SettingsScreen hangs without the package_info mock. That is why the nav
  shell regression tests use stub branch screens in a bare GoRouter instead of
  the real app. EXTENSION (router boot tests): even a *mounted* full shell
  stalls tearDown — drift's teardown timers fire only if the tree is
  unmounted INSIDE the test (`pumpWidget(SizedBox.shrink())` + a couple of
  pumps) before `container.dispose()`/`db.close()`, and an in-memory
  database initializes within one pump, so the splash phase is only
  observable through a gate-held `QueryExecutor` (see
  `test/router_boot_regression_test.dart`). Also: rebuilding the
  ProviderContainer to "re-read" settings races the controllers' in-flight
  `_init` reads — persist rows via the repository BEFORE constructing the
  container instead.
- `flutter.bat` writes its summary to stderr, so PowerShell reports exit 1 even on success.

## Bugs fixed (2026-09-25)

1. **Onboarding buttons did nothing** — `onboardingDoneProvider` was a `FutureProvider`
   whose cached value the router redirect trusted forever, bouncing every `context.go`
   back to `/onboarding`, which made *every* button in the app look dead. Now a
   `StateNotifierProvider<bool>`; redirect logic extracted into testable
   `resolveOnboardingRedirect()`. Regression tests in `test/onboarding_flow_test.dart`.
2. **Opening stock was double-counted** — `ItemRepository.create` seeded `currentStock`
   *and* posted an `opening` movement. Now inserts `currentStock: 0`.
3. **Brand colour green → blue** across theme, logo, PDF, avatar palettes.
4. **Light-mode contrast** — overdue-invoice hero gradient no longer fades to pale pink
   under white text; `outline` strengthened 1.23:1 → ~1.7:1. Verified by eyeballing all 6
   regenerated goldens.## Exact next action

1. Rebuild + run on Windows/Android and eyeball the new editor layout —
   goldens were regenerated before the editor revamp, so re-capture when the
   editor look is signed off (`flutter test --tags golden --update-goldens`
   with `dart_test.yaml` moved aside; see the list-revamp note).
2. Release builds (`--release`): Windows + APK. APK needs a signing config;
   the template signs with debug keys today.
3. `git init` — still not a repository, so none of this work is version-controlled.
4. Optional cleanup: stale repo-root artifacts (`analyze*.txt`, `test_out.txt`,
   `HANDOFF.MD`, `LEFTOFF.MD`, `status.md`, `build_out.txt`).

## Useful commands

```powershell
# Analyzer (clean exit = success)
& "C:\flutter\bin\flutter.bat" analyze

# Tests (goldens excluded by dart_test.yaml)
& "C:\flutter\bin\flutter.bat" test

# Regenerate light-mode goldens (capture-only; slow)
& "C:\flutter\bin\flutter.bat" test --tags golden --update-goldens test/golden_light_mode_test.dart

# Native builds
& "C:\flutter\bin\flutter.bat" build windows --debug
& "C:\flutter\bin\flutter.bat" build apk --debug
```

Before any `flutter test`, stop lingering processes or `sqlite3.dll` locks the build dir:
`Get-Process -Name dart,dartvm,flutter_tester,flutter | Stop-Process -Force`

## Working tree

Not a git repository (`git status` fails). No version control is tracking these changes.

---

# AUDIT PASS COMPLETE — 2026-09-27

All three audits (`audit/01-core-logic-audit.md`, `02-ui-ux-audit.md`, `03-gap-analysis.md`) are CLOSED with resolution notes appended at the end of each file.

## Final state
- Tests: **94/94** (`flutter test --exclude-tags golden --concurrency=1`, EXIT=0; 87 baseline + 7 new regression tests).
- Analyzer: `dart analyze lib test` → No issues found.
- Builds: `build\windows\x64\runner\Release\atria.exe` rebuilt successfully after all fixes.
- Git: **initialized** (first commit `c7b4305`), `.gitignore` + `.github/workflows/ci.yml` added; root litter deleted.
- Pubspec: `qr: ^3.0.2` added (UPI QR).

## Key fixes by area
- Core (01): backup/rewrite, P&L, credit-note stock, payment recompute, schema v4 (sequenceFy + unique doc indexes), GSTR-1/3B, guarded nextNumber.
- **Deadlock fix:** nextNumber's optimistic guard compared post-reset values → infinite loop on every fresh firm (this was the "tests time out" mystery). Guard now uses stored values; regression test with 10s timeout in vyapar_features_test.dart.
- UI (02): swipe-delete onDismissed, purchase ?type=, save guards everywhere, dashboard error+retry, tab listener + debounced cached streams, GST dropdown in sale editor, qty validator, UnsavedGuard/SaveShortcut on expense+firm settings, period-lock try/catch+confirm, supabase obscure+autosave, stock adjust error text, M/L cluster all done.
- Gaps (03): UPI QR on invoice PDF, logo picker + PDF logo, credit-limit advisory banner, DN→invoice, interest text neutralized, /more documented, git+CI.

## Deferred (recorded in 03 resolution notes)
Release signing, e-invoice/e-way, cloud backup, i18n, app lock, recurring invoices, TDS/TCS, POS, godowns/batch, launcher-icon branding (needs flutter_launcher_icons run), dark goldens, integration tests, sync drain.

## Gotchas learned
- Background long commands: git-bash `&` still blocks; use PowerShell `Start-Process ... -RedirectStandardOutput` (returns immediately, file grows).
- Money.parse throws FormatException — always tryParse first in UI paths.
- drift watch `.first` inside widget-test fake-async hangs (assert via getById instead).
- Negative stock is allowed by design; do not add throws.
