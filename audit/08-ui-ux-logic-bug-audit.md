# Atria — UI/UX + Logic Bug Audit

_Date: 2026-10-03/04. Baseline: `master` @ `00d1714`, working tree (202 files dirty)._

> **FIX PASS COMPLETE.** Every finding below has been worked through by ten engineers plus a
> chief integrator, under strict per-file ownership, with `dart analyze lib test` clean at the
> end. Section **H** is the fix ledger and lists what still has to be done by hand.

**Scope:** all 143 Dart files in `lib/`, plus `android/app/src/main/AndroidManifest.xml`,
`android/app/build.gradle.kts`, `windows/runner/*`, `pubspec.yaml`.
**Method:** six independent deep-read passes over disjoint areas, each finding then
re-verified by direct line inspection. Platform claims checked against the Flutter /
go_router / `decimal` / `archive` / `file_picker` sources in the pub cache.

Findings marked **[v]** were re-confirmed line-by-line in a second session.

---

## Verdict

| Severity | Count | Worst areas |
|---|---|---|
| Critical | 15 | Backup/restore data loss, editor discard trap, sync merge, trial balance, GST returns, navigation shell |
| High | 26 | Sync session handling, Windows print path, list pagination, stock/outstanding correctness, barcode lookup |
| Medium | 31 | Responsive breakpoints, keyboard types, empty states, ledger classification, overflow at 360dp |
| Low | 34 | Copy, hit targets, dead code, comments |

**The single most damaging theme:** several bugs are *silent*. They look correct, report
success, and quietly corrupt money or lose data. Those are marked **[SILENT]** below and
should be treated as the top priority regardless of severity label.

---

## A. Critical

### A1. "Discard changes" can never leave any editor **[v]**
`lib/shared/widgets/unsaved_guard.dart:34`

`UnsavedGuard` wraps each editor in `PopScope(canPop: !hasChanges)`. On confirm it calls
`navigator.pop()`, but `canPop` is still `false`, so Flutter vetoes the pop and re-fires
`onPopInvokedWithResult(didPop: false)` → the dialog opens again. Flutter's own
`pop_scope.dart` documents this: *"Programmatically attempting pop navigation will also
result in a call to `onPopInvokedWithResult`, with `didPop` false."*

Infinite dialog loop. Affects sale, purchase, item, party, expense, journal and firm-settings
editors on **both** platforms (Android system back, Windows back button/Escape).
No test covers it — `grep -r Discard test/` → 0 matches.

**Fix:** hold a `_confirmedDiscard` flag, flip `canPop` to true, and pop after the frame.

---

### A2. Backup/restore silently destroys the ledger **[v] [SILENT]**
`lib/core/database/repositories/settings_repository.dart:216-241`, `:376-394`

`export()` writes `firms, parties, categories, units, items, stock_movements,
sales_invoices, sales_invoice_items, purchase_bills, purchase_bill_items, payments,
expenses, firm_members, settings`.

It does **not** write `accounts`, `journal_entries`, `journal_lines` or `audit_logs`.
`_clearAll()` also never deletes those tables.

- Restore onto a new device → every journal voucher and the whole chart of accounts are
  gone, and the UI reports "Restored N records".
- Restore over existing data → the previous firms' accounts and journals survive as
  orphans pointing at `firmId`s that no longer exist.

A "Ledger" feature (chart of accounts, journal vouchers, balance sheet, trial balance)
exists in the app but is absent from the backup format.

---

### A3. The backup file contains a live session; restoring it signs you in as that user **[v] [SILENT]**
`settings_repository.dart:212-214`, `:287`, `:130-133`

`export()` selects every `app_settings` row where `firm_id IS NULL` — exactly where
`access_token`, `refresh_token`, `access_token_expires_at`, `user_email` and `device_id`
live. `Settings → Backup → Export` writes that to a plaintext JSON file and
`backup_restore_screen.dart:470-476` offers **Share** on it.

Restoring writes the same rows back, so restoring a colleague's backup silently
authenticates this device as them — no password, no prompt, `signedIn` flips true.

(`access_token`/`refresh_token` are deliberately plaintext in SQLite and documented as
such at `settings_repository.dart:125-129` with a DPAPI/Keystore upgrade named. That is a
known trade-off. Exfiltrating them through the *shareable backup* is a separate,
unacknowledged hole.)

---

### A4. Trial balance returns ₹0.00 for every account, every January–March **[v]**
`lib/features/ledger/ledger_reports_screen.dart:376-384`, `:393-396`

```dart
start: DateTime(DateTime.now().year, 4, 1),
end:   DateTime.now(),
```

Hardcoded instead of `FinancialYear.forDate(now).start`. On 15 Feb 2026 that is
**start 2026-04-01, end 2026-02-15** — start after end. Every movement satisfies
`m.date.isBefore(from)` (`ledger_repository.dart:1325`), so Debit and Credit are zero and
only carry-forward balances print, labelled as the period's activity. The same expression
is the date-picker's `initialDateRange`, so the dialog opens invalid and rejects every
confirmation until hand-fixed. The button is labelled "This year"; the intent is clearly
the financial year.

---

### A5. Same-second edits between devices are dropped permanently **[v] [SILENT]**
`lib/core/sync/pull_applier.dart:204-205`

Drift stores `DateTime` as unix **seconds**. The merge rule is
`if (localAt != null && !pulledAt.isAfter(localAt)) return false;`

Two devices saving the same row within one second produce equal timestamps → the pulled
row is refused. The cursor still advances (`applyPage :113-114`), so the change is **never
re-fetched**. The books converge to whichever device wrote last locally, forever.

The same lines make the rule purely clock-based: a device whose clock is even slightly
fast wins every conflict permanently (`pull_applier.dart:227-247`), with no skew bound and
no log line.

---

### A6. GST 3.1(a) absorbs the exempt portion of every mixed-rate invoice **[v] [SILENT]**
`lib/core/reports/gst_return_builder.dart:548-556`

The nil-rated bucket is decided from **document totals**:
`if (doc.cgst == 0 && doc.sgst == 0 && doc.igst == 0 && doc.cess == 0)`.

An invoice with one 18% line and one exempt line has non-zero tax, so the entire
`doc.taxableValue` — exempt portion included — lands in 3.1(a), and 3.1(c) stays 0
forever. 3.1(a)/3.1(c) are *rate* buckets; the split must come from
`sales.itemsFor(doc.id)` filtered on `gstRate == 0`. The two figures stop reconciling
against portal Table 4.1.

---

### A7. GST payable differs three ways in one app; the dashboard can go negative **[v] [SILENT]**
`report_repository.dart:527-532`, `:608-630`, `:121` vs `gst_return_builder.dart:533-535`, `:608-610`

- `gstSummary` and `profitAndLoss` read only `docType:'invoice'`/`'bill'`. Sales **credit
  notes** and purchase **debit notes** are never read. GSTR-3B *does* subtract both
  (`addInward(dn, sign:-1)`, `addOutward(cn, sign:-1)`). Same month, three different
  numbers — and the P&L overstates income by every credit note and expenses by every
  debit note.
- `GstSummary.netPayable` is a raw `outputTax - inputCredit` (unclamped) while
  `Gstr3bReport.netPayable` floors at zero. The Dashboard KPI
  (`dashboard_screen.dart:686-693`) can therefore show **negative GST payable** in the same
  month where the return you file shows ₹0.00.

---

### A8. Payment Reminders lists invoices that are not yet due **[v] [SILENT]**
`lib/core/database/repositories/sales_repository.dart:549-562`

`watchOverdue()` filters `balanceDue > 0.001 AND dueDate IS NOT NULL` — **no
`dueDate < now` predicate**, contradicting its own doc comment on line 546. Every unpaid
invoice with a future due date is counted and summed as overdue, and
`payment_reminders_screen.dart:178` prints the negative day count literally ("-5d late").

`watchOverdue` (excludes `cancelled` + `converted`) and `totalOutstanding`
(`:852-860`, excludes only `cancelled`) also disagree.

---

### A9. "Duplicate" converts the source document **[v] [SILENT]**
`lib/features/sales/sale_editor_screen.dart:287`, `:631-635` + `document_row_menu.dart:238`, `:189`

Both *Duplicate* and *Convert to invoice* build the same `?from=` route
(`_duplicateRoute :262-269`). The editor sets `_convertSourceId = doc.id` for **any**
`?from=` and unconditionally calls `markConverted` after save (`:633`).

- Duplicating an **unpaid invoice** sets its status to `converted`, which drops it out of
  Payment Reminders (A8's query excludes `converted`) while `totalOutstanding` still counts
  it. No badge is shown for invoices (`sales_list_screen.dart:457-472` doesn't recognise
  the status), and the only feedback is "Invoice saved".
- Duplicating a quotation or sales order **kills its own Convert entry permanently**
  (`document_row_menu.dart:87-92` hides Convert for converted docs).

---

### A10. Barcode / SKU lookup is missing from the document line picker **[v] [SILENT]**
`lib/shared/widgets/item_type_ahead.dart:149-163`, `:97-99`

The type-ahead filters on `i.name.toLowerCase().contains(query)` only — never SKU, HSN or
barcode — then prepends an `isNew` "Save item" row whenever the exact *name* is absent.
`_commitFreeText` re-checks name-only and calls `onCreateItem`.

An EAN-13 scanned into an invoice line therefore creates a real catalogue item literally
named `8901234567890`, bypassing the actual product. Barcode lookup exists in POS
(`pos_screen.dart:255-283`), global search (`atria_global_search.dart:281`) and label
printing — this is the one place it is absent.

---

### A11. Android is offered a Windows-only transport, and the profile persists **[v]**
`lib/features/settings/printer_settings_screen.dart:592-596` + `printer_transport.dart:49`, `:162-166`

`PrinterTransport.values` is rendered with no platform filter, so "USB / installed printer"
appears on Android. `installedPrinterNames()` returns `const []` off-Windows, so the screen
says *"No installed printers were listed. Type the exact name Windows shows…"* and every
attempt fails with *"Printing to an installed printer only works on Windows."*

Because the profile is saved, a receipt printer configured on desktop and restored on
Android silently points at an unusable printer.

---

### A12. Successful firm restore gives no feedback and never navigates **[v]**
`lib/features/onboarding/firm_setup_screen.dart:342-366`

`_restoreFirm` ends with `onboardingDone.complete()` + `activeFirmId.select(...)` — no
`context.go`, no snackbar, no `setState`. Compare `_chooseDemo` (`:102`) and `_save`
(`:151`), which both `context.go('/dashboard')`.

The router's `refreshListenable` pulses only on `appInitializationProvider`
(`app_router.dart:63-65`, `:76`), which resolves once at boot — so flipping the flags does
not re-run `redirect`. The books just pulled in are never opened. The failure branch *does*
snackbar (`:349-352`), so the silent path is the successful one.

---

### A13. Scanning a bill creates a purchase that moves no stock **[v] [SILENT]**
`lib/features/purchase/purchase_editor_screen.dart:228-244` + `purchase_repository.dart:277`

`_applyScanSeed` fills name/HSN/unit/qty/rate/discount/GST/cess on each `_LineState` but
**never sets `line.itemId`**. The save path skips null-item lines outright:
`if (line.itemId == null || line.quantity == Money.zero) continue;`

The bill looks complete, appears in the list, and `currentStock` plus the stock ledger are
untouched. `bill_scan_screen.dart:400-591` offers no catalogue matcher either.

---

### A14. Editing a bill below what was paid writes a negative balance **[v] [SILENT]**
`lib/core/database/repositories/purchase_repository.dart:201-205`, `:219`

`final balance = grandTotal.toDouble() - paidAmount;` is stored unclamped. The other two
write paths *do* clamp (`applyPayment :544`, `_recomputeLinkedDoc :339`, both
`balance < 0 ? 0 : balance`). `paymentStatus` is derived from the unclamped balance, so it
still resolves to `'paid'`.

Repro: ₹10,000 bill → pay ₹10,000 → reopen → delete a ₹3,000 line → save. The list shows a
**Paid** chip beside **−₹3,000**, and `totalPayable()` (`:567-575`) nets the negative
against other suppliers.

---

### A15. Chrome menus push a second copy of the shell onto the root navigator **[v]**
`lib/shared/widgets/atria_top_bar.dart:100`, `:134`, `:266` + `dashboard_screen.dart:138`

Every chrome entry point that should *switch branch* uses `context.push`:

```dart
onPressed: () => context.push('/settings'),      // atria_top_bar.dart:100
onSelected: (route) => context.push(route),      // :134 (business switcher), :266 (account menu)
```

`/settings` is the **root of a `StatefulShellBranch`** (`app_router.dart:343-346`) and no
branch route sets `parentNavigatorKey` (grep: zero hits). go_router's
`RouteMatchList._createNewMatchUntilIncompatible` (`match.dart:602-620`) tests
`otherMatches.last is ShellRouteMatch` — but `otherMatches.last` is the `/settings`
`RouteMatch`, so the shell-reuse branch is skipped and line 619 appends the
`ImperativeRouteMatch` as a **top-level sibling of the `StatefulShellMatch`**.

Result: the pushed page is hosted by the **root** navigator, outside the shell — Settings
renders full-screen with **no nav rail and no bottom bar**, and Android Back returns to the
pre-push screen instead of behaving like a tab. Applies to `/settings`,
`/settings/firm`, `/settings/backup`, `/settings/audit-log` from both popup menus, and to
the duplicate Trial-balance / Balance-sheet entries (D3).

**Fix:** `goBranch(11)` / `go('/settings')`.

---

### A16. ~~Statements and invoices cannot paginate~~ — **RETRACTED (false positive)**

**Originally reported as Critical. It is wrong, and no restructuring was made.**

`pw.Table` is declared `class Table extends Widget with SpanningWidget`
(`pdf-3.12.0/lib/src/widgets/table.dart:250`). `SpanningWidget` is exactly the interface
`pw.MultiPage` uses to re-lay a too-tall child against the space left on each page and carry
its row cursor into the next page. Tables inside a `MultiPage` **do** paginate.

The premise was an unverified assumption that any over-tall `MultiPage` child overflows. That
holds only for non-spanning children. The finding survived a second-session re-verification
because both passes reasoned about the library instead of reading it.

What *was* real next door, and got fixed instead:
- `pw.MultiPage` defaults to `maxPages: 20` and throws `TooManyPagesException` past it. A busy
  party's full-year statement can exceed that, so `StatementExport._kMaxPages` is now 400 with
  the ceiling documented. (`invoice_pdf.dart` already used 100.)
- Both documents now carry a comment recording that the table DOES paginate, and the
  statement's closing block is placed so it lands on a fresh page rather than crowded by the
  ledger.

**Process note for the next audit:** any claim about a dependency's behaviour must be checked
against that dependency's source, not inferred. This one was confidently wrong twice.

---

## B. High

### Windows printing
| # | Finding | Where |
|---|---|---|
| B1 | **The whole app freezes while spooling.** `send()` is `async` but contains **no `await`** — `OpenPrinterW`, `StartDocPrinterW`, `WritePrinter`, `EndDocPrinter` all run on the UI isolate. `WritePrinter` blocks until the spooler accepts the job; a stalled driver, offline queue or paused job blocks indefinitely, and the `_busy` spinner (`printer_settings_screen.dart:918`) never gets a frame. Fix: `Isolate.run` | `printer_transport.dart:161-259` |
| B2 | **Network jobs get truncated.** `await socket.flush()` only drains into the kernel buffer; the `finally` then calls `socket.destroy()`, explicitly *not* graceful. The fixed 250 ms pause is nowhere near enough for a 100×100 mm label bitmap → clipped labels or a literal command tail. Fix: `await socket.close()` then `await socket.done` | `printer_transport.dart:96-117` |
| B3 | **Every spooler error message is the wrong error.** `late final _getLastErrorNative = DynamicLibrary.open(...)` is an *instance* field, so it initialises on first access — inside `lastErrorText()`, after the failing `OpenPrinterW`. `LoadLibrary`/`GetProcAddress` clobber the thread's last error. Also a fresh `_Spooler` per `send()` re-`LoadLibrary`s both DLLs per label and never `FreeLibrary`s | `printer_transport.dart:295`, `:342-344`, `:179` |
| B4 | `probe()` catches only `SocketException` while `send()` also catches `TimeoutException` — probing a firewall-DROPped port throws unhandled out of a `VoidCallback` | `printer_transport.dart:121-137` |
| B5 | `setState` called synchronously from `initState` → *"setState() or markNeedsBuild() called during build"* in debug | `printer_settings_screen.dart:420 → 440` |

### Sync / session
| # | Finding | Where |
|---|---|---|
| B6 | **Offline is reported as "signed out".** `_renew` returns `null` on a *transient* failure without clearing the session, but every caller collapses `null` → signed out. On a train: "Sign in to Atria to sync", the business-removal sheet disables the server option, and `AuthState.refreshing` is left `true` forever — the account card shows "Not signed in" *and* "Renewing this device's session…" simultaneously until something else calls `accessToken()` | `auth_controller.dart:157-171`, `:199-209`; `sync_engine.dart:252-259`; `firm_settings_screen.dart:1037-1055`, `:1187-1192` |
| B7 | **"Last synced" is stamped even when the push failed** — `kSyncLastSyncedAt` written on `pullError == null` with no reference to `pushReport.error`, while `providers.dart:113-115` states the opposite intent | `sync_engine.dart:374-380` |
| B8 | **Skipped pull rows vanish silently.** Unknown entity / FK orphan / column mismatch → swallowed to `debugPrint` (stripped in release), cursor advances past it, `PullApplyReport.skipped` is counted then discarded by every caller. No retry, no dead-letter, nothing in Settings | `pull_applier.dart:175-186`, `:65-67`; `sync_engine.dart:423`, `:531` |
| B9 | `expiresIn: 0` (or < 30) stores an already-past expiry → `ServerSession.current()` returns null immediately and every `accessToken()` rotates the refresh token again; with server-side rotation that is a self-inflicted sign-out loop | `auth_client.dart:205-221` |

### Data correctness **[SILENT]**
| # | Finding | Where |
|---|---|---|
| B10 | **Binned payments still reduce party outstanding.** `outstandingFor`'s `unlinkedPayments` query omits `isDeleted` while every sibling query in the same method filters it. The contract is stated at `payment_repository.dart:208-211` | `party_repository.dart:301-306` |
| B11 | **Items list hard-capped at 1000 with client-side search over that cap.** The box says "Search name, SKU, HSN or barcode" and returns "No matching items" for anything past row 1000. The repository's SQL `LIKE` search is correct and unbounded; the screen bypasses it | `items_screen.dart:31-62`; `item_repository.dart:119-126` |
| B12 | **Duplicate on an item can never be saved** — `_prefillDuplicate` clears the name but leaves the source's SKU and barcode, so the uniqueness check always aborts | `item_editor_screen.dart:175-184`, `:296-350` |
| B13 | **Parties "Outstanding" column never refreshes** — the `Future` is cached per row state and the screen lives under an `IndexedStack`, so even a rebuild hands `FutureBuilder` the same completed `Future` | `parties_screen.dart:304-317` |
| B14 | **Party editor Save silently no-ops with no firm open** — `repository?.create` → null → `context.pop(null)`, no error. Reachable from the global Create ▸ Customer menu | `party_editor_screen.dart:276-299`, `:338` |
| B15 | **GSTR-1 drops every export/SEZ invoice entirely** — `if (doc.isExport) continue;` removes them from B2B/B2CL/B2CS, there is no EXPWP/EXPWOP table and no shipping-bill entry in `docIssue`. GSTR-3B *does* report them as 3.1(b) | `gst_return_builder.dart:46`, `:244-247` |
| B16 | **GSTR-1 HSN table has no rate field and merges different rates** — `_HsnAccum` is keyed on the HSN string alone and `Gstr1Hsn` has no rate property, so `rt` is never emitted (every other table does, `gstr1_report.dart:339`). Table 12 requires it; the offline utility rejects the file. `qty` is also signed, so a credit note emits a negative quantity | `gst_return_builder.dart:194-239`; `gstr1_report.dart:71-83` |
| B17 | **CDNUR emits the structure its own comment says is rejected** — the class doc says raw rate rows are rejected and the note's own number/date/value belong in one wrapped `itm_det`, but `toJson()` emits `itms` whenever items exist. `buildGstr1` always supplies items, so every row ships the wrong shape | `gstr1_report.dart:205-206` vs `:258-280` |
| B18 | **`_categoryCode` matches accounts by name with no type filter** — create an *asset* account named "Rent" and every `rent` expense posts its debit there: cost vanishes from the P&L, assets inflate, books still balance so the trial-balance banner stays green. The sibling `accountForCategory :451` *does* filter on type | `ledger_repository.dart:1289-1298` |
| B19 | **Row-kebab "Receive Payment" writes an over-sized payment** — no cap against `balanceDue` (the detail screen caps and warns). `applyPayment` clamps internally, so the ledger records ₹2,000 against a ₹1,000 invoice while `paidAmount` moves ₹1,000, and the SnackBar reports success | `document_row_menu.dart:369-399` |
| B20 | **The payment amount field goes stale after a partial payment** — `_PaymentSectionState` has `initState` and `dispose` but **no `didUpdateWidget`**. Record ₹400 of ₹1,000 → the field still reads 1,000.00 → tapping Record takes the whole remaining balance | `sale_detail_screen.dart:1070-1096` |
| B21 | **`watchList(limit: 1000)` truncates silently** and the stream orders by date with no secondary sort, so past 1000 bills the totals card is simply wrong | `purchase_list_screen.dart:162`; `purchase_repository.dart:501-520` |
| B22 | **`reverseStockForSource` re-reverses its own reversal rows** — the reversal rows carry the same `sourceId`, so each call posts the opposite of each. Net stock is preserved but the movement table doubles per cycle: 2ⁿ phantom rows in "the stock ledger of record" | `sales_repository.dart:922-958` |
| B23 | **Editing a cheque's mode leaves `chequeStatus` stale and unmanageable** — `update()` writes it from the *existing* row regardless of the new mode, so cheque→cash stays `pending` (counted in both buckets, and `_ChequeMenu` is gated on `mode == 'cheque'`), and cash→cheque never enters `watchUnclearedCheques()` | `payment_repository.dart:94-112`, `:55` |
| B24 | **The `_setChequeState` guard documented at `:446-448` does not exist** — only `mode != 'cheque'` is checked, and the menu gates only `deposit` on `status == 'pending'`, so `clear` and `bounce` are offered from every state. A settled cheque can be reversed by a second tap | `payment_repository.dart:449-471`; `payments_screen.dart:657-662` |

### UI/UX
| # | Finding | Where |
|---|---|---|
| B25 | **The top-bar `Row` overflows for windows ≈840–944dp with a firm name over ~22 chars.** Every child except the `Spacer` is non-flex: rail 236 + switcher + label (capped 220) + search 300 + buttons ≈ 724 + labelWidth. `wide` turns the 300px search on at ≥720dp, so at 900dp only ~176px of label fits. **The app's own 1280px default window is 853dp at 150 % OS scaling — inside the band** | `atria_top_bar.dart:56-106`; `windows/runner/main.cpp:29` |
| B26 | **`navEntryIsActive` prefix-matches sub-paths, so the rail highlights wrong rows.** Line 77 is unreachable for any sub-path, so the comment at `:75-76` is not implemented. `/settings/firm` highlights **Settings** as well as Company profile; `/ledger/trial-balance` highlights **Chart of accounts** *and* both Trial-balance rows *and* Balance sheet — four simultaneous highlights | `adaptive_nav_shell.dart:69-84`; `nav_destinations.dart:362`, `:399` |
| B27 | **`_CompactRail` is 32 unlabelled, un-tooltipped icons with no section headings** — `showLabel: false` drops the `Text` and leaves a bare `Icon` with no `Tooltip` or `Semantics`. Used for every width 600–839dp. Includes near-identical glyph pairs (`scales` for Trial balance, `books` for Balance sheet, `clipboardText` twice) | `adaptive_nav_shell.dart:489-536` |
| B28 | **No minimum window size and no `WM_GETMINMAXINFO`** — the window can be dragged to ~200×100. Below ~256dp the top bar overflows; below 52dp height the shell's bare `Column` throws a vertical RenderFlex; below ~114dp the bottom `NavigationBar` overflows | `main.cpp:29-30`; `win32_window.cpp:181-219` |
| B29 | **Expense delete throws unhandled** — `RowAction.onSelected` is a `VoidCallback`, so the async `softDelete` future is dropped and `PeriodLockedException` surfaces nowhere. Swiping dismisses the row and it then reappears | `expenses_screen.dart:376-384`; `transaction_list.dart:234` |
| B30 | **Party opening-balance and credit-limit fields use `TextInputType.number`** — no `.` key on the Android keypad, so paise cannot be entered. The lone outlier; item/expense/line fields all use `numberWithOptions(decimal: true)` | `party_editor_screen.dart:659`, `:702` |
| B31 | **The line grid's delete control is hover-only** — `onRemove: _hovered ? row.onRemove : null`. There is no way to delete a line on any touch device at ≥840dp (Android tablet landscape, Windows touch laptop) | `atria_line_grid.dart:192-205`, `:249-256` |

---

## C. Platform-specific matrix

### Android-only
| Finding | Detail |
|---|---|
| **GSTR-3B and FY exports are unreachable** | `gst_reports_screen.dart:483-505`, `:512-558` — both write into `getApplicationDocumentsDirectory()` = `/data/user/0/com.atria.atria/app_flutter`, which no file manager or document picker can reach. Only the GSTR-1 tab calls `OpenFilex.open`; 3B and the FY summary show a snackbar with a path and offer **no way to open or share the file at all**. For the one artifact a shopkeeper must upload to the portal, the Android build is unusable. (The same code lands in visible `Documents\atria\gst\<GSTIN>\<fp>` on Windows.) |
| **Export help text is wrong on both platforms** | `gst_reports_screen.dart:341-347` states `Documents\atria\gst\<fp>` with backslashes — and omits the GSTIN level that `_periodDir` actually inserts (`gst_export_service.dart:255-261`) |
| **`http://` dev override cannot work** | `api_config.dart:107-112` permits cleartext only for loopback, but the manifest sets no `usesCleartextTraffic`/network-security-config, so even `http://localhost:8090` is blocked on Android. `localhost` on a handset is the handset anyway |
| **No camera barcode scanning on any platform** | `simple_barcode_scanner: ^0.6.0` is a runtime dependency at `pubspec.yaml:71` imported by **nothing** in the repo. POS depends entirely on a keyboard wedge (`pos_screen.dart:261`) |
| **The soft keyboard opens over POS on arrival** | `pos_screen.dart:529` `Focus(autofocus: true)` + `:573` `paneHeight = constraints.maxHeight * 0.55` ignores `MediaQuery.viewInsets.bottom`. The screen opens with the IME raised and "Complete sale" invisible. Desktop unaffected |
| **Payment sheet overflows at 360dp + keyboard** | `payments_screen.dart:936-1053` — `isScrollControlled: true` with a `Column(mainAxisSize: min)` and **no scroll view**: SegmentedButton + Autocomplete + Amount + Mode + Reference + Notes + Save ≈ 470–490dp plus `viewInsets.bottom`. Nothing scrolls, Save is off-screen |
| **GSTR-2A import assumes the picker returns bytes** | `gst_reports_screen.dart:459` `utf8.decode(picked.files.single.bytes!)` — above file_picker's in-memory threshold `bytes` is null and `path` is set, so a large portal export fails with `Null check operator used on a null value` |
| **`OpenFilex` failure overwrites a success message** | `gst_reports_screen.dart:490-502` — `setState('Saved to …')` then `await OpenFilex.open(…)` inside the *same* `try`. With no `.json` handler the catch replaces it with "Export failed", so users retry a successful export |
| **Whole-file reads through the platform channel** | `backup_restore_screen.dart:91-95`, `vyapar_import_screen.dart:57-61` — `withData: true` pulls the entire file into RAM (a `.vyb` is a ZIP of a whole SQLite DB) and `vyapar_import_screen` holds it for the screen's life. OOM on mid-range Android |
| **App name is lowercase "atria"** | `AndroidManifest.xml:9` `android:label="atria"` |
| **Sync timer never pauses when backgrounded** | `app.dart:45-58` — a 60 s `Timer.periodic` with no `AppLifecycleListener`/`WidgetsBindingObserver` |

### Windows-only
| Finding | Detail |
|---|---|
| **Vyapar import leaks an unencrypted copy of the books** | `vyapar_backup.dart:439-457` — the temp `vyapar.vyp` is deleted in a `finally` **while sqlite3 still holds the file open**. The comment claims "safe on every platform we ship"; on Windows the handle blocks deletion, the exception is swallowed at `:454`, and the full customer database is left in `%TEMP%` after every import. `read()` disposes the handle at `:387`, too late |
| **App name is lowercase "atria"** | `main.cpp:30` `window.Create(L"atria", …)`; `Runner.rc:92-98` `FileDescription`/`InternalName`/`ProductName` all `"atria"`. Task Manager, title bar, file Properties |
| **Default window size is inside the top-bar overflow band** | `main.cpp:29` `Size(1280, 720)` is *physical* px, scaled by DPI → 853dp at 150 % scaling |
| **No minimum window size** | see B28 |
| **All print-path defects** | see B1–B5 |

### Both
| Finding | Detail |
|---|---|
| **Text scale hard-clamped at 1.15×** | `app.dart:127-129` — `MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15)`. Android's font-size setting goes to 2.0×; everything above 115 % is silently discarded. WCAG 1.4.4 failure, and Windows has no other scale knob |
| **Android system back is unhandled outside `UnsavedGuard`** | Only `unsaved_guard.dart` uses `PopScope` in the entire app. See A1 for the trap; note there is no global back handling for the sheet/dialog cases |
| **Every money column is `RealColumn`** | `sales_invoices.dart:27-60` and siblings store IEEE-754 doubles while all computation is `Decimal`. Hence the scattered `toStringAsFixed(2)` patches and `> 0.001` epsilons throughout |
| **No `onDowngrade` in the migration strategy** | `app_database.dart:54-137` — a downgraded install runs against a newer schema with no guard |
| **`DocumentNumbering.parseSequence` returns the wrong number** | `document_numbering.dart:95-107` — for `INV/2025-26/001` it returns **2025** (the FY), not 1. Currently dead code; the doc comment claims the seeder and diagnostics use it |

---

## D. Medium

**GST / reports**
- D1. Statement filenames collide — `statement_<party>_<today>.<ext>` has no period, so two periods exported on the same day silently overwrite (`statement_export.dart:374-376`). `csv_export.dart:162-166` correctly uses minute resolution.
- D2. Reconciliation CSV totals row is written under the wrong headers — `['Totals','', booksTotalTax, portalTotalTax]` under `['Invoice No','Status','Books Taxable','Books Tax','Portal Taxable','Portal Tax']`, so books tax prints under "Books Taxable" and "Portal Tax" is blank (`gst_export_service.dart:106-119`).
- D3. GSTR-3B ITC reversals are floored at zero — a month where debit notes exceed bills reports **more** ITC than was available; Table 4(B) is hardcoded 0 so it is invisible (`gst_return_builder.dart:643`, `:646`).
- D4. GSTR-2A "Books ITC" ignores purchase debit notes, so it contradicts GSTR-3B 4(A)(5) for the same period; `inwardNonGst` is declared, never incremented, exported as a hardcoded 0 (`gst_return_builder.dart:797-812`, `:588`).
- D5. Next-month arrow on GST Reports is unbounded — you can page into a future month and export a return for a period that has not happened (`gst_reports_screen.dart:108-116`).
- D6. Export buttons promise Excel; only CSV and JSON are ever written (`gst_reports_screen.dart:312-314` vs `gst_export_service.dart:16-17`).
- D7. `This Quarter` re-queries the whole books on every rebuild — `_range` returns `now` for an unfinished quarter, so `_DateRange` compares unequal on every rebuild (`reports_screen.dart:99`).
- D8. `Sales vs Purchases` and `Stock Summary` show the previous firm's data after a firm switch — `late final _future` with no `didUpdateWidget`; all five sibling cards *do* check (`reports_screen.dart:1224`, `:2118`).
- D9. Overdue-invoice alert is silently scoped to the selected month, while `lowStockCount` beside it is all-time and `receivable` is lifetime — one card, three windows (`report_repository.dart:351-358`).
- D10. Statement .xlsx writes Debit/Credit/Balance as Indian-grouped text via `TextCellValue`, so Excel sees strings — no SUM, no chart. `csv_export.dart:45-47` deliberately does the opposite; the two exporters disagree (`statement_export.dart:338-345`).
- D11. GSTR-3B screen omits 3.1(c), 3.1(d) and all of Table 5, so `netPayable` contains an invisible cash-RCM component (`gst_reports_screen.dart:280-305`).
- D12. Raw `'$e'` / `'${snapshot.error}'` is still surfaced on **every** report error path — `reports_screen.dart:503`, `gst_reports_screen.dart:167,183,397-399`, `ledger_reports_screen.dart:77,161,265`, `chart_of_accounts_screen.dart:114`, `journal_list_screen.dart:79`, `dashboard_screen.dart:353,635,812,1167`, plus export catches. A `FileSystemException` path can appear as the *status line* of a successful-looking screen.

**Ledger**
- D13. Editing an account can flip its type, silently unbalancing the balance sheet — nothing checks whether the account already carries postings, and `BalanceSheetGroup.total` negates (`chart_of_accounts_screen.dart:568-583`; `ledger_repository.dart:584-598`, `:169-175`).
- D14. Account-ledger opening/closing rows use flex `7/4` while the header and movement rows use `2/5/2/2/2`, so the figures sit ~25 % of the row width right of the running-balance column (`ledger_reports_screen.dart:760-827`).

**Sales / purchase**
- D15. `/sales/new?party=<id>` is a dead deep link — the preset is overwritten by `_selectParty(_parties.first)` (`sale_editor_screen.dart:231-237` vs `:338-342`).
- D16. A new invoice silently pre-selects the alphabetically-first customer while the comment claims "last-used", then resets `_dirty` so the guard never warns (`:339-342`, `:350`).
- D17. TCS % never marks the form dirty — `_tcsRateController` is absent from `_markDirty`'s four controllers and `onChanged` only calls `_recalc()` (`:181-188` vs `:1519-1527`).
- D18. Editor prints "SGST" for UT firms — `editor_totals.dart:221-223` hardcodes it, though `intraStateSecondHead()` exists (`gst_engine.dart:33-34`) and the detail screen uses it.
- D19. Share fires WhatsApp *and* the system share sheet — `launchUrl`'s result is discarded and `Share.shareXFiles` runs unconditionally (`sale_detail_screen.dart:266-280`).
- D20. Moving the invoice date forward leaves the due date in the past — `firstDate: invoiceDate` only constrains new picks, nothing re-clamps `_dueDate` (`sale_editor_screen.dart:1015-1018`).
- D21. Debit notes and purchase orders permanently read "Unpaid" beside a ₹0 balance, and a purchase return adds no credit — a ₹10,000 return against an unpaid ₹30,000 bill leaves the supplier at ₹30,000 (`purchase_repository.dart:201-205`, `:219`; `purchase_list_screen.dart:409-416`).
- D22. `softDelete`/`restore` have no `isDeleted` state guard — `softDelete` on an already-binned bill reverses stock again, `restore` on a live bill re-posts it. The invariant rests entirely on the UI hiding the action (`purchase_repository.dart:311-316`, `:343-347`).
- D23. Bill-scan: `dueDate`, `shippingCharge` and `otherCharges` are seeded into the bill but have **no review field**, so they land unexamined (`bill_scan_screen.dart:707-732`; `purchase_editor_screen.dart:174-179`).
- D24. Bill-scan line-number fields desync after a deletion — unkeyed `TextFormField(initialValue:)` with positional state retention, so surviving cards show one line's numbers against another's state (`bill_scan_screen.dart:491-492`, `:576-591`).
- D25. Bill-scan shows a red "Not a valid GSTIN format" under an untouched empty field when the model read none (`bill_scan_screen.dart:423-425`).
- D26. Bill-scan `_reviewField` allocates a `TextEditingController` per build and never disposes it; the caret is forced to the end on every keystroke (`:456-459`).

**POS / payments**
- D27. POS `_submitSearch` has no generation guard — two scans inside one DB round-trip can land out of order and add the wrong SKU (`:261-298`).
- D28. POS has no destructive confirmation anywhere — `_clearCart` wipes party + paid state + every line on one tap, the `−` stepper deletes a qty-1 line outright, and `IconButton(Icons.x)` removes with no confirm. This is a live till (`:161-185`, `:699-703`, `:795-817`).
- D29. Balance cards read ₹0.00 while loading — `cashBankBalancesProvider` is an async* `StreamProvider` and `valueOrNull ?? const CashBankBalances()` renders a hard zero with no spinner, so the first paint says the shop has no cash. Being `autoDispose`, it re-flashes on every tab return (`payments_screen.dart:105-107`; `providers.dart:425-443`).
- D30. Empty states ignore an active search on Payments (`payments_screen.dart:232-248`) — the branch tests only `_range.isAllTime`. `purchase_list_screen.dart:225-239` gets it right, so the two lists disagree.

**Items / parties / stock**
- D31. **State code 97 (Other Territory) can never validate** — the dropdown offers it (`indian_states.dart:51`), the GSTIN regex admits only `00-38` (`validators.dart:14-16`), and `gstinStateMismatch` compares the first two digits, so picking 97 gives a permanent unresolvable error.
- D32. Custom segmented pills are `GestureDetector`-based: ~35dp tall and **no focus node**, so on Windows they cannot be reached by Tab or toggled with Space/Enter (`party_editor_screen.dart:747-804`; `party_statement_screen.dart:151-181`).
- D33. Invoice editor's item list silently shrinks 2000 → 1000 the moment the watch stream first fires, so an existing item past row 1000 reads as "not found" and committing its name creates a duplicate (`sale_editor_screen.dart:211-222`, compounding A10).
- D34. "Selling below cost" blocks the save despite its comment saying it shouldn't — it is returned from a `validator`, so clearance/loss-leader stock cannot be saved (`item_editor_screen.dart:739-757`).
- D35. Item preview header adds GST to inclusive-tax prices and never applies cess, so the figure is overstated and the `TaxModeToggle` beside it changes nothing (`item_editor_screen.dart:1152-1153`).
- D36. Stock adjustment is written outside a transaction — the movement insert and the `currentStock` update are two separate writes (`stock_screen.dart:106-115` vs `item_repository.dart:255`).
- D37. Stock adjustment picker is an unsearchable dropdown of up to 1000 rows, and negative counted quantities are accepted with no `counted >= 0` check (`stock_adjustment_dialog.dart:72-89`, `:102-106`).
- D38. Custom units vanish from the line-grid unit picker after one change — `AtriaUnitPicker.items` enumerates `Unit.standard` only (`atria_line_grid.dart:638-647`).
- D39. Statement of Account silently loses parties past 500, and a deep link to one renders a blank white area with both download buttons disabled (`statement_of_account_screen.dart:55-68`, `:339`).
- D40. Type-ahead resolves by name equality only, so two items differing by case or trailing text are indistinguishable and the first always wins (`sale_editor_screen.dart:768-777`; `purchase_editor_screen.dart:752`).

**Responsive / platform**
- D41. Top-bar Create button in the icon rail is an **18×38dp** tap target for the app's primary create affordance on every 600–839dp window (`atria_create_menu.dart:184-200`).
- D42. Dashboard's column split uses `MediaQuery.sizeOf(context).width >= Breakpoints.medium` — the **window** width — while the shell has already removed 236+1dp for the rail at the same threshold. `AtriaEditorForm` correctly uses `LayoutBuilder` for exactly this reason (`dashboard_screen.dart:74`, `:159-179` vs `atria_form_section.dart:264-275`).
- D43. Non-scrollable pill rows lose ~58dp per pill to chrome at 360dp, leaving ~51dp for the label — every label degrades to `…`. Used by Items, Stock, Payments and Parties (`atria_list_toolbar.dart:62-68`, `:111-141`).
- D44. `AtriaResultsBar` has no `Flexible`/ellipsis on either text, so a 7-digit count plus a period total overflows a 360dp phone (`atria_list_toolbar.dart:192-233`).
- D45. GSTR-2A reconciliation chips sit in a bare `Row` with no `Wrap` — four ~120–150dp chips ≈ 550dp in 328dp. Guaranteed overflow on every phone (`gst_reports_screen.dart:387-394`).
- D46. Period-lock action row is a bare `Row` of two labelled buttons needing ~300dp in 296dp available at 360dp, at the 1.15 scale the app permits (`period_lock_and_audit_screens.dart:177-200`).
- D47. `_BottomShell` chrome suppression misses `/ledger/account/:id`, so the account ledger keeps the top bar and bottom bar while every sibling pushed route drops them (`adaptive_nav_shell.dart:97-105`).
- D48. Onboarding footer is a transparent overlay above the scrolling page — mid-scroll text passes behind the indicator row and Next button (`onboarding_screen.dart:112-117`, `:158-199`).
- D49. `editor_shell.dart:58,108,233` read `MediaQuery.sizeOf(context).width` instead of the pane — benign today because the thresholds coincide, but it breaks the moment they diverge.

**Forms / misc**
- D50. `Validators.phone` rejects anything but exactly 10 digits, contradicting `WhatsAppLinks.normalize`, which was written specifically to accept `+91` and `0`-prefixed forms. `+91 98765 43210` cannot be saved (`validators.dart:102-110` vs `whatsapp_links.dart:8-18`).
- D51. Firm Profile cannot clear any optional field — `fieldValue()` returns `Value.absent()` for empty input, so `copyWith` + `db.update(...).replace(...)` writes the old value back. All 19 columns are nullable. **You can never remove a wrong GSTIN or a former phone number.** Same for the logo: "Remove" never removes (`firm_settings_screen.dart:244-247`, `:252-281`).
- D52. Firm logo rename orphans the old file — `dest = 'firm_logo.$ext'` is a fixed basename (`firm_settings_screen.dart:466`).
- D53. `File(path).existsSync()` runs in `build()`, and `_prefixField.onChanged` calls `setState(() {})` per keystroke, so every character typed in any prefix field does a synchronous disk stat on the UI thread (`firm_settings_screen.dart:397`, `:1317-1320`).
- D54. `NumberToWords` throws `RangeError` for any total ≥ ₹100 crore — `_twoDigit(100+)` indexes `_tens[10+]` (`number_words.dart:96-101`).
- D55. Barcode Code128 is unguarded — a barcode with non-ASCII or an over-long payload throws out of the label PDF (`barcode_labels.dart:61-67`).
- D56. Every period end is `23:59:59`, excluding rows stamped `23:59:59.001`–`23:59:59.999` (`reports_screen.dart:82`; `ledger_repository.dart:977`; `gst_reports_screen.dart:22-23`; `period_selector.dart:234`).
- D57. `edit_round_trip`: editing a saved document and saving again leaves `paidAmount`/`paymentStatus` derived rather than reset — correct, but worth a regression test since a negative-balance edit is currently reachable (A14).
- D58. `_purgeAll` force-unwraps the active firm *after* the dialog and aborts on the first non-`StateError`, so a partial purge reports a misleading "Purged N" (`settings_screen.dart:297`, `:309-311`).
- D59. Period **lock** — the destructive direction — has no confirmation, while unlock does. The asymmetry is backwards (`period_lock_and_audit_screens.dart:44-77` vs `:79-101`).
- D60. The server-address field writes one SQLite transaction per keystroke (DELETE+INSERT each), and an invalid URL is displayed but not saved, so the field can show an address the app won't use (`settings_screen.dart:1355 → 1437 → 1473-1489`).
- D61. Recycle-bin confirmation loads every deleted row into memory six times, twice (`settings_screen.dart:199-230`, `:322-345`).
- D62. `DropdownButtonFormField(initialValue:)` for the printer queue is decided before the async list arrives, so a configured queue shows unselected (`printer_settings_screen.dart:641-644`).
- D63. Vyapar preview is labelled "Importing…" and can run for minutes with no cancel and no `PopScope` (`vyapar_import_screen.dart:86`, `:212-213`).

---

## E. Low (grouped)

- **Hit targets under 44dp:** `_SectionRow` ≈38dp ×32 rows (`adaptive_nav_shell.dart:419-453`); `AtriaHeaderIconAction` 34×34 (`atria_page_header.dart:194-201`); `AtriaTaxModePill` ≈26dp (`tax_mode_toggle.dart:88-102`); header back button 36×36 (`atria_page_header.dart:76-82`); `PopupMenuItem(height: 40)` (`document_row_menu.dart:118`); search clear button 38dp (`transaction_list.dart:203-215`).
- **Duplicate nav entries:** "Trial balance" and "Balance sheet" are each listed twice, in REPORTS and ACCOUNTING, with identical label/icon/route (`nav_destinations.dart:344-353`, `:370-379`). The REPORTS copies have no `branchIndex`, so they take the `context.push` path — A15's cross-branch bug for a route inside `/ledger`.
- **Stale async state:** `setState() called after dispose()` when backing out during the party load (`sale_editor_screen.dart:206-238`, `:341`, `:388`; `purchase_editor_screen.dart:148-161`). `_itemsSub`/`_lines` can be assigned after `dispose()` and leak — the listener is `mounted`-guarded so it won't crash, but the drift watch is never cancelled.
- **Uncancelled debounce on clear:** type "abc", hit ✕ within 250 ms → the pending timer resurrects the stale term and the list shows `No matches for "abc"` with an empty box (`sales_list_screen.dart:129-132`; `purchase_list_screen.dart:61-67`).
- **Keyboard/Enter contract:** `advance()` is wired only to qty/rate/discount, so Enter on the **Item** cell commits free text and stops, and the **HSN** cell swallows it. `Escape` exits the editor while the type-ahead list is open (`sale_editor_screen.dart:984`; `atria_line_grid.dart:75` vs `:780-785`; `item_type_ahead.dart:169`; `save_shortcut.dart:44`).
- **Leaked controllers:** `_receivePayment`'s `TextEditingController` (`document_row_menu.dart:288-292`); five controllers plus an uncancelled stream per payment-sheet open/close, and `setSheetState` firing after dismiss (`payments_screen.dart:808-822`, `:916-924`).
- **Copy/label bugs:** sale-detail headline hardcoded "Total invoice value" on a sales order/DN/credit note (`:492`); share text "here is your quotation" for a credit note (`:258`); `StatusChip.payment` shows "Unpaid" on a quotation (`:508`); delivery_note/credit_note tabs fall through to "No invoices yet" (`sales_list_screen.dart:342-372`); results count excludes cancelled rows that are still rendered (`:328-329`); category printed twice on vendor-less expense rows (`expenses_screen.dart:355-362`); SnackBarAction reads "Open folder file" (`settings_screen.dart:173`).
- **Missing platform affordances:** no right-click/context menu on rows — `transaction_list.dart` exposes `onSecondaryTap` but `sales_list_screen.dart:556-583` passes neither, so right-click on a Windows sales row does nothing. No hover on the icon rail (B27). No delete on item tiles (`items_screen.dart:487-520`).
- **Async-gap hygiene:** `context.push`/`OpenFilex.open` inside `SnackBarAction.onPressed` with no `context.mounted` (`settings_screen.dart:134-135`, `:174`); `_confirmCancel` uses `ref`/`_invoice` after the dialog with no `mounted` (`sale_detail_screen.dart:407-409`); `setState` after `await` in the GST export path (`gst_reports_screen.dart:493`, `:501`, `:552`); sale save returns `false` silently when repo/firm is missing (`sale_editor_screen.dart:501`).
- **Dead code / stale comments:** `EditorActions.onExit` declared and never read (`editor_shell.dart:28`); dead `share` parameter (`document_row_menu.dart:442-446`); `EditorTotals._grandRateLabel` half-rate (A18/D18 adjacent); stale `app_theme.dart:485-487` comment; `breakpoints.dart:25` says "coarsest" but returns the most specific; `NavDestinations` comment drift.
- **Misc:** `BouncingScrollPhysics` on Android (`onboarding_screen.dart:143-145`); `AtriaListPage` is only valid inside a bounded-height `Column` (`atria_list_page.dart:135-142`); stock-movement sheet always occupies 72 % of the window (`stock_screen.dart:146-150`); parties master-detail splash not clipped to the rounded row (`parties_screen.dart:324-339`); `/payment-reminders` is unreachable from global search and not in `NavDestinations.sections`; audit-log filter omits `recycle_bin`/`journal_entries`/`accounts` so the `purge` action can't be filtered to; rate-wise GST table can total ₹0 next to non-zero output tax (`reports_screen.dart:966-976`).

---

## F. Verified correct — do not re-audit

**Navigation**
- `initialLocation: '/boot'` does not defeat Android relaunch — `GoRouter._effectiveInitialLocation` returns the platform default whenever it isn't `/`, so `launchLocation` stays live; `resolveOnboardingRedirect` has no cycle; `errorBuilder` is wired.
- `/pos` and `/payment-reminders` are legitimately outside the shell and do not duplicate it.
- `NavDestinations.branches` matches the router's 13 `StatefulShellBranch`es 1:1; `bottomBarItemCount = 5` partitions correctly; the More sheet's filter keeps branch roots ≥ 5.
- The More sheet reads `GoRouterState` in the shell's context (not the builder's) and pushes from a captured `shellContext` — the Android blank-sheet bug is genuinely fixed.
- Rail footer overflow is genuinely fixed.

**Money / accounting**
- All editor math is `Decimal` end to end; `_apportionInvoiceDiscount` keeps line taxables summing exactly to the discount under largest-remainder; `_splitTax` makes intra-state halves sum exactly; `_lineDiscount` clamps to `[0, gross]`.
- The **P&L net-profit double-count is genuinely fixed** (`report_repository.dart:672-685`), and the visible rows reconcile (`purchaseTaxable + opening − closing == COGS`, `:647`).
- **Archived-account journal bug is fixed on both sides** — `chartOfAccountsProvider` uses `includeArchived: true` and the journal editor re-adds archived accounts referenced by existing lines; `_book` loads all accounts so archived ones keep their balances.
- Trial-balance/balance-sheet arithmetic is sound: negative sides normalised, 0.005 balance tolerance enforced, `opening`/`running` kept separate, income/expense folded into `netProfit` so `Assets − (Liabilities + Equity)` is genuinely zero.
- `_Postings.post` and `accountLedger` carry-forward verified against the repositories' un-normalised `to` comparisons — no double counting.
- GSTIN (15-char structure, `00-38` state, PAN entity class, mod-36 check digit), PAN and HSN/SAC validation are correct. The Flutter SDK's `autocomplete.dart:475-512` confirms `optionsBuilder` output is *not* re-filtered by `displayStringForOption`, so the HSN field is fine.
- `IndianAmountInputFormatter` round-trips commas, caps decimals, strips signs; `Money.tryParse` strips `₹`/spaces/commas; `Formatters.indianGroup` produces correct Indian grouping. No Western/Indian mismatch anywhere.
- `GstEngine` `NumberingStyle` formats, `FinancialYear.forDate`, round-off and period-lock re-assertion in `applyPayment`.
- `NumberToWords` lakh/crore decomposition is correct below ₹100 crore.
- CSV escaping correct in both writers (quote-when-needed with doubled `"`; quote-all + UTF-8 BOM). No separator injection, no thousands separators in the CSV path.
- UPI QR failure degrades gracefully — `upi_qr.dart` catches and `invoice_pdf` gates, so an unencodable payload omits the QR rather than failing the document.
- `InvoicePdf` per-line rate labels (`gstRate / 2`) are correct — unlike `editor_totals`.
- Document numbering in GSTR-1 doc-issue is integer-safe (`INV-9` before `INV-10`).
- Stock: `create` seeds `currentStock: 0` and posts opening via the ledger — no double count; services/untracked consistently excluded from `stockSummary`/`stockValue`/`_computeStats`.
- `partyStatement` opening + prior-period carry-forward is correct against the un-normalised `to` comparisons.
- POS cart/totals use `Decimal` throughout; `PaymentRepository.create` runs `onLinked` inside the transaction; period locks are re-asserted.
- Firm purge is complete — `journalLines` is covered by `ON DELETE CASCADE` (`tables/ledger.dart:107`), verified not an orphan.
- Archive/restore cascades, `deleteForever` refusal for in-use rows, and unique-constraint surfacing as snackbars are all correct.

**Infra**
- **Backup export null-column bug is genuinely fixed** — `_rowToMap` reads `Variable.value` off `toColumns(true)` and throws `StateError` rather than emitting null; `_sqlValue` converts ISO↔seconds and bool↔0/1.
- Hollow-journal repair is genuinely fixed — confirm dialog, deterministic idempotent ids, immediate push, honest report including the `enqueued == 0` case.
- Scan-gateway retry and error surfacing are genuinely fixed; gateway errors carry the status and the server's own message.
- No `SharedPreferences` and no `flutter_secure_storage` anywhere; the four token keys live only in Drift and are documented as plaintext with the DPAPI/Keystore upgrade named. **No token is ever passed to `print`/`debugPrint`.**
- `normaliseBaseUrl` rejects plaintext http for any non-loopback host and strips credentials from the URL. No hardcoded hosts or ports.
- Android `INTERNET` is in the **release** manifest, not just debug/profile; `exported="true"` + single LAUNCHER intent-filter correct; `adjustResize` set; `configChanges` covers `fontScale`/`uiMode` so a theme flip doesn't restart the activity; `values-night/styles.xml` keeps the launch window dark. **No `POST_NOTIFICATIONS`/CAMERA is needed** — there are no local notifications and `file_picker` uses `ACTION_IMAGE_CAPTURE` via the system camera app (`file_picker-8.3.7` declares no permissions).
- `url_launcher` on Android 11+ package visibility is **not** a problem — it calls `startActivity` directly, no `resolveActivity`, so no `<queries>` entry is required.
- Windows DPI: `PerMonitorV2` in the manifest, `WM_DPICHANGED` handled, fonts reloaded on `WM_FONTCHANGE`.
- Every export path creates its directory tree with `createSync(recursive: true)` — no missing-subdirectory failure on either platform.
- Vyapar ZIP extraction is **not** vulnerable to ZipSlip — it picks the `.vyp` entry and writes it to a temp file under a fixed name, never extracting by entry name. (A1 in the agent pass suggested otherwise; inspection shows the code is safe.)
- `AtriaEditorForm` / `AtriaSectionColumns` / `AtriaFormFieldRow` all use `LayoutBuilder` and degrade monotonically — no fixed pixel widths that break at 360dp.
- Dark-mode colour pairs all clear 4.5:1.
- `PeriodRange` / `_DateRange` value equality is correct, and the period picker's `initialDate` is always in bounds (no `showDatePicker` assertion).
- Double-submit guards on all saves: `SaveShortcut.enabled` is now genuinely read, and app-bar/bottom-bar/Save-and-New all disable while `_saving`.
- `UnsavedGuard`'s navigator/messenger capture across the async gap is correct (its bug is A1's pop, not this).

---

## G. Suggested fix order

1. **A1** — one-line class of fix, seven editors, both platforms, users are currently trapped.
2. **A2/A3** — backup integrity. Block token export, add `accounts`/`journal_entries`/`journal_lines` to the format, add `onDowngrade`.
3. **A15** — one-line `go()`/`goBranch()` fix, affects every Settings entry point.
4. **A4** — `FinancialYear.forDate(now).start`; three months a year are currently broken.
5. **A13/A14** — scanned-bill stock and negative balances; both silent.
6. **A6/A7/A8** — GST return correctness; these get filed with the government.
7. **A5 + B6–B9** — sync merge and session handling, as one piece.
8. **B1/B2/B3** — Windows print path; the UI-isolate block is a freeze.
9. **A10/B10/B11/B12/B13/B14** — catalogue and party correctness.
10. **B16/B17** — GSTR-1 schema shape. (A16 was retracted; see its entry.)
11. **A9, B19–B24** — document lifecycle correctness.
12. **C (Android exports), B25–B28** — platform reachability and responsive overflow.
13. Everything in D/E as capacity allows.

---

## Notes on method

- `flutter analyze` was clean at the time of the previous audit (`audit/01`) and no new
  analyzer-visible defects were found; essentially every finding here is a *logic or
  design* defect that type-checking cannot see.
- The 84 existing tests are real and pass, but coverage is concentrated on repositories.
  There is **no test** for: `UnsavedGuard`'s discard path, keyboard type on any field,
  hover-only affordances, platform-conditional rendering, or the text-scale clamp.
  Widget tests that assert on layout at a single width will not catch B25/B43/D44/D45/D46.
---

## H. Fix ledger

All work landed on the working tree above `00d1714`. `dart analyze lib test` → **No issues
found!** at the end of the pass.

### What each area got

| Area | Fixed |
|---|---|
| Backup / restore | Ledger (`accounts`, `journal_entries`, `journal_lines`, `audit_logs`) added to the format and to `_clearAll`; session keys excluded on the way **out** and refused on the way **in**; `_version` 2→3 with v1/v2 still restoring; downgrade guard routed through `onUpgrade` (drift 2.31 has no `onDowngrade`) |
| Sync / auth | Same-second tie now applies the pull instead of dropping it forever; `maxTrustedClockSkew = 1 day`; new `AccessTokenResult` / `resolveAccessToken()` so offline ≠ signed out; `refreshing` cannot stick; `expiresIn` leeway clamped at 0; "Last synced" needs both directions |
| GST returns | 3.1(a)/3.1(c) split from per-line rates using stored line taxables (buckets still sum to the document total); EXPWP/EXPWOP for exports; `doc_num: 4` for debit notes; HSN rows carry `rt`; CDNUR shape corrected; ITC reversals routed to 4(B)(1); credit/debit notes included in `gstSummary`; net payable floored at 0 |
| Ledger / reports | Trial balance uses `FinancialYear.forDate` (was start-after-end every Jan–Mar); ledger row flexes aligned to the header; trend + stock cards re-query on firm switch; quarter range snaps to the real last day |
| Sales / purchase docs | Scanned bills resolve to catalogue items (and say so when they don't); one `DocumentSettlement` derivation for balance + status across every write path, with an over-payment warning; `reverseStockForSource` excludes its own reversal rows and is idempotent; duplicate no longer converts the source; TCS marks dirty; UTGST instead of SGST; rate labels only when there is one rate; due date re-clamped |
| Payments / POS | Real cheque state machine with the repository as authority; `chequeStatus` follows mode; receive-payment capped at balance; POS search generation guard; clear-cart confirm + undo on every line removal; stale payment amount re-synced via `didUpdateWidget`; loading skeleton instead of a fake ₹0.00 |
| Windows printing | FFI spooling moved off the UI isolate onto one long-lived worker with a 20 s timeout; `close()`+`done` instead of `flush()`+`destroy()`; `GetLastError` bound before the failing call; `usb` transport hidden and refused off Windows; every failure surfaces as a message, never a red screen |
| Export / PDF | Real per-platform export root (Android app-scoped external storage, no permission prompt); Share offered on every export and no raw paths shown; export/open outcomes reported independently; repeated table headers; `maxPages` raised; xlsx money written as numbers; reconciliation totals under the right headings |
| Catalogue / parties / stock | Barcode/SKU/HSN lookup in the line picker; items search pushed into SQL (cap gone); binned payments stop reducing outstanding; outstanding made reactive; "Save & New" can clear its dirty flag; custom units survive a line-unit change; state 97 GSTINs validate |
| Settings | Firm Profile can clear every optional field (the absent-vs-null footgun); logo Remove works; period lock confirms first; purge reports per-table failures and no longer aborts on the first locked row; server URL debounced; all raw exception text replaced |
| Responsive / platform | Text-scale clamp removed (was silently capping Android's setting at 1.15×); sync pauses when backgrounded; Windows minimum window size; app name "Atria" on both platforms; top-bar overflow fixed by measuring chrome first; most-specific rail highlighting; duplicate nav entries removed; 44dp targets across the shared widgets; `/payment-reminders` reachable from the rail and search |
| Shared | One `atriaErrorMessage()` helper replacing 11 sites that printed `SqliteException` and file paths as user-facing text; line-grid delete reachable by touch |

### Retracted

- **A16** — "statements and invoices cannot paginate" was **wrong**. `pw.Table` is a
  `SpanningWidget` and does paginate. The real adjacent bug (`maxPages` default of 20) was
  fixed instead. This is the one finding from this audit that was confidently incorrect.

### Still to do by hand

1. ~~**Run the tests.**~~ **DONE.** The Application Control policy was lifted, so the suite
   ran for real. It found **three genuine bugs the type checker could not** — see below.
   Final state: **537 passing, 0 failing, 1 skipped** (a Vyapar fixture absent from this
   machine).
2. ~~**Regenerate the goldens.**~~ **DONE.** All 13 PNGs recaptured via the procedure in
   `dart_test.yaml`. Two captures overran the 5-minute teardown budget *after* writing their
   image — the file's own notes say that happens and the PNG is still valid.
3. ~~**Windows C++ was reviewed by hand, not compiled.**~~ **DONE.** Compiles, debug and
   release. `build/windows/x64/runner/Release/atria.exe`.
4. **STILL OUTSTANDING — the Android APK was never built.** This machine has no Android SDK
   and no JDK, so `flutter build apk` cannot run at all. The manifest was validated as
   well-formed XML with the label corrected, and gradle/`build.gradle.kts` is unchanged
   except for pre-existing release signing, but **nothing has compiled the Android target.**
   Do that before shipping.

### What the test run caught that the type checker could not

Running the suite for real found three defects that `analyze` was perfectly happy with, all
in code written during this very fix pass:

- **The sync merge rule was inverted.** `localAt.difference(pulledAt) <= maxTrustedClockSkew`
  instead of `>`, so believing the local clock was the *default* rather than the exception.
  Inside the bound a genuinely newer local edit was clobbered by a 5-minute-old remote row;
  outside it a 6-year-old clock correctly won. Two test failures that looked mirrored were
  one line failing in both directions. **This was the A5 data-loss fix itself, broken.**
- **Exports were filed under the wrong place of supply.** GSTR-1 Tables 13A/13B accept only
  `96` (Outside India); the builder was echoing the document's `placeOfSupply`, which holds
  the *domestic* state — so every export invoice was filed under a state the goods never went
  to. Both files' own doc comments already said `96` was the only legal code.
- **The filter pill row could ellipsise the one label it exists to protect.** `_fits` summed
  every label, but the equal-width row gives each pill the *same* share, so a mixed row
  (`All` / `Sales invoice` / `Receipt`) passed the total check at 320dp while `Sales invoice`
  still did not fit. Now checks `widest <= share`.

### Build hygiene uncovered along the way

- **`simple_barcode_scanner` broke the Windows build.** Audit finding D18 had already recorded
  that it was declared but imported nowhere. It drags in `webview_windows`, and
  `webview_windows_plugin.vcxproj` no longer compiles against MSVC 14.51 — its C++ uses
  `<experimental/coroutine>`, which MSVC rejects with `STL1011 ... will be REMOVED SOON`.
  Removing the dead dependency fixed the build. There has never been any camera barcode
  scanning on any platform; POS uses a keyboard-wedge scanner.
- **A stale `build/windows/x64/CMakeCache.txt`** mixed Community's `cmake.exe` with BuildTools'
  compiler paths and made Flutter look for a VS instance that does not exist. `flutter clean`
  fixed it.
- **`flutter analyze` at the repo root reports ~482 issues in `server/`**, a separate Dart
  package whose deps are not resolved here. Pre-existing and unrelated. Scope to
  `flutter analyze lib test`.
- **Stale golden failure diffs remain in `test/failures/`** from before the fixes. They are
  excluded from the suite and harmless, but they no longer correspond to anything; worth
  deleting if nothing else reads them.

### Known follow-ups left deliberately

- **Stock reversal rows** written before the fix have random ids and come in self-cancelling
  pairs. They are correctly excluded now and stop multiplying, but cannot be paired with their
  originals without a data migration. A firm wanting a clean ledger must purge those documents.
- **A purchase return still adds no credit to the linked bill.** There is no `linkedBillId`
  column, so this needs a migration plus a matching rule plus UI to pick the bill — a product
  decision, not a bug fix.
- **Text scale up to 2.0× now reaches screens outside the responsive group's ownership**
  (editors, line grid, GST tabs). Those were tuned against 1.15× and may need a pass.
- **`restoreFirm` now navigates** and shows `report.describe`; worth watching on first run.
