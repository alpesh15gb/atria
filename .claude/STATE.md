# Project State

_Last updated: 2026-10-04 (Android "items don't render": root cause found, fixed, regression-tested)_

## 2026-10-04 (later): the actual cause — a batch the server refused

**The user's clue closed this:** *"i uploaded the data from vyb file then i
synced to atria server then when i am seeing the data on android this bug"*. The
import and the phone pull were both fine in isolation; running the whole road —
`.vyb` → push → server → second device — reproduced it exactly.

**Root cause.** `SyncEngine` built push batches by counting rows
(`batchSize = 200`), not by measuring the encoded body. The server refuses
anything over 256KB and rejects the request **whole** — there is no partial
accept. The drain orders every parent before its children, so a full batch of
`purchase_bills` headers fits comfortably, while the much larger
`purchase_bill_items` rows land in requests the server throws away. The server
ends up holding bills with their totals and no items, and any other device
pulls precisely that.

Reproduced in `test/vyapar_sync_roundtrip_test.dart` before the fix:

    PROBE cap push: pushed=0 ... batches=[209, 591]KB bills=199 lines=0
    PROBE cap pull: 199 bills, 0 lines

After the fix: `batches=[200, 200, 198, ...]KB`, phone receives 200 bills and
all 2000 lines, `pending=0`.

**Why it was silent** — two compounding bugs, both mine (from `7688242`):

1. A row the server refused `maxAttempts` (8) times was marked
   `synced_at = sent`. `pruneSent` then deleted it. The invoice existed on **no
   device and no server** while the settings screen reported a clean sync. That
   is the worst possible assumption in a ledger app. Now `_quarantineUnsendable`
   keeps it unsent, keeps it counted in `pending`, skips it in the drain so one
   impossible row cannot wedge the queue, and "Re-send all books" revives it.
2. `rejournalEverything` skipped a quarantined row — the `entity`+`entityId`
   dedupe matched it and `continue`d — so the repair reported success and left
   the row unsent. It now clears `attempts` on rows it finds parked.

**A test was holding the bug in place.** `test/sync_engine_test.dart`'s
"an outbox row with no business is retired with a reason" asserted
`syncedAt` isNotNull for an unsendable row. It passed, and it was asserting the
data loss. Renamed to "…is quarantined, not retired" and inverted.

Verified by reverting the size check in place: the torn-document test fails with
`The server refused the request (HTTP 413).`

## 2026-10-04: the Android items bug — what was fixed, what was ruled out

The report was *"in windows items render but in android items doesnt render in
already saved bill and estimate just the column"*. That is **two** symptoms, and
they have different answers.

### Fixed: "just the column" on a saved invoice/estimate (`6e01476`)

`sale_detail_screen.dart`'s Items card was the only place in the app that did
not use `AtriaLineGrid` — it built a `DataTable` inside a horizontal
`SingleChildScrollView`. Nine columns need ~800dp; a 360dp phone shows the Item
column and pushes every rupee figure off-screen. A desktop window fits the whole
table, which is exactly why this only ever appeared on Android.

It now renders through `AtriaLineGrid` (sheet when wide, labelled card per line
when narrow). Note the widget choice alone was *not* the fix — see "the test that
did not prove anything" below.

Mounting the screen at 360px then surfaced **four pre-existing RenderFlex
overflows**, none in the items card:

- the balance-due strip, the grand-total row and every `_AmountBreakdown` line
  were `Row` + `Text` pairs that did not fit ~294dp;
- the payment Mode `DropdownButtonFormField` had no `isExpanded`, so it laid its
  label out at natural width inside a 119px field.

Money now goes through `MoneyText(shrinkToFit: true)`, which scales a figure down
rather than truncating it — `TextOverflow.ellipsis` on an amount turns
`₹1,23,456.00` into `₹1,23,45…`, and a books app cannot lose a digit to a width
problem. `scaleDown` never grows a figure, so desktop is unchanged.

### Ruled out: the purchase editor's blank line

The screenshot showed "Edit Purchase Bill" with the header loaded but one empty
line row (qty 1, no name, ₹0.00). A default `_LineState` is exactly quantity `1`
with an empty rate — so that row was the grid's empty state, meaning `_prefill`
was handed **zero** items.

Checked and eliminated, in order:

1. **`save()` not deleting old lines on edit** — I claimed this earlier and was
   wrong. `purchase_repository.dart:194-199` does hard-delete the old
   `purchaseBillItems` rows for the bill. Duplicates are not possible.
2. **`itemsFor`'s `is_deleted = 0` filter** — correct; save writes `isDeleted`
   false.
3. **The repository round-trip** — a throwaway test saved a two-line bill,
   re-saved it with a changed rate, and reloaded: both lines present, one raw
   row, `is_deleted` false. The repository is sound.
4. **The editor's reload** — `test/purchase_editor_saved_lines_test.dart` now
   mounts the real `PurchaseEditorScreen(editId:)` over a real saved bill at
   1680px **and** 360px and asserts both line names and both HSNs render. It
   passes. Verified to have teeth by emptying `_prefill`'s loop, which fails both
   cases. **The editor is not the bug.**

Also considered and eliminated on inspection: `applyEntity` writes every field
(name/HSN/qty/rate/discount/GST) correctly, and the derived getters parse via
`Money.tryParse`, which handles Indian grouping.

**So the blank line means the bill genuinely has no `purchase_bill_items` rows.**
The leading remaining hypothesis is a bill created on one device and pulled to
another with its lines lost. The obvious mechanism — `purchase_bill_items`
arriving before `purchase_bills` and hitting the `REFERENCES purchase_bills(id)`
foreign key — was checked and is *not* it: `_nextBatch` sorts every batch by
`journalOrder` so parents always lead, and that ordering is what the comment at
`sync_engine.dart:711-714` documents. **Unverified**, and the thing to check
next: whether the affected bill was created on another device, and whether
`PRAGMA foreign_keys=ON` (on in production, *off* in the in-memory test DB —
which is why no test catches FK-ordering bugs) rejected anything during a pull.
`PullApplier._applyOne` catches a failing child, counts it `skipped`, and the
cursor advances regardless, so a single FK orphan is dropped permanently and
invisibly. That is the shape of the bug, not proof of it.

### The test that did not prove anything

Worth recording, because it nearly shipped. The phone test first asserted that
no `Text` inside the grid sat outside the 360px window — which is precisely the
`DataTable` bug. Reverting the fix to force the wide sheet made it **pass**.
Reason: `_Sheet` is a `Row` of flex cells inside a bounded parent, so at 360px
it *squeezes* its columns rather than overflowing them. "Nothing off-screen" is a
real invariant worth keeping, but it does not detect a squeezed table. The test
was only validated against the genuine original: `git checkout HEAD --
sale_detail_screen.dart` fails it with `Found 0 widgets with type
"AtriaLineGrid"`. Verify a revert landed by checking the failure changed.

### Also fixed earlier this session (`7688242`)

Three silent sync failures: a re-journal id that collided with the server's
`change_id` primary key (a second repair healed nothing), a poison row that
blocked the whole head-of-queue drain for ever, and `journal_lines` re-journalled
under a voided voucher. Plus a firm-scoped `_hardDelete`.

### Still open

- `UnsavedGuard` is dead on both nav rails (`context.go` bypasses `PopScope`) —
  HIGH, an in-progress invoice is lost to a rail click. All 8 guarded editors.
- Invoice line rate/discount have no validator, so a ₹0 line can be saved.
- The invoice does not foot; CGST/SGST halves display over.
- Non-atomic page apply in `pull_applier.dart:128-142` loses rows permanently.

## 2026-10-03: "are we ready to go live?" — verification pass

The answer required checking the open MEDIUM findings against source rather than
from memory. Four were real. All four are now fixed, each with a test proven to
fail when the fix is reverted in place.

Suite: **439 passed, 1 skipped, 0 failed** (was 435 at the start of this pass).
`flutter analyze lib/ test/` → **No issues found!**

### Fixed this pass

1. **The account-ledger Balance column was not a running balance** (MEDIUM).
   `_LedgerMovementRow` added the account's *opening* to every row, so the
   column read 100/200/300 while "Closing" said 600 — the list contradicted
   itself. `LedgerEntryRow` gained a `balance` field; `accountLedger` carries a
   separate `running` accumulator (`opening` must stay put because `closing`
   folds over it — feeding one from the other double-counts). Test:
   `test/ledger_test.dart` (rows 1180 / 780, last == closing).
2. **Indian-grouped amounts were silently dropped** (MEDIUM).
   `journal_editor_screen.dart` and `chart_of_accounts_screen.dart` used
   `double.tryParse`, which returns null for "1,00,000" and fell back to 0 — a
   voucher saved with no amount and no warning. Both now use `Money.tryParse`.
   Test: `test/journal_grouped_amount_test.dart`.
3. **Party opening balances never reached the books** (MEDIUM — the big one).
   `outstandingFor` and the party statement both count a party's opening, but
   the ledger's Sundry Debtors account never did, so the books disagreed with
   every customer statement by exactly the opening, from day one. `_book` now
   derives the posting from the party row (Dr/Cr Debtors vs Creditors, contra
   Capital) rather than writing a voucher at party-save time — a voucher would
   go stale when the opening is edited and be orphaned when the party is
   purged. Test: `test/reconciliation_test.dart` (customer ₹15,000 Dr + supplier
   ₹8,000 Cr, both also asserting `trialBalance.isBalanced`).
4. **The Payments cards disagreed with the ledger** (MEDIUM).
   `_summarize` summed the payment rows alone, so a ₹3,000 cash expense left
   "Cash in hand" ₹3,000 richer than the Cash account. New
   `cashBankBalancesProvider` reads the trial balance; new
   `LedgerRepository.watchBookMovement` ticks it on any of the seven posting
   tables. `CashBankSummary`/`_summarize`/`_cashBankProvider` deleted.
   Test: `test/payments_ledger_agreement_test.dart`.

### Still open

- **MEDIUM — editing a payment breaks the cheque-state invariant**
  (`payments_screen.dart` keeps `chequeStatus` when the mode changes:
  cheque→cash leaves `pending`, cash→cheque leaves null). The one remaining
  real correctness item from the 2026-10-03 audit.
- **Exports/SEZ cannot be recorded at all** — nothing sets `isExport`, and
  `exportType` is persisted but read nowhere. A feature addition (a WP/WOP
  choice in the sale editor + EXPWP/EXPWOP tables in `gstr1_report`), not a
  calculation fix. Blocked the two GST "HIGH" findings as unreachable.
- **LOW** — reports grid 2-up at 360dp ellipsizes labels; POS cart row amount
  fixed 96dp; sale editor date row has no compact fallback; filter-pill touch
  targets under 48dp.
- **Release/packaging** — release builds (`--release` Windows + APK; APK needs
  a signing config), rebuild + install the debug APK on hardware to confirm the
  route fix, three `*_plus` plugins still apply the Kotlin Gradle Plugin.

### Test-writing lessons (recorded in `.claude/memory/bugs.md`)

- Assert on the **rendered figure** (`find.text('₹7,000.00')`), not on a
  widget-tree path. The payments card stacks icon-above-text below the compact
  breakpoint, so the Row carrying the label is not the Row carrying the figure.
- A provider that re-derives from an async report needs a **pump-until-emitted**
  loop, not `pumpAndSettle`, which can stop before the stream ticks.
- Prove every new test catches its bug: revert in place, run, confirm the exact
  failure, restore. This pass's four reverts produced four distinct failures.

---

## 2026-10-03 (earlier): phone-width and widescreen alignment pass

Goal was "check for ui is it properly aligned on both android and windows". The
method that worked: pump each screen at a real viewport in a widget test and
let Flutter say whether it overflowed, with the app's bundled Inter registered
first (the test fallback font is far wider — see `.claude/memory/bugs.md`).

Baseline before this pass: 411 passed / 1 skipped. After: 435 passed, 1
skipped, 0 failed, `flutter analyze lib/ test/` clean.

Tests added (each verified to fail without the fix it guards):

- `test/pos_double_billing_test.dart` — the POS double-billing fix.
- `test/journal_editor_archived_account_test.dart` — archived account in a
  journal editor's dropdown.
- `test/phone_width_smoke_test.dart` — all 13 tabs at 360×640 + the dashboard at
  1920×1080 + a *measurement* test asserting the sales list's column is capped
  at a reading width on 1920dp (`headerWidth < 1500`).
- `test/statement_ledger_phone_test.dart` — both ledger screens with a crore
  running balance at 360dp.
- `test/settings_widescreen_test.dart` — printer settings, period lock, audit
  log and payment reminders at 1920×1080, each asserting the column is capped
  *and* seeded with real rows (an empty screen's centred message is narrow by
  design, which would pass the width check for the wrong reason).

Fixes (all in `.claude/memory/bugs.md` under this date):

- `atria_list_toolbar.dart` pill label — overflowed 26–48px on five list tabs.
- `dashboard_screen.dart` trend bars — 36px of bars in a ~34.8px slot.
- `pos_screen.dart` — totals pane bounded + scrollable; was squeezing the cart
  to a sliver and pushing Complete off a short phone.
- `common_widgets.dart` `EmptyState` — the actual POS overflow source; its
  intrinsic Column height exceeds a squeezed flex parent.
- `party_statement_screen.dart` / `statement_of_account_screen.dart` — column
  header ellipsis, compact running balance, and the **redundant reference chip
  removed** (see bugs.md — it duplicated the number already in `particulars`
  and could not fit a 91dp column).
- `sale_detail_screen.dart` — meta-chip ellipsis; items table floor used the
  window width instead of `constraints.maxWidth`, so at 1920px the card held
  ~1040px while the table was forced to 1880px.
- `sales_list_screen.dart` / `purchase_list_screen.dart` — trailing slot 36→48
  to match `DocumentRowMenu`'s real tap target.
- `journal_list_screen.dart`, `chart_of_accounts_screen.dart`,
  `ledger_reports_screen.dart` — ellipsis where `overflow` alone was wrapping.
- `payments_screen.dart` `_SummaryCard` — stacks three cards vertically under
  600dp instead of crushing each to ~101dp.
- `money_text.dart` — gained a `textAlign` param; `reports_screen.dart`'s rate
  table right-aligns its headers but its amounts were left-aligned.
- **Widescreen**: `AtriaListPage` now centres and caps at
  `constraints.contentMaxWidth` (the token was dead code), new
  `AtriaContentWidth` widget applied to `printer_settings_screen.dart` (both
  the list and the editor), `period_lock_and_audit_screens.dart` (both bodies)
  and `payment_reminders_screen.dart`; the two statement screens unified on
  980.

Not changed, deliberately: `firm_settings_screen.dart` has an explicit reasoned
comment about staying full width (its fields group two-up via `_FieldRow`), and
`EditorShellBody` / `AtriaEditorForm` already own their own `maxFormWidth` /
`maxContentWidth`.

Also fixed this day (earlier audit pass, tests in place):
- **HIGH — a bounced cheque stayed in the books as an asset.** `_book` selected
  every non-deleted payment with no `chequeStatus` filter. Now
  `isNull() | not(equals('bounced'))` (drift 2.31 has no `isDistinctFrom`, and
  plain `not(equals())` on a null is SQL-null and would drop every cash/bank
  payment too). Test: `test/bounced_cheque_ledger_test.dart`.
- **HIGH — archiving an account erased its opening balance.** `_book` now loads
  `allAccounts(includeInactive: true)`. Test:
  `test/archived_account_balance_test.dart`.
- **LOW — the recycle bin's Restore icon had no error handling**; the invoice
  title printed the raw slug (`sales_order`) instead of "Sales order".

## Exact next action

1. **Rebuild + install the app and re-import the real `.vyb`** to confirm the
   line items now reach the server. The bug is fixed and regression-tested in
   isolation; it has not been seen working against the real server yet.
2. Fix the HIGH items: `UnsavedGuard` is dead on both nav rails (below), then
   invoice rate/discount have no validator (silent ₹0 lines).
3. Fix the last MEDIUM: the payment editor's cheque-state invariant when the
   mode changes (`payments_screen.dart` ~845–867). Add a test that flips
   cheque→cash and cash→cheque and asserts `chequeStatus` is right.
4. Release builds (`--release`): Windows + APK. APK needs a signing config.
5. Decide on exports/SEZ as a post-launch feature.

## ⚠️ Build toolchains are MISSING from this machine (2026-10-03)

`flutter doctor`: "Visual Studio not installed" and "Unable to locate Android
SDK". Verified by disk search, not just doctor:

- `C:/Program Files/Microsoft Visual Studio` and
  `C:/Program Files (x86)/Microsoft Visual Studio` **do not exist**. The only
  `MSBuild.exe` on C: is the .NET Framework one in `WinSxS` — not the C++
  workload Windows builds need. `vswhere.exe` is absent.
- No Android SDK anywhere: `AppData/Local/Android`, `C:/Android`,
  `D:/*/Sdk`, `E:/*/Sdk` all absent; `ANDROID_HOME`/`ANDROID_SDK_ROOT` are
  empty; `~/.gradle` does not exist either.
- Both build commands fail immediately:
  - `flutter build windows --debug` → "Unable to find suitable Visual Studio
    toolchain."
  - `flutter build apk --debug` → "No Android SDK found."

This is the same class of loss as the Flutter SDK disappearing earlier (see
the note below) — a working install stopped being visible.

**The on-disk artifacts are stale** and must not be shipped as if current:

| Artifact | Built | Last commit |
|---|---|---|
| `build/windows/x64/runner/Debug/atria.exe` | 2026-09-27 00:14 | HEAD 2026-10-02 |
| `build/app/outputs/flutter-apk/app-debug.apk` | 2026-09-27 21:00 | HEAD 2026-10-02 |

Both predate the whole October audit pass (the router fix, the editor/list
revamps, and every fix recorded above). They contain known bugs that have
since been fixed — the ledger running balance, the grouped-amount parse, the
party-opening reconciliation gap.

**To restore builds**, one of:
- Reinstall Visual Studio with the "Desktop development with C++" workload,
  and Android Studio (or a standalone SDK + `flutter config --android-sdk`),
  then rebuild; or
- Restore from whatever backup/image held these before the loss, if there is
  one; or
- Build on another machine that has the toolchains — the repo is git-tracked,
  so `git clone` + `flutter pub get` + `build_runner` is enough.

`git`, `flutter`, and `dart` themselves still work (the whole 439-test suite
ran on this SDK today). Only the two native toolchains are gone.

## Useful commands

```bash
# Analyzer (clean exit = success)
/c/flutter/bin/flutter.bat analyze lib/ test/

# Tests (goldens excluded by dart_test.yaml)
/c/flutter/bin/flutter.bat test

# Native builds
/c/flutter/bin/flutter.bat build windows --debug
/c/flutter/bin/flutter.bat build apk --debug
```

Before any `flutter test`, stop lingering processes or `sqlite3.dll` locks the
build dir: `Get-Process -Name dart,dartvm,flutter_tester,flutter | Stop-Process -Force`

---

## Prior sessions

## Current objective

Bring Atria to a clean, production-ready baseline: zero analyzer issues, passing tests,
and building binaries for every target. Then fix the functional/UX bugs the user reported.

## Current implementation state

- Working:
  - Full Flutter app: GST invoicing, purchases, parties, stock, expenses, reports, PDF.
  - `dart analyze lib/` → **No issues found!**
  - `flutter test --exclude-tags golden` → **439 passed, 1 skipped, 0 failed.**

_Last updated: 2026-10-02 (audit pass; toolchain unavailable — see the blocker note below)

## ⚠️ Toolchain restored and the 2026-10-02 edits VERIFIED (2026-10-02, later)

The SDK was restored at `C:\flutter` (Dart 3.13.5, Flutter revision 5fc346839b).
Re-ran after `flutter pub get`:

- `dart analyze lib/ test/` → **No issues found!**
- `flutter test --exclude-tags golden` → **397 passed, 1 skipped** (the suite has
  grown far beyond the 87 recorded for 2026-09-27; +4 are the new
  service-stock / SKU / refresh tests below).
- `flutter test test/invoice_discount_apportionment_test.dart` → 7/7, all
  hand-traced expectations exact.

Two corrections surfaced when the compiler could finally run, both in the GSTIN
uniqueness check (the engine fix was clean as written):

1. `party_editor_screen.dart` imported drift as `show Value`, so drift's `&` on
   `Expression<bool>` was out of scope → `import ... show BooleanExpressionOperators, Value`.
2. `repository!.firmId` inside the `repository != null` block was a redundant
   `!` on a promoted non-nullable → `repository.firmId`.

**The percent-discount shift flagged earlier did not break anything** —
`money_precision_test`'s 'awkward rates' case still passes; the stored
`taxableValue` lands where it displays.

## ⚠️ Previous blocker (resolved): no Flutter SDK on this machine

`C:\flutter` **no longer exists** (the location recorded near the bottom of this
file). `where flutter` / `where dart` find nothing, PATH has no entry, and a
depth-4 sweep of C:/D:/E: found no `dart.exe` or `flutter.bat`. The last known
baseline (`dart analyze` clean, 87/87 tests, both builds) was produced by that
SDK on 2026-09-27 — **it is not reproducible here now.**

Consequence: **no change made on 2026-10-02 was compiled or test-run** until the
SDK was restored later that day (see the note above). Treat "exit 0" from any
background build with suspicion — a stale task id once reported an old log as
fresh success.

### Unverified changes made 2026-10-02 → now VERIFIED (see the note above)

1. **`lib/features/parties/party_editor_screen.dart`** — GSTIN uniqueness check
   in `_save` (mirrors the barcode check in `item_editor_screen.dart`). Verified
   by inspection only: `db.select(db.parties)` matches the pattern at
   `party_repository.dart:76`; `firmId`/`gstin`/`isDeleted` are real columns; no
   other GSTIN-uniqueness logic exists (not redundant, not conflicting).
2. **`lib/core/engine/gst_engine.dart`** — fixed the invoice-level-discount
   apportionment (HIGH). The old code scaled each line by
   `ratio = Money.div(invoiceDiscount, preDiscountTaxable)`, which rounds a
   non-terminating quotient to 2 dp: ₹10 off ₹300 used 0.03 instead of 1/30 and
   left the line at ₹291 rather than ₹290; ₹1 off ₹300 rounded to 0.00 and was
   dropped while the PDF still printed "Discount ₹1.00". Replaced with exact
   paisa-level apportionment (`_apportionInvoiceDiscount`, largest fractional
   remainder) so `Σ lineTaxable == preDiscountTaxable − invoiceDiscount`. Also
   added `invoiceDiscount = Money.round2(invoiceDiscount)` so a percent discount
   (7.5% of ₹299.97 = ₹22.49775) settles to paisa first; that shifts the stored
   `taxableValue` for such a document by a sub-rupee — it displays identically,
   but **re-check any test that pins a percent-discount document's totals.**
   Regression test added: `test/invoice_discount_apportionment_test.dart`
   (7 tests, expectations hand-traced, **NOT YET RUN**).

### 2026-10-03 — second audit pass: reports, ledger, payments, recycle bin

Verified against source before changing anything; the two agents' reports
caught three live bugs and one dead-code path.

**FIXED (with regression tests):**
- **HIGH — a bounced cheque stayed in the books as an asset.**
  `ledger_repository._book` selected every non-deleted payment with no
  `chequeStatus` filter, so a returned cheque kept posting Dr Cheques in hand
  while the payment repository had already released the invoice it settled —
  the ledger and the party reports disagreed, over a balance sheet that still
  foots. Now `chequeStatus.isDistinctFrom('bounced')`, using the codebase's
  existing null-safe idiom (`isNull() | not(equals(...))` — drift 2.31 has no
  `isDistinctFrom`, and plain `not(equals())` on a null status is SQL-null and
  would silently drop every cash/bank payment too). The app's own contract is
  stated in three places that all agree now: `payment_repository:302`,
  `payments_screen:351` and `markChequeBounced`'s doc. Test:
  `test/bounced_cheque_ledger_test.dart` (3 tests, incl. a cleared cheque that
  must still post to Bank).
- **HIGH — archiving an account erased its opening balance.** `_book` loaded
  active accounts only, so a retired account's opening vanished with no contra
  (trial balance out by that amount) and its journal movements were re-posted
  to Suspense. `setAccountActive`'s own doc says the account "stays in the
  chart for the entries that reference it", and the delete dialog sends users
  with history to archive for exactly that reason. `_book` now loads
  `allAccounts(includeInactive: true)`. Test:
  `test/archived_account_balance_test.dart` (2 tests; the opening one uses a
  balanced Dr-asset/Cr-capital pair so `isBalanced` is a meaningful check).
- **LOW — the recycle bin's Restore icon had no error handling**, so a restore
  refused by the period lock failed silently (the purge path already caught
  and surfaced its error). Now both do. Also: the invoice title printed the
  raw slug (`sales_order`) instead of "Sales order" — replaced with a small
  `_docTypeLabel` switch.

**ASSESSED, NOT A BUG:** the GST agent's two HIGH findings
(exports-with-payment taxed but unreported in 3.1(b); GSTR-1 dropping exports
from every section) are in code the app **cannot reach**: nothing in `lib/`
ever sets `isExport` true — not the sale editor, not the seeder, not the
importer — and `exportType` (`wp`/`wop`) is persisted but read nowhere. So
both are latent at most. The real gap is that **the app cannot record an
export or SEZ supply at all**, which is a feature addition (a WP/WOP choice in
the editor plus EXPWP/EXPWOP tables in `gstr1_report`), not a calculation fix.

**ASSESSED, NOT A BUG:** the cross-branch deep-link finding (see below) — the
Sales branch's home already is the invoice list.

### Remaining open (from the 2026-10-03 agents, verified as real but not yet fixed)

Ledger/payments agent — MEDIUM, all confirmed against source:
- **Account-ledger Balance column is not a running balance** —
  `ledger_reports_screen.dart:814` adds the account's *opening* to every row
  instead of accumulating. The list contradicts itself and its own closing row.
- **Journal amounts typed with Indian grouping are silently dropped** —
  `journal_editor_screen.dart:35-36` uses `double.tryParse` (rejects "1,000")
  and `_save` skips lines whose parsed value is 0, so a line vanishes from the
  saved voucher with no message. `payments_screen` already uses `Money.parse`
  and shows an error — the model to copy.
- **Editing a voucher whose account was archived hits a Flutter assertion** —
  `journal_editor_screen.dart:148` filters the dropdown to active accounts
  while `_LineRow` passes the archived id as `initialValue` →
  "There should be exactly one item with the value". Debug crash; release
  renders the field blank.
- **POS can bill the same cart twice** — `pos_screen.dart:351-410` commits the
  invoice before the receipt; if payment creation or printing throws, the
  message says "Could not complete the sale" and the cart is retained, so
  pressing Complete issues a second invoice for the same goods.
- **Editing a payment breaks the cheque-state invariant** —
  `payments_screen.dart:845-867` keeps `chequeStatus` when the mode changes
  (cheque→cash leaves `pending`, cash→cheque leaves null).
- **Debtors/Creditors can never reconcile to party balances** — party
  openings are posted nowhere in the ledger, and party-less payments post to
  Debtors/Creditors while `party_repository` attributes only party-carrying
  ones. No report exposes the gap.
- **Payments-screen balance cards disagree with the ledger** —
  `_summarize` counts payments only, while expenses/income also post to
  Cash/Bank; `_cashBankProvider` is also capped at 10,000 rows.

GST agent — real, lower priority: GSTR-1 has no EXPWP/EXPWOP table (moot until
exports are recordable, above); `doc_issue` from/to emit the number *prefix*
(`INV-1`) instead of the numeric serial the offline utility wants
(`gst_return_builder.dart:326-342`); 3B clamps net reversals to zero
asymmetrically; the 2A reconciliation CSV's totals row is column-shifted
(`gst_export_service.dart:105-119`); CDNR/`_invoice` can emit an empty
`itms`; the envelope emits an unknown `gtin` key; B2CL gates on taxable value
rather than invoice value (flagged with deliberate uncertainty by the agent).

### Test harness: three widget tests hung at `db.close()` after the healing fix

After `ActiveFirmController` gained its drift existence watch, three widget
tests started timing out — always the same three, in a parallel run, a
two-file run, **and** `--concurrency=1`. My first hypothesis was parallel-suite
contention; that was **wrong** (the serial run failed identically), and running
`service_stock_test.dart` on its own reproduced it. All three were the
teardown: the tests called `select(...)` and then let a file-level
`tearDown(() => db.close())` close the database with no pump-down, so the
watch's teardown timers never fired. Fixed with a local helper in
`service_stock_test` and a corrected teardown in the router test. See
`.claude/memory/bugs.md` (2026-10-03) for the pattern to copy into any future
test that selects a firm — **the 1s pumps must come after `container.dispose()`**,
since the teardown timer only starts when the subscription is cancelled.

**Suite status: 411 passed, 1 skipped, 0 failed, no timeouts**
(`flutter test --exclude-tags golden --concurrency=1`).

### Open audit findings (verified against source, not yet fixed)

Dashboard/parties/items/stock agent:
- ~~**HIGH** — a `Service` item can be stock-tracked, polluting the Stock screen
  and low-stock counts.~~ **FIXED 2026-10-02** — the item editor now forces
  `stockType = 'untracked` when "Service" is picked, locks the toggle with an
  explanatory caption, and the save path re-derives it; the read side
  (`item_repository.stockValue`/`lowStock`, `report_repository` stock value +
  summary, `items_screen` stats) now applies the same `isService` test the two
  movement writers already used, so pre-existing bad rows stop distorting
  totals. Regression test: `test/service_stock_test.dart` (2 tests, passing).
  Compiles + full suite verified.
- ~~**MEDIUM** — stock summary never refreshes after a sale made elsewhere
  (IndexedStack keeps the tab mounted; needs a branch-index signal).~~
  **FIXED 2026-10-02** — `_stockSummaryProvider` now depends on
  `itemMovementSignalProvider`, a `StreamProvider` over the firm's movement log
  (`ItemRepository.watchAllMovements`). `currentStock` is a cached balance every
  movement rewrites, so any sale/purchase/adjustment anywhere re-runs the
  summary. Chosen over a branch-index signal through the router (one less thing
  to plumb) and over a lifecycle observer (only covers app-resume, not the
  common sell-then-switch-tab path). Regression test verified by control: it
  FAILS against the stashed fix and passes with it.
  **Test gotcha:** a widget test that mounts `StockScreen` hangs at `db.close()`
  unless it unmounts with ≥1s pump steps after `container.dispose()` — the
  stream-teardown timers must fire inside fake async. Copy the teardown in
  `stock_screen_regression_test.dart`. Also: output is buffered to the end of a
  `flutter test` process, so a hung test shows an empty log; instrument with
  prints and read them only after exit.
- ~~**MEDIUM** — duplicate SKU allowed.~~ **FIXED 2026-10-02** — app-side
  uniqueness check in `item_editor_screen._save`, mirroring the existing
  barcode check (hoisted `db` so both share it). Case-insensitive, because a
  SKU is read off a label. Blank codes exempt. Regression test covers the
  case-differing duplicate and asserts the error names the owning item.
- ~~**MEDIUM** — a sale price of ₹0.00 is accepted (`Validators.amount`
  `allowZero: true`).~~ **FIXED 2026-10-02** — the item's sale-price field now
  validates `allowZero: false`.
- ~~**LOW** — a sale price below the purchase price saves silently.~~
  **FIXED 2026-10-02** — advisory validator message ('Selling below cost
  (₹…)') on submit. Deliberately non-blocking: below-cost selling is a real
  business choice (clearance, loss leader), so the user is told and can
  re-submit, not stopped.

Router/app-state agent (the rest of that report verified correct — redirect,
boot gate, shell, query params, per-firm caching all sound):
- ~~**MEDIUM** — `pull_applier.dart:148` hard-deletes a firm on a sync tombstone
  without repointing the active firm (the local deletion path does repoint via
  `_repointActiveFirm`); leaves a phantom selected business until relaunch.~~
  **FIXED 2026-10-02** — rather than push Riverpod into the applier,
  `ActiveFirmController` heals itself: `_watchFirmExistence` subscribes to
  `watchById` for the selected firm and, when the row goes, applies the same
  policy as the local path (clear when none remain, else the default, else the
  first remaining, promoting it to default). `select`/`_init` both install the
  watch; `dispose` cancels it. Regression test `test/active_firm_healing_test.dart`
  (3 tests: repoint to default, clear when the last business dies, an unrelated
  deletion leaves the open one alone). UNVERIFIED whether a second signed-in
  device is even reachable in this build — the fix is defensive, exercised by
  a raw `DELETE` that mimics the tombstone path.
  **Test gotcha:** the test must `await ...ready` *before* `select(...)`. If
  `select` races `_init`, init's `state = defaultFirm.id` lands afterwards and
  overwrites the selection — and it cancels the watch on the deleted firm, so
  the healing never runs at all. The app is safe from this because the boot
  gate awaits `ready` before any UI can pick a firm.
- ~~**LOW** — `syncStatusProvider` (`providers.dart:86`) is computed once and only
  invalidated after a manual sync, so "changes waiting to be sent" is stale
  after writes made before Settings is opened.~~ **FIXED 2026-10-02** — it is
  now a `StreamProvider` over `SyncEngine.watchPendingCount()` (a drift
  `watchSingle` count of unsent outbox rows), so the count follows the outbox.
  Settings is branch 11 of 13 and stays mounted offscreen under the shell's
  IndexedStack, so a cached read really would have kept reading the value from
  when the screen was first built. The raw stream emits once per write, so
  `_coalesceOutboxChanges` passes the first event through at once and then
  waits a second of quiet — a billing burst becomes one re-read, not one per
  document. Regression test `test/sync_status_freshness_test.dart`.
- ~~**LOW** — adaptive nav shell: a cross-branch deep link (`/sales?type=invoice`
  from the More sheet) becomes the tab's remembered root, so re-tapping Sales
  reopens the filtered list instead of its home.~~ **ASSESSED, NOT A BUG
  (2026-10-02)** — the Sales branch's *home already is* the invoice list:
  `SalesListScreen._docType` defaults to `'invoice'` when `initialType` is
  absent (`sales_list_screen.dart:44`), and the in-screen Type segmented filter
  can switch back to it. Nothing strands the user anywhere they can't leave in
  one tap; the "remembered root" behaviour is the shell deliberately keeping
  each tab's place.

GST/math agent (partly disputed):
- `money.dart` `div`/`over100` do not round a *terminating* quotient to scale 2
  (`div(1, 8)` = 0.125), contradicting their docstrings. The agent's parallel
  claim that `percent` leaks scale 4 is **wrong** — `percent` wraps its result
  in `round2`. Harmless in practice (every display path re-rounds).
- ~~`formatters.dart` `moneyCompact(12345)` returns `₹12.35 K`, contradicting its
  own docstring (LOW).~~ **FIXED 2026-10-02** — the `K` branch is gone; below a
  lakh there is no Indian compact unit, so the amount renders as the grouped
  figure the docstring always promised (`₹12,345`). "K" also read as a
  percentage to many shopkeepers, and rounding 12,345 up to 12.35 K lost the
  exact figure. Regression test `test/formatters_test.dart` (4 tests).
### How to resume

1. Restore or point at a Flutter SDK (`C:\flutter\bin` was the recorded path).
2. `dart analyze lib/ test/` — the engine edit is the risky one.
3. `flutter test --exclude-tags golden` — was 87/87; the new apportionment file
   adds 7, and `money_precision_test`'s 'awkward rates' case is the one to
   watch for the percent-rounding shift.
4. Re-verify the open findings against the current tree before fixing them —
   the audit agents were briefed on an older file inventory.

---

## Prior sessions

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
