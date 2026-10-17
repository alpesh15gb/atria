# Bugs found — 11 October 2026

Read-only independent audit of the Apex Books working tree, Windows and Android. At the time of this original audit, all findings below were **open**; no application fixes were made during the audit.

**Repair follow-up, 11 October 2026:** all 18 findings have been addressed in the subsequent authorized repair pass. See [repairs and verification](docs/audit-repairs-2026-10-11.md) and [release artifacts](dist/RELEASE-2026-10-11.md). The original observations below are retained as historical evidence.

## Result

**18 confirmed findings: 13 high priority (P1), 5 medium priority (P2).** No critical/P0 classification was assigned. Shared repository defects affect both platforms even when the clearest visible symptom is on Windows.

The existing suite passed **1,179 tests**, and `flutter analyze --no-pub lib test` reported **no issues**. Those results do not cover the failures reproduced below. I wrote and ran fresh, isolated audit probes: **15 logic probes and 6 widget probes passed by asserting the observed faulty behavior**. These are evidence of bugs, not evidence that the app is fixed.

### How this was checked

- Reviewed current implementation directly, including routing, form guards, payments, expenses, inventory, bank accounts, accounting summaries, sync encoding/application, period locks, roles and backup restore. Previous audit conclusions were not used as proof.
- Opened the existing Windows release app with the computer-use skill and visually inspected the dashboard, invoice list and invoice editor. Navigated without saving, deleting, importing or changing settings in the real books.
- Ran independent Flutter widget checks with Android and Windows platform overrides, real bundled fonts/icons and isolated in-memory business data. Swept 18 routes per platform: dashboard, sales, purchases, items, parties, payments, expenses, reports, stock, settings, bank accounts, and seven editor/counter routes.
- Stress conditions: Android 360 × 640; Windows 1024 × 600; interface scale 150% plus OS text scale 150%. Form navigation checks also used Android 412 × 892 and Windows 1280 × 800 at normal scale. Keyboard check used a 300-logical-pixel bottom inset on Android 360 × 640 at normal scale.
- Compared SHA-256 hashes for **598 existing files** under `lib`, `test`, `android`, `windows` and `server`: **zero changes** during the audit. Audit-only scripts, logs and screenshots are under `build/import-audit/readonly-2026-10-11/`.

Base Git HEAD: `4deb2ea`, with the existing uncommitted working tree included. Audit date/time zone: 2026-10-11, Asia/Calcutta. The inspected Windows Dart payload was built at 03:09 on this date; current-source widget and repository checks are independent of that binary.

## Findings

| ID | Priority | Platforms | Confirmed problem |
|---|---|---|---|
| B01 | P1 | Both / sync | Recycle-bin deletion becomes permanent on the receiving device; restoring loses invoice lines |
| B02 | P1 | Both / sync | Synced stock movements do not update displayed stock quantities |
| B03 | P1 | Both / sync | Editing a linked payment leaves the other device's invoice settlement stale |
| B04 | P1 | Both | Saving an already-open item editor overwrites intervening stock changes |
| B05 | P1 | Both | Payment date edits bypass the original locked period |
| B06 | P1 | Both | Expense date edits bypass the original locked period |
| B07 | P1 | Both | A read-only accountant can post a manual stock adjustment |
| B08 | P1 | Both UI | Typing item/party details alone does not activate the unsaved-changes guard |
| B09 | P1 | Android reproduced; shared POS code | Back silently destroys an active POS cart |
| B10 | P1 | Both UI/accounting | Negative bank opening balances become positive |
| B11 | P1 | Windows dashboard; shared summary logic | Cash in hand ignores cash expenses |
| B12 | P1 | Windows dashboard; shared summary logic | To receive ignores opening balances and unallocated receipts |
| B13 | P1 | Both / reports | Bank opening balances are absent from the accounting ledger |
| B14 | P2 | Both / restore | A backup containing loan transactions cannot restore with production foreign keys |
| B15 | P2 | Both UI/reports | Expense/income lists silently cap rows and understate displayed totals |
| B16 | P2 | Both / sync | Permanent document/payment/expense purges do not enqueue a purge event |
| B17 | P2 | Android UI | POS footer becomes unusable with supported zoom and larger text |
| B18 | P2 | Android UI | Stock-adjustment dialog overflows with the keyboard open |

### B01 — Recycle-bin sync permanently deletes data

**Reproduction:** Sync an invoice to another device. Move it to the recycle bin on the first device, sync, then restore it and sync again.

**Observed:** The receiving device hard-deletes the row even though the deletion payload contains the soft-deleted document. With foreign keys enabled, invoice lines cascade-delete. The restore queues the parent but not its line items. The independent probe ends with a restored invoice **grand total ₹100, line count 0**. A separate payment probe confirms that a recycle-bin payment disappears entirely on pull.

**Expected:** Binning should preserve a recoverable record and its lines on every device; restoration should restore the complete document.

**Cause:** `PullApplier` treats every `operation == 'delete'` as a hard-delete without inspecting the payload. Sales, purchase, payment and expense soft-delete writers send that same operation. The sync encoder preserves the operation and includes the existing row payload, so it does not correct the mismatch.

**Locations:** [pull_applier.dart:164](lib/core/sync/pull_applier.dart#L164), [sales_repository.dart:911](lib/core/database/repositories/sales_repository.dart#L911), [sales_repository.dart:991](lib/core/database/repositories/sales_repository.dart#L991), [payment_repository.dart:341](lib/core/database/repositories/payment_repository.dart#L341), [sales_invoices.dart:106](lib/core/database/tables/sales_invoices.dart#L106), [sync_engine.dart:971](lib/core/sync/sync_engine.dart#L971).

**Repair direction:** Separate soft deletion from permanent tombstones across producers and consumers. Include a regression for delete → sync → restore → sync with foreign keys enabled and line-count/PDF parity.

### B02 — Inventory movement sync leaves the displayed count stale

**Reproduction:** Start from synchronized stock 10. Sell or adjust out 2 on one device, then deliver its newly queued movement to the other device.

**Observed:** The writer queues `stock_movements` only. Its local item count becomes 8. On the receiver, the synchronized movement sum is **8**, but `items.currentStock` remains **10**. The Items screen and cached-stock summaries therefore disagree with the stock ledger. This occurs without simultaneous edits on two devices.

**Expected:** The receiving device should show 8 consistently in Items, low-stock calculations and stock summaries.

**Cause:** `_recordMovement` rewrites the item locally without queuing an item update. Pull applies the movement but rebuilds only bank balances, not stock balances.

**Locations:** [item_repository.dart:323](lib/core/database/repositories/item_repository.dart#L323), [item_repository.dart:332](lib/core/database/repositories/item_repository.dart#L332), [pull_applier.dart:144](lib/core/sync/pull_applier.dart#L144), [report_repository.dart:1235](lib/core/database/repositories/report_repository.dart#L1235).

**Repair direction:** Derive stock caches from the complete movement ledger after applying changes. Sending last-write-wins item totals alone would still lose concurrent sales.

### B03 — Linked payment edits do not synchronize invoice settlement

**Reproduction:** Fully pay a ₹100 invoice, synchronize it, then edit its linked receipt down to ₹40 and synchronize.

**Observed:** The origin recomputes invoice due as **₹60** but queues only the payment. The receiver gets the ₹40 receipt and retains invoice due **₹0**, still marked paid. The probe applied exactly the entity the real update queued. The same recomputation helper is also used by payment delete, restore and cheque lifecycle paths.

**Expected:** Both devices should derive the same paid amount, balance and status from the live linked payments.

**Cause:** `_recomputeLinkedDoc` writes invoice/bill settlement without queuing that parent; pull does not derive document settlement after applying payment changes.

**Locations:** [payment_repository.dart:228](lib/core/database/repositories/payment_repository.dart#L228), [payment_repository.dart:237](lib/core/database/repositories/payment_repository.dart#L237), [payment_repository.dart:414](lib/core/database/repositories/payment_repository.dart#L414), [pull_applier.dart:144](lib/core/sync/pull_applier.dart#L144).

**Repair direction:** Recompute affected document settlements from linked payments on each device, including bounce and restore. Cover simultaneous receipts as well as edits.

### B04 — Item editing can undo stock changes made while the form is open

**Reproduction:** Open an item with stock 10 for editing. Let a sale or sync reduce its stock to 8. Save a name or price change from the still-open item editor.

**Observed:** Saving the old entity snapshot resets `currentStock` to **10**, while the movement ledger remains **8**. The probe reproduced this using the real repository update path.

**Expected:** Saving catalogue details must preserve inventory changes made after the editor loaded.

**Cause:** The editor submits `_existing.copyWith(...)`; `ItemRepository.update` replaces the whole row, including the stale derived stock fields.

**Locations:** [item_editor_screen.dart:403](lib/features/items/item_editor_screen.dart#L403), [item_repository.dart:176](lib/core/database/repositories/item_repository.dart#L176).

**Repair direction:** Update editable catalogue fields explicitly and preserve/rederive current stock inside the transaction.

### B05 — Locked receipts/payments can be changed by moving their date

**Reproduction:** Record a ₹100 receipt dated 1 September. Lock books through 30 September. Edit the receipt to 1 October and ₹200.

**Observed:** The update succeeds, removes the September receipt from the locked period and changes its amount to ₹200.

**Expected:** The original locked transaction should be protected even if the proposed replacement date is unlocked.

**Cause:** `PaymentRepository.update` checks only `payment.date`, the proposed date, before loading the original; it never checks `original.date`.

**Location:** [payment_repository.dart:156](lib/core/database/repositories/payment_repository.dart#L156).

**Repair direction:** Check both original and replacement dates, matching the sales/purchase edit enforcement pattern.

### B06 — Locked expenses/income can be changed by moving their date

**Reproduction:** Record a September expense, lock September, then change its date to October and its amount.

**Observed:** The independent probe moved a locked **₹100 September expense to ₹200 in October** successfully.

**Expected:** The original locked expense should be protected. The same repository handles other income.

**Cause:** The original entity is read, but only the replacement `expense.date` is checked.

**Location:** [payment_repository.dart:947](lib/core/database/repositories/payment_repository.dart#L947).

**Repair direction:** Enforce the lock against the original and replacement dates inside the mutation transaction.

### B07 — Read-only accountants can adjust stock

**Reproduction:** Enable a member session with `MemberRole.accountant`, then post a manual stock adjustment.

**Observed:** A role explicitly defined as read-only changed stock from **10 to 15** through `applyStockEffect`. The Stock screen exposes this same path without a role check.

**Expected:** A read-only member cannot mutate stock, valuation or the outbox.

**Cause:** The stock adjustment entry point has no permission enforcement; the shared movement writer has none either. Document writers have their own permission checks, but the standalone adjustment path does not.

**Locations:** [item_repository.dart:529](lib/core/database/repositories/item_repository.dart#L529), [stock_screen.dart](lib/features/stock/stock_screen.dart), [member_role.dart](lib/core/domain/member_role.dart).

**Repair direction:** Introduce an authorized manual-adjustment operation at the repository boundary and make its UI reflect the permission.

### B08 — Typing alone does not arm the item/party unsaved guard

**Reproduction:** Open Add Item or Add Party, type a name, and use Back without changing a dropdown or another control that rebuilds the editor.

**Observed on both platform variants:** The rendered `UnsavedGuard.hasChanges` remains **false** after typing. Back closes the editor, **no confirmation appears**, and the typed name is lost. Four scenarios were reproduced: Android item/party and Windows item/party.

**Expected:** The first text edit should immediately activate the unsaved-changes guard.

**Cause:** Controller listeners call `_markDirty`, which changes a boolean without rebuilding the enclosing `UnsavedGuard`/`PopScope`.

**Locations:** [item_editor_screen.dart:89](lib/features/items/item_editor_screen.dart#L89), [item_editor_screen.dart:450](lib/features/items/item_editor_screen.dart#L450), [party_editor_screen.dart:56](lib/features/parties/party_editor_screen.dart#L56), [party_editor_screen.dart:383](lib/features/parties/party_editor_screen.dart#L383).

**Repair direction:** Make the dirty-state transition rebuild/reactively update the guard. Test text-only edits rather than selecting a customer or dropdown first.

### B09 — Android Back silently destroys a POS cart

**Reproduction:** Open Counter sale, add an item using its SKU, use Android system Back, then reopen Counter sale.

**Observed:** The route returns to Dashboard without a discard prompt. Re-entry shows an empty cart. The probe verified the item was in the cart before Back; no invoice had been saved.

**Expected:** Preserve the draft cart or ask before abandoning it. The explicit Clear action already recognizes that clearing a whole cart deserves confirmation.

**Cause:** POS holds the cart in screen state and does not guard route exit. The new section Back history correctly navigates away, which now exposes this data-loss path.

**Locations:** [pos_screen.dart:622](lib/features/pos/pos_screen.dart#L622), [pos_screen.dart:627](lib/features/pos/pos_screen.dart#L627), [mobile_back_navigation.dart](lib/core/navigation/mobile_back_navigation.dart).

**Repair direction:** Guard exit while a cart is nonempty and/or persist a recoverable draft. Review the Windows leave-counter button too; its code is shared, but this audit reproduced the loss using Android system Back.

### B10 — Bank overdraft entry silently becomes a positive balance

**Reproduction:** Type or paste `-5000` into Bank & Cash → Add/Edit account → Opening balance.

**Observed:** The formatter transforms it to **`5,000`**, so the sign is lost before parsing and saving. The field explicitly requests a signed keyboard and its parsing comments say overdrafts are accepted.

**Expected:** Preserve the negative amount and display a ₹5,000 overdraft.

**Cause:** `IndianAmountInputFormatter` removes every character except digits and periods, including `-`.

**Locations:** [bank_accounts_screen.dart:388](lib/features/settings/bank_accounts_screen.dart#L388), [formatters.dart:238](lib/core/utils/formatters.dart#L238).

**Repair direction:** Use a signed formatter for balance fields; keep document amount restrictions separate.

### B11 — Dashboard Cash in hand ignores cash expenses

**Reproduction:** Record a ₹1,000 cash receipt, then a ₹200 cash rent expense.

**Observed:** Dashboard summary cash remains **₹1,000** while the actual cash ledger is **₹800**. The Windows dashboard labels the payment-only calculation as “Cash in hand”.

**Expected:** Dashboard cash should agree with the cash ledger, including cash expenses/income and relevant opening/journal entries.

**Cause:** Dashboard `cashIn`/`cashOut` sum payments only; expense/income cash movements are posted by the ledger but omitted here.

**Locations:** [report_repository.dart:470](lib/core/database/repositories/report_repository.dart#L470), [dashboard_screen.dart:827](lib/features/dashboard/dashboard_screen.dart#L827), [ledger_repository.dart](lib/core/database/repositories/ledger_repository.dart).

**Repair direction:** Read the accounting cash balance instead of maintaining a second, incomplete balance formula.

### B12 — Dashboard To receive excludes opening balances and unallocated receipts

**Reproduction:** Create a customer with ₹1,000 opening debit balance and record an unallocated ₹200 receipt.

**Observed:** Party outstanding is correctly **₹800**, but dashboard `receivable` is **₹0**. The desktop snapshot displays that incomplete figure as “To receive”. The corresponding payable formula has the same document-only shape.

**Expected:** Business-wide receivable/payable summaries should reconcile to party balances under an explicitly consistent netting policy.

**Cause:** Dashboard sums invoice/bill balances and note balances. It does not include party opening balances or unallocated payments, unlike `outstandingFor`.

**Locations:** [report_repository.dart:478](lib/core/database/repositories/report_repository.dart#L478), [dashboard_screen.dart:814](lib/features/dashboard/dashboard_screen.dart#L814), [party_repository.dart:317](lib/core/database/repositories/party_repository.dart#L317).

**Repair direction:** Use one reconciled party-balance aggregation for dashboard and party totals.

### B13 — Bank opening balances never reach trial balance/balance sheet

**Reproduction:** Add a bank account with a ₹1,000 opening balance and no transactions.

**Observed:** Bank & Cash records **₹1,000**. The accounting trial balance contains **₹0 bank assets** from that entry; the zero bank row is omitted. The balance sheet derives from that trial balance.

**Expected:** A brought-forward bank balance should be represented consistently in the accounting books, with a corresponding opening contra/equity treatment.

**Cause:** Bank account saving changes `bank_accounts` only. The ledger reads opening balances from `accounts` and party openings; it does not post bank-account openings. The account editor does not wire an accounting account/opening entry.

**Locations:** [bank_account_repository.dart:17](lib/core/database/repositories/bank_account_repository.dart#L17), [bank_balance.dart](lib/core/database/repositories/bank_balance.dart), [ledger_repository.dart](lib/core/database/repositories/ledger_repository.dart).

**Repair direction:** Wire bank/cash openings into the accounting ledger and reconcile the bank statement and balance sheet against the same underlying entries.

### B14 — Loan-bearing backups fail restore with production foreign keys

**Reproduction:** Create a loan plus one linked disbursement/repayment, export the backup, then restore it with `PRAGMA foreign_keys=ON`, matching the production database setup.

**Observed:** Restore throws **SQLite error 787: FOREIGN KEY constraint failed** on insertion into `loan_transactions`. The transaction rolls back, so the probe confirmed the original loan survives; this is a failed restore, not demonstrated source-data erasure.

**Expected:** An app-exported backup should restore its loan and transactions successfully.

**Cause:** Restore inserts loan transactions **before** their referenced loans. The comments describe the dependency backwards. Default in-memory fixtures do not automatically reproduce production foreign-key enforcement.

**Locations:** [settings_repository.dart:471](lib/core/database/repositories/settings_repository.dart#L471), [banking.dart:137](lib/core/database/tables/banking.dart#L137), [app_database.dart](lib/core/database/app_database.dart).

**Repair direction:** Restore parents before children and run backup roundtrip tests with foreign keys enabled. Loans currently have limited UI exposure; this is confirmed for a backup containing these schema-supported records.

### B15 — Expense/income screens silently truncate their totals and search

**Reproduction:** Add 1,001 expenses of ₹10 in the same selected period.

**Observed:** The Expenses screen's provider returns 1,000 records and its summed total is **₹10,000**. The real repository period total is **₹10,010**. Search filters the already-loaded rows, so omitted records cannot be found there. The income provider uses the same cap.

**Expected:** Totals should cover the whole period. All records should be searchable, with explicit pagination if needed.

**Cause:** Providers request `limit: 1000`, and the UI computes totals from those limited arrays.

**Locations:** [expenses_screen.dart:37](lib/features/expenses/expenses_screen.dart#L37), [expenses_screen.dart:49](lib/features/expenses/expenses_screen.dart#L49), [expenses_screen.dart:168](lib/features/expenses/expenses_screen.dart#L168).

**Repair direction:** Compute totals over the full period independently of pagination and move search into the underlying query.

### B16 — Permanent purges do not emit sync tombstones

**Reproduction:** Soft-delete a payment and expense, clear/mark their already-sent outbox entries, then permanently purge them.

**Observed:** Both records are physically removed locally with **zero outgoing sync entries**. Code review finds the same missing enqueue in sales and purchase `purge`.

**Expected:** A permanent deletion must have its own durable sync event so all devices can converge, including after remote restore/repair.

**Cause:** These purge methods delete and audit but never enqueue a tombstone. Item and party permanent deletion already do enqueue one.

**Locations:** [payment_repository.dart:768](lib/core/database/repositories/payment_repository.dart#L768), [payment_repository.dart:1006](lib/core/database/repositories/payment_repository.dart#L1006), [sales_repository.dart:1021](lib/core/database/repositories/sales_repository.dart#L1021), [purchase_repository.dart:604](lib/core/database/repositories/purchase_repository.dart#L604).

**Interaction with B01:** Current soft-delete sync already wrongly hard-deletes the receiver, so an ordinary already-synchronized purge may appear to work. This does not make the missing purge event correct; it masks the defect. Payment/expense lack of events was reproduced; sales/purchase lack of events was confirmed by inspecting the current implementations.

**Repair direction:** Emit permanent tombstones transactionally, independently of the recycle-bin state change.

### B17 — Android POS footer fails at supported scale/accessibility settings

**Reproduction:** Use a 360 × 640 Android viewport, Settings interface scale 150%, OS text scale 150%, then open Counter sale.

**Observed:** Flutter reports **9.7 px horizontal overflow and 71 px bottom overflow**. The count/total column wraps almost character by character, consumes the available screen and overlaps the Review payment action. This was visually inspected with bundled fonts/icons loaded.

**Expected:** The footer should reflow or scroll while keeping the total and action readable and reachable.

**Cause:** A fixed horizontal footer row allocates a shrinking `Expanded` column beside a large intrinsic-width action, with no compact/stacked alternative at this logical width.

**Location:** [pos_screen.dart:696](lib/features/pos/pos_screen.dart#L696).

**Screenshot:** [Android POS scale overflow](build/import-audit/readonly-2026-10-11/android-_pos.png).

**Repair direction:** Stack or wrap footer content when width/text scale demands it. Test all offered zoom values together with OS accessibility text sizes.

### B18 — Stock-adjustment dialog cannot accommodate the Android keyboard

**Reproduction:** On Android 360 × 640 at normal interface/text scale, open Stock → Adjust stock and show a keyboard occupying 300 logical pixels.

**Observed:** Flutter reports **74 px bottom overflow**. Reason entry and the action row visibly overlap; the dialog has insufficient scroll space.

**Expected:** All fields and Post adjustment should remain reachable while the keyboard is visible.

**Cause:** The dialog content uses a non-scrollable `Column` inside a width constraint; its height does not adapt to the reduced keyboard-visible area.

**Location:** [stock_adjustment_dialog.dart:205](lib/features/stock/stock_adjustment_dialog.dart#L205).

**Screenshot:** [Stock dialog with keyboard inset](build/import-audit/readonly-2026-10-11/android-stock-keyboard.png). The screenshot models the occupied keyboard area through view insets; it is not a photograph of a hardware keyboard overlay.

**Repair direction:** Make the dialog content scrollable and verify focused-field/action visibility with keyboard insets and larger text.

## Evidence and reproduction commands

Evidence directory: `build/import-audit/readonly-2026-10-11/`.

| Artifact | Contents |
|---|---|
| `full-tests.log` | Fresh baseline run: 1,179 passed |
| `analyze.log` | Fresh analyzer run: no issues |
| `logic_probe_test.dart` / `logic-probes.log` | 15 independent probes and exact observed values/errors |
| `ui_probe_test.dart` / `ui-probes.log` | 6 probes, platform variants, 36-route sweep, dirty-state/cart/keyboard checks |
| `android-_pos.png` | Visually verified scaled POS defect |
| `android-stock-keyboard.png` | Visually verified stock dialog overflow |
| `android-pos-before-back.png` | Active cart before the Back data-loss check |
| `source-hashes-before.json` / `source-integrity.json` | 598 existing files checked; zero changed |

Run from `D:\Atria`:

```powershell
C:\flutter\bin\flutter.bat analyze --no-pub lib test
C:\flutter\bin\flutter.bat test --no-pub
C:\flutter\bin\flutter.bat test --no-pub build/import-audit/readonly-2026-10-11/logic_probe_test.dart
C:\flutter\bin\flutter.bat test --no-pub build/import-audit/readonly-2026-10-11/ui_probe_test.dart
```

The probes intentionally assert today's faulty results so their successful execution preserves a reproducible audit. After repairs, invert those assertions to expected correct behavior and move suitable regressions into the normal suite. The `build` directory is disposable; preserve these audit artifacts before cleaning it if they are needed for follow-up.

## Coverage limits and items requiring a further pass

- `adb devices -l` returned **no attached Android device**. Android gesture/keyboard findings were reproduced through Flutter's system-Back binding and viewport/inset simulation; no physical-device pass is claimed.
- Windows native navigation/layout inspection was performed, but mutation scenarios were exercised only against isolated databases/widget trees to keep the real books untouched.
- Sync findings exercise the current client writer/outbox/applier code directly. No production cloud deployment, destructive cloud operation or two live signed-in device test was performed.
- This is not a claim that every possible defect has been found. Actual printer hardware, OS file-picker/share cancellation, prolonged offline conflict recovery, live GST filing, and manual visual comparison of every generated PDF format still need dedicated passes.
- Additional code-review risks were not counted among the 18 findings: native Windows window-close draft protection, sales-editor text-only dirty-state transitions, and current-dated settlements against locked older invoices. They need focused reproduction before being called confirmed bugs.

## Suggested repair order — not applied

1. B01–B04: prevent cross-device data loss and disagreement; use production foreign keys in those regressions.
2. B05–B09: enforce locks/roles and protect user drafts/cart state.
3. B10–B13: reconcile balance entry, dashboard and ledger figures.
4. B14–B16: restore dependencies, full-period queries and durable purge events.
5. B17–B18: repair scale/keyboard layouts and repeat the visual sweep.

No app source, existing tests, database records or deployment configuration were edited to fix these findings. This report records the current defects for review.
