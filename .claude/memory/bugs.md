# Bugs

## Status

All items below were FIXED. This file is kept as the audit trail of what was
wrong and why each fix took the shape it did.

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
