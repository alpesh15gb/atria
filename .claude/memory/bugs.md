# Bugs

## Status

All items below were FIXED. This file is kept as the audit trail of what was
wrong and why each fix took the shape it did.

**Still open (2026-10-03):** one MEDIUM — editing a payment keeps
`chequeStatus` when the mode changes (`payments_screen.dart` ~845–867:
cheque→cash leaves `pending`, cash→cheque leaves null). See `.claude/TODO.md`.

**Exception:** the "2026-10-02" section below was fixed and then, once the SDK
was restored later that same day, **compiled and test-run** — `dart analyze
lib/ test/` clean, 393 tests passing. The two corrections that the compiler
caught are recorded inline there.

## 2026-10-03 — go-live verification pass (4 real bugs, all fixed + tested)

Suite at the end of this pass: **439 passed, 1 skipped, 0 failed**;
`flutter analyze lib/ test/` clean.

Every test below was verified to catch its bug by **reverting the fix in place,
running, and confirming the exact failure** — then restoring. The four reverts
produced four distinct failures, which is the only evidence a regression test
is worth anything.

34. **The account-ledger "Balance" column was not a running balance.**
    `ledger_reports_screen._LedgerMovementRow` received the same
    `ledger.opening` for every row and printed `opening + row.amount`, so a
    ledger with a 100 opening and three 100 movements read 200/300/400 while
    the Closing line printed 400 — a column of *per-row* figures that
    contradicted the closing total printed directly beneath it, which is the
    first thing an accountant checks a ledger for.
    Fix: `LedgerEntryRow` gained a required `balance` (the account's balance
    *after* that movement) and `accountLedger` accumulates a separate `running`
    variable. **`opening` and `running` must stay separate** — `AccountLedger.closing`
    folds `opening` + the rows, so mutating `opening` as the loop advances
    double-counts. `opening` is also what the caller prints as the period's
    opening, so it has to stop at the first in-range row.
    Test: `test/ledger_test.dart` — rows 1180 / 780, and
    `rows.last.balance == closing`. Reverting produced
    "Expected: <780> Actual: <-400.0>".

35. **Indian-grouped money strings were silently dropped by `double.tryParse`.**
    `journal_editor_screen._Line.debitValue`/`creditValue` and
    `chart_of_accounts_screen`'s opening-balance parse used `double.tryParse`,
    which returns `null` for the grouping comma in "1,00,000". The fallback was
    0, so a voucher line saved with no amount and no error, and an account
    opened with a zero balance. A voucher that silently drops its amount is how
    the books stop balancing.
    Fix: `Money.tryParse` in all three places (`payments_screen` already used it
    and showed an error — the model to copy).
    Test: `test/journal_grouped_amount_test.dart` — type "1,00,000", assert
    "Total debit" renders the lakh. Had to wait for the editor's spinner (the
    chart must resolve before the line fields exist) and then drag the totals
    card into view (it is below the editor ListView's fold). Reverting produced
    "Actual: '₹0.00'".

36. **Party opening balances never reached the books** — the reconciliation gap.
    `PartyRepository.outstandingFor` and `ReportRepository.partyStatement` both
    count `party.openingBalance`, but nothing in `lib/` ever posted it to
    account 1100/2000 (only `_postSale`, `_postPurchase` and `_postPayment`
    write those codes). So Sundry Debtors disagreed with the sum of the customer
    statements by exactly the openings — on the first day and every day after,
    over a trial balance that still footed.
    Fix: `_book` derives the posting from the party row — Dr/Cr Debtors vs
    Creditors against Capital — rather than writing a journal voucher at
    party-save time. **Derived, not written, because a voucher would go stale
    the moment a party's opening is edited and would stay on the books after
    the party is purged** (purge refuses when documents reference the party, so
    the voucher would be orphaned but still posted). The party row is the source
    of truth; the books are a view of it — the same reason everything else in
    `_book` is derived.
    Test: `test/reconciliation_test.dart` — customer: 5,000 Dr opening + 10,000
    invoice → Debtors closing 15,000 AND `trialBalance.isBalanced` (an opening
    that posts one side would foot only because two errors cancelled);
    supplier: 8,000 Cr opening → Creditors closing −8,000 and
    `outstandingFor` −8,000. Reverting produced 10,000 and 0.0.

37. **The Payments screen's "Cash in hand" card disagreed with the ledger.**
    `_summarize` summed the payment rows alone, while `_postExpense` also posts
    to Cash/Bank — a ₹3,000 cash expense left the card ₹3,000 richer than the
    Cash account, forever. The card and the account are the same name to a
    user, so they have to be the same number.
    Fix: new `cashBankBalancesProvider` in `providers.dart` reads
    `trialBalance(asOf: now)` for codes 1000/1010/1020; new
    `LedgerRepository.watchBookMovement` ticks it. Written out per-table rather
    than looped, because the seven tables are different generated types and a
    loop loses the per-table type the `where((t) => t.firmId...)` needs.
    `CashBankSummary`, `_summarize` and `_cashBankProvider` deleted.
    **The cheques figure comes from the same source now too** — the ledger's
    Cheques in Hand account is what the books say; the payment-row derivation
    was the duplicate.
    Test: `test/payments_ledger_agreement_test.dart`. Reverting to the
    payment-row sum produced "Found 0 widgets with text '₹7,000.00'" (the card
    rendered ₹10,000.00 instead).

### Test-writing lessons from this pass (expensive to rediscover)

- **Assert on the rendered figure, not the widget tree.** The payments card
  stacks its icon above the text below the compact breakpoint, so the `Row`
  that carries "Cash in hand" is not the `Row` (or Column) that carries the
  figure — every ancestor/descendant finder I wrote matched the wrong slot.
  `find.text('₹7,000.00')` (with `findsWidgets`) is both simpler and immune to
  layout changes.
- **A provider that re-derives from an async report needs a pump-until loop.**
  `pumpAndSettle` can return before the stream ticks; the derived trial balance
  is a fresh `Future` per tick. Loop on the expected text for N pumps instead.
- **Verify by reverting, every time.** My first attempt at the reconciliation
  test asserted on a widget-tree path that happened to read ₹0.00 for an
  unrelated reason (the provider had not emitted yet) — it would have "passed"
  for the wrong cause. Reverting is what distinguishes a test from a formality.
- **Prove the provider, not the widget, when a test is stuck.** A throwaway
  `container.listen(...)` + `print` on the provider's value settled the
  payments case in one run: the provider was right, the finder was wrong.

## 2026-10-02 (UNVERIFIED — no Flutter SDK on the machine)

33. **`gst_engine.dart` invoice discount apportionment moved whole rupees.**
    `computeDocument` scaled every line by
    `ratio = Money.div(invoiceDiscount, preDiscountTaxable)`, and `Money.div`
    rounds a *non-terminating* quotient to 2 dp. So ₹10 off a single ₹300 line
    used `0.03` instead of `1/30` → `lineTaxable = 300 × 0.97 = 291.00` instead
    of `290.00` (and 18% tax came out at 52.38 instead of 52.20); ₹1 off ₹300
    used `0.00` → nothing was deducted while the PDF still printed
    "Discount ₹1.00"; ₹1 off ₹150 used `0.01` → 148.50, over-deducting ₹0.50.
    Percent discounts were unaffected (`pct/100` always terminates) — only the
    *amount* path was broken.
    Fix: `_apportionInvoiceDiscount` hands out whole paisa by largest
    fractional remainder, so `Σ lineTaxable == preDiscountTaxable −
    invoiceDiscount` exactly whatever the ratio. Also added
    `invoiceDiscount = Money.round2(invoiceDiscount)` before apportioning, so a
    percent discount that does not land on a paisa (7.5% of ₹299.97 =
    22.49775) settles to paisa first — otherwise it would be truncated by the
    paisa math and the total would not reconcile.
    Regression test: `test/invoice_discount_apportionment_test.dart` — **7/7
    passing.** The percent path's stored `taxableValue` does move by a
    sub-rupee (277.47225 → 277.47) but `money_precision_test`'s 'awkward rates'
    case still passes, so nothing pinned it.
    Corollary (recorded, not fixed): `money.dart` `div`/`over100` only round a
    *non-terminating* quotient — `div(1, 8)` returns `0.125`, not `0.13`, so
    their "rounded HALF_UP to scale" docstrings over-promise. Harmless: every
    display path re-rounds. Note the audit agent that reported this also claimed
    `percent` leaks scale 4; that half is **wrong**, `percent` wraps its result
    in `round2`.
    Two compile errors the analyzer caught once the SDK was back, both in the
    GSTIN-uniqueness check in `party_editor_screen.dart` (not in this fix):
    the file imported drift as `show Value`, so the `&` it uses — drift's
    `BooleanExpressionOperators` extension on `Expression<bool>` — was out of
    scope; and `repository!.firmId` was a redundant `!` on a value already
    promoted non-nullable by a `!= null` guard. Lesson: `show`-restricted
    imports hide extension operators that the mirrored repository code depends
    on, and only the compiler sees that.

## CRITICAL (data corruption / money wrong)

1. **`formatters.dart` `indianGroup` mis-grouped every amount >= 1000.**
   `1234 -> "12,34"` (should be `1,234`). Fixed: rightmost group of 3, then
   groups of 2, with the first comma firing after 3 digits.
2. **`gst_engine.dart` invoice discount was counted twice.** The second loop
   added `discountForLine` into `itemDiscountTotal`, and PDF/detail add the
   item and invoice discount columns, so a ₹100 invoice discount printed ₹200.
   Removed the accumulation; the unused local went with it.
3. **Per-line tax columns were never persisted.** `SalesLineDraft.toCompanion`
   and `PurchaseLineDraft.toCompanion` left `taxableValue/cgst/sgst/igst/
   cessAmount/total` at their column DEFAULT of 0. Both now take the
   `ComputedLine` and write the resolved figures, so the detail screen and the
   PDF show real line tax instead of ₹0.00.
4. **Editing a purchase bill threw `UNIQUE constraint failed`.** `save()`
   re-inserted an existing row. Now `getById` detects the edit, reverses stock,
   deletes the old line rows, and `insertOnConflictUpdate`s the header.
5. **Editing a sales invoice deducted stock twice and orphaned payments.**
   The editor cancelled and re-inserted under a new id. `save()` now rewrites
   in place; the reversal keeps payments (they key off `invoiceId`).
6. **`sales_repository.dart` stock reversal for an edit.** Added
   `reverseStockForSource`, which posts the equal-and-opposite of every
   movement a source recorded rather than deleting rows — the ledger stays
   append-only and auditable. `purchase_repository.dart` has the same helper.
   A monotonic `_movementSeq` keeps two movements posted in the same
   millisecond from colliding on the PK.
7. **Opening stock was double-counted.** `ItemRepository.create` seeded
   `currentStock` AND posted an `opening` movement. Now inserts
   `currentStock: 0`.

## HIGH

8. **`report_repository` party statement ignored the date range for payments**
   and used the party's ORIGINAL opening instead of a carried-forward one.
   Both fixed; payments now honour `from`/`to`, and a period statement sums
   prior sales/purchases/payments into an opening balance.
9. **`money_text` negative amounts lost the minus sign** (passed the magnitude
   AND `signMode: never`). Fixed: the `never` branch passes the amount
   un-negated and relies on the formatter's own sign.
10. **"Add Income" FAB created an expense.** `/expenses/new?type=...` is now
    threaded from both the FAB and the empty state.
11. **Purchase editor footer totals included lines the save silently drops.**
    `_totals` summed all `_lines` while `_save` kept only qty > 0 with a name.
    Added `_LineState.isValid` and filtered both paths through it, so the
    footer the user reads always describes the bill that will be written.
12. **`purchase_repository.save()` wiped recorded payments** (hard-wrote
    `unpaid` / `paidAmount: 0`). Now preserves both and derives status.
13. **`Formatters.money` did not always show 2 decimals** — `Decimal.round`
    returns `this` when scale <= n. Fixed via `toStringAsFixed`.
14. **`Money.div`/`divN` truncated** (`Rational.toDecimal` default), losing a
    paisa. Fixed with `toBigInt: (v) => v.round()`.
15. **Onboarding-done-but-no-firm** went to an empty dashboard. Verified
    ALREADY CORRECT via `test/onboarding_flow_test.dart`; not changed.
16. **No recovery if the DB fails to open.** Both startup controllers completed
    their readiness futures in a `finally`, so an unreadable database counted
    as "ready" and the app crashed on its first real query. Now: `_init`
    records `initError` and `completeError`s; `appInitializationProvider`
    rejects; `_AtriaSplash` renders `_BootFailure` with a Retry that
    invalidates both controllers and the gate. Regression tests in
    `test/boot_failure_test.dart` using a `QueryExecutor` whose every
    statement throws — closing a real database does NOT reproduce this, drift
    tolerates queries after close, so a failing executor is required.
17. **Dashboard KPIs never refreshed.** `WidgetsBindingObserver` invalidates on
    `resumed`, plus a `RefreshIndicator` and `_refresh()`.
18. **Dashboard trend bars overflowed** their fixed-height box. Extracted
    `_TrendBars.height` / `barHeight = height - 24`.
19. **Cancelled invoices showed "Unpaid" in Recent invoices.** `markCancelled`
    leaves `paymentStatus` untouched. `_InvoiceTile` now shows
    `StatusChip.doc('cancelled')` when `status == 'cancelled'`.
20. **"Add new supplier" sentinel stayed selected** and validated, saving a
    bill with a null party. Fixed; the created id is re-fetched and selected.
21. **No unsaved-changes guard** on the sale/purchase/item/party editors — a
    back swipe discarded everything silently. Added `lib/shared/widgets/
    unsaved_guard.dart` (`PopScope` + confirm dialog) wired into all four.
    Dirty tracking: `TextEditingController` listeners (which fire on user
    input only, so prefilling an existing row does NOT trip the guard) plus
    explicit flags in dropdown/segment/date handlers. Each `_save` clears the
    flag before its own `context.pop()`, or the guard would ask whether to
    discard the thing just saved.
22. **Item editor Save was enabled while loading** -> null `_formKey`
    currentState crash. Guarded.
23. **Stock screen totals row contradicted visible rows** under the low-stock
    filter. Totals now run on the filtered set.
24. **Parties clear-search did not cancel the debounce** -> the cleared query
    re-applied itself 220 ms later.
25. **"Party deleted" snackbar could never appear** — the sheet context was
    popped before the await. Navigator/messenger captured above the gap.
26. **A "Registered" party could be saved with no GSTIN**, and the GSTIN's
    state prefix was never checked against the selected state. Added
    `_gstinRequired` (registered/composition/sez; overseas stays optional),
    `Validators.gstinStateMismatch`, and the state dropdown now requires a
    state when a GSTIN is mandatory. Regression tests in
    `test/formatting_test.dart`.
27. **`_PartyRow` reused a stale outstanding Future** across row recycling.
    Keyed on the party id.
30. **Party type never preselected from context.** `/parties/new?type=supplier`
    and the editor's `initialType`; the created id is returned via `pop`.

## Additional fixes (sweep pass, 2026-09-26)

31. **Over-payments were silently swallowed.** `sale_detail_screen._record`
    passed the typed amount straight through; `applyPayment` clamps
    `balanceDue` at zero but keeps the excess in `paidAmount`, so a ₹12,000
    payment on a ₹10,000 invoice marked it "paid" and the customer's ₹2,000
    change was nowhere. The screen now caps the amount at the balance due and
    says what it recorded, formats the confirmation in Indian-grouped money
    (it used to print a raw `10000.0`), and the "repos are null" early return
    now surfaces a snackbar instead of doing nothing. Pinned by
    `test/payment_test.dart`.
32. **`_load()` read `ref` before its `mounted` guard.** A pop during an
    in-flight `markCancelled` would call `ref.read` on a disposed
    `ConsumerState` and throw. Guarded at the top, and `_confirmCancel`
    re-checks `mounted` before reloading.

## Verified clean (do not re-litigate)

- `backup_restore_screen` restore path: `mounted` checked at every gap,
  `ScaffoldMessenger.maybeOf` captured before the awaits.
- `firm_setup_screen`: messenger captured pre-await, `mounted` before
  `context.go`.
- `reports_screen` custom period: an inverted From/To is already swapped
  before the range is built.

## Known limitations (documented intent, do NOT "fix")


- **`markCancelled` does not reverse stock.** The confirm dialog says the
  document is voided; the ledger is append-only by design.
- **Stock is not clamped at zero.** Clamping would corrupt the running
  balance; a negative is a real signal that a sale preceded its purchase.
- **`units.symbolOf` falls back to the raw id.** There is no custom-unit
  feature in the app, so the branch is unreachable in practice.
- **`report_repository.netProfit` does not double-subtract COGS** — verified.
- **`party_repository.outstandingFor` does honour payments** — verified.

## FALSE POSITIVES (agent claims, verified WRONG)

- **`report_repository.dart:479` netProfit double-subtracts COGS.** WRONG.
  `totalExpenses` is folded from `expenseByCat` only; `purchaseTaxable` is
  separate. `netProfit = (sales - purchases) + otherIncome - otherExpenses`.
- **`party_repository.dart:145-173` `outstandingFor` ignores payments.**
  WRONG. It sums `balanceDue`, which `applyPayment` already reduces.

## Test-suite gotchas (expensive to rediscover)

- Closing a real drift database does NOT make subsequent queries throw — drift
  tolerates them. To simulate an unreadable book in a test, subclass
  `QueryExecutor` and throw from every method (see `_FailingExecutor` in
  `test/boot_failure_test.dart`). Note `QueryExecutor` has no const
  constructor, and `package:drift/drift.dart` exports `isNull`, which collides
  with `package:matcher` — `import 'package:drift/drift.dart' hide isNull;`.
- `StateNotifier._init` early-returns inside its `try`: if you move
  `_ready.complete()` out of a `finally`, those returns silently hang the
  boot gate. Always guard with `if (!_ready.isCompleted)`.
- `SalesInvoiceItems` PK is `{id}` alone, so line ids must be globally unique
  across invoices — the app avoids this by always generating UUIDs.
- `PackageInfo.fromPlatform()` hangs under `flutter_test`; the golden suite
  mocks the `dev.fluttercommunity.plus/package_info` channel.

## Build gotchas (expensive to rediscover)

- **A background `flutter build` can hand back a task id from a previous
  session.** This session, `run_in_background` returned the same id as a
  build that had completed pre-compaction, so the output file held the OLD
  log and the "completed" notification looked like a fresh success. The
  `atria.exe` mtime was 29 hours old. **Verify a build by artifact mtime,
  never by exit code alone.** Foreground builds do not have this hazard.
- **The Windows `atria.exe` mtime does not move when only Dart changes.**
  In debug it is a thin C++ runner; the compiled Dart is
  `build/windows/x64/runner/Debug/data/flutter_assets/kernel_blob.bin`
  (~103 MB). Check THAT file's mtime, not the exe's.
- `flutter build apk --debug` warns that `device_info_plus`,
  `package_info_plus` and `share_plus` still apply the Kotlin Gradle Plugin.
  Harmless today; a future Flutter will refuse to build until they migrate
  to built-in Kotlin.

## 2026-10-03 — widget tests that select an active firm hang at `db.close()`

`ActiveFirmController.select()` installs `_watchFirmExistence`, a drift
`watchById` stream (added 2026-10-02 for the tombstone-healing fix). Any widget
test that calls `activeFirmIdProvider.notifier).select(...)` and then lets a
file-level `tearDown(() => db.close())` close the database **hangs until its
timeout**, with no assertion failure and (because `flutter test` buffers stdout)
an empty log.

Why: drift's stream teardown timers only fire when the fake-async clock is
pumped. The test body has finished, so nothing pumps, and `close()` waits on
the stream's teardown forever.

**Every widget test that selects a firm must end with the pump-down**, not a
bare `container.dispose()`:

```dart
for (var i = 0; i < 8; i++) {
  await tester.pump(const Duration(milliseconds: 50));
}
await tester.pumpWidget(const SizedBox.shrink());
container.dispose();
for (var i = 0; i < 6; i++) {
  await tester.pump(const Duration(seconds: 1));
}
```

This is why `service_stock_test` (two tests) and one `router_boot_regression`
test silently started timing out after the healing fix landed: they passed
before because the controller held no watch. A local helper
(`_disposeWithMountedDrift`) now wraps it in `service_stock_test`.

Diagnostic dead-ends worth remembering: the three timeouts looked identical in
a parallel run, a two-file run, and a `--concurrency=1` run, so "concurrency"
was a wrong first hypothesis — it is the teardown, and running a file alone is
what isolates it. Also: a name printed at the bottom of a `flutter test` log
without `[E]` is just the test that was running when the run ended, not a
failure — read the "Failing tests:" block instead.

**The order matters: `container.dispose()` must come BEFORE the 1s pumps.** The
drift teardown timer only starts when the subscription is cancelled, so pumping
before disposing advances nothing and `db.close()` still hangs. An instrumented
copy of the router test showed the entire body pass and then block on `close()`
for exactly this reason. (The `service_stock_test` helper already had it right;
my first fix of the router test did not.)

**To find a hang like this:** copy the test to a throwaway file, add
`debugPrint` at every `await`, run it with `--plain-name`, and read the output
file only after the process exits — `flutter test` buffers stdout, so a hung
test's log looks empty until then. Delete the copy afterwards.

## 2026-10-03 — two ledger bugs found by audit agents, both verified live

Both were found by read-only review agents and confirmed against source before
any change. Both were genuine; a third agent finding was not — see below.

1. **A bounced cheque stayed in the books.** `ledger_repository._book` selected
   payments with no `chequeStatus` filter, so a returned cheque kept posting
   `Dr Cheques in hand` while `payment_repository` had already released the
   invoice it settled. The app's contract is stated in three agreeing places —
   `payment_repository:302`, `payments_screen:351`,
   `markChequeBounced`'s doc — and the ledger was the one violating it.
   Fixed with `(chequeStatus.isNull() | chequeStatus.equals('bounced').not())`.
   **Drift 2.31 has no `isDistinctFrom`**; the codebase's null-safe idiom is at
   `party_repository:306`. Beware: plain `not(equals('bounced'))` on a null
   column is SQL-null, which drops every cash/bank payment from the books
   silently — the failure mode this fix is about, inverted.

2. **Archiving an account erased its opening balance.** `_book` loaded active
   accounts only, so a retired account's opening vanished with no contra
   (trial balance out by exactly that amount) and its journal lines were
   re-posted to Suspense. `setAccountActive`'s own doc says the account "stays
   in the chart for the entries that reference it", and the delete dialog
   explicitly directs users with history to archive rather than delete. Fixed
   by loading `allAccounts(includeInactive: true)` in `_book`.

**An agent finding that was NOT a bug, and the check that caught it:** the GST
agent reported two HIGH findings about exports (with-payment exports taxed but
unreported in GSTR-3B 3.1(b); GSTR-1 dropping exports from every section). A
grep for who *sets* `isExport` found nobody — not the sale editor, not the
demo seeder, not the importer — and `exportType` is persisted but read
nowhere. So both findings live in unreachable code; the real gap is that
exports/SEZ supplies cannot be recorded at all. Lesson that held for the third
session running: **before fixing a reported bug, check the path is reachable**
— grep for who *writes* the flag, not just who reads it.

## 2026-10-03 — the phone/widescreen alignment pass

Thirteen UI defects, all reproduced by pumping the real screen at a real
viewport (`test/phone_width_smoke_test.dart`, `test/statement_ledger_phone_test.dart`)
rather than by reading code. Two lessons drove the method, and both are worth
more than any individual fix:

- **The test binding's fallback font is far wider than the app's bundled
  Inter.** A 41px dashboard "overflow" was entirely a font artefact and
  vanished once `FontLoader(AppTypography.family)` was populated from
  `rootBundle.load('assets/fonts/Inter[opsz,wght].ttf')` (needs
  `package:flutter/services.dart`). **Any width-based assertion in a widget
  test is meaningless without the real font.**
- **`tester.takeException()` alone does not prove a screen is laid out
  correctly, and neither does it prove a fix is guarded.** Money strings are
  single unbreakable words: a too-narrow `Text` *paints past its box* without
  throwing, so the framework never complains. The statement ledger's running
  balance had to be guarded by asserting on the rendered text (`find.text('₹1
  Cr')`), and the widescreen cap by *measuring* (`tester.getRect(...).width <
  1500`). A test that passes with the fix reverted is not a regression test —
  verify each one by reverting in place.

Three specific defects worth remembering:

1. **A chip cannot hold a document number.** The ledger rows rendered
   `StatusChip(label: line.reference)`, but `reference` is *always* the same
   number already embedded in `particulars` ("Sales Invoice INV/2026/001" →
   chip "INV/2026/001"). A 13-character token does not fit a 91dp column, so
   the chip's inner `Row` overflowed 1.6–2.8px. Removed as redundant rather
   than ellipsised — the number was already on the line above it. `StatusChip`
   itself was left alone: `Row(mainAxisSize: min)` chips are not expected to
   shrink, and every other caller passes short fixed labels.
2. **The framework reports only the FIRST exception per test.** To enumerate
   every overflow, install a temporary `FlutterError.onError` collector in a
   throwaway probe test and read `FlutterErrorDetails.toString()` — the stack
   is null for layout errors, but the diagnostics name the offending widget
   (`Row:file:///.../status_chip.dart:88:14`). Note the harness asserts you
   restore `FlutterError.onError` before any `expect`, so a probe is for
   diagnosis only, then delete it.
3. **`WindowSizeX.contentMaxWidth` was dead code** — defined, consumed by zero
   screens. `AtriaListPage` now uses it, and a new `AtriaContentWidth` widget
   carries the repeated `LayoutBuilder`+`Center`+`ConstrainedBox` idiom for
   non-list screens. Convention that emerged: **720** for settings/form columns
   (`settings_screen` and `backup_restore` already used it), **980** for the
   two statement ledgers (unified — they were 900 and 980 on screens one tap
   apart), **1280** for document lists, and editors own their own
   `maxFormWidth`/`maxContentWidth` because a maximised window is deliberately
   spent on the line grid. `firm_settings_screen` is full-width on purpose
   (fields group two-up); do not "fix" it.
4. **A widescreen cap test needs real data or it passes for the wrong reason.**
   `test/settings_widescreen_test.dart` first asserted on an empty screen's
   width and measured 340px — the `EmptyState`'s own `SingleChildScrollView`
   (itself a fix from this pass), not the list. Seed a printer profile and an
   overdue invoice first, then measure `find.byType(Scrollable).first`, which
   is the screen's own list. The same trap caught a real bug: I capped
   `PrinterEditorScreen` when the routed screen is `PrinterSettingsScreen` —
   two classes in one file, and only a test that pumped the routed one would
   have noticed. **When a file holds two screen classes, check which one the
   router builds before editing.**


