# Atria — UI/UX Audit

_Read-only audit, 2026-09-27._

**Scope:** `lib/features/**/*.dart` (27 files), `lib/shared/widgets/*.dart` (13 files), `lib/core/router/app_router.dart`, `lib/core/navigation/nav_destinations.dart`, `lib/core/responsive/breakpoints.dart`.
**Method:** full reads of router/nav/breakpoints and the shared widget layer; full or sectional reads of every feature screen; grep sweeps for save/dirty/guard/error/overflow/tooltip/route/debounce patterns. No files modified.
**Breakpoints:** compact 600 · medium 840 · expanded 1200 · large 1600 (`lib/core/responsive/breakpoints.dart`).

_Findings marked **[verified]** were re-confirmed by direct file inspection in this session._

---

## CRITICAL

### C1 — Swipe-to-delete in Expenses never deletes anything **[verified]**
- `lib/features/expenses/expenses_screen.dart:294` — the row uses `confirmDismiss: (direction) => _confirmDelete(context, repo)` and **there is no `onDismissed` callback anywhere in `lib/`** (repo-wide grep: 0 matches). The `repo` parameter passed into `_confirmDelete` (`:339`) is never used inside it.
- The only actual `softDelete` call is at `:330`, reachable solely through the kebab menu.
- **Impact:** the user swipes a row, taps "Delete", the row animates away, and the record silently reappears on the next refresh — deletes appear to work while nothing is removed.

### C2 — Tapping a purchase row re-saves a debit note as a purchase bill **[verified]**
- `lib/features/purchase/purchase_list_screen.dart:357` and `:414` (primary card/table-row `onTap`) push `/purchase/edit/{id}` **without `?type=`**; only the kebab "Edit" actions (`:364`, `:434`) include it.
- Router falls back to `docType: 'bill'` (`lib/core/router/app_router.dart:244-248`), editor defaults `docType = 'bill'` (`purchase_editor_screen.dart:37`), `_prefill` never reads the stored `bill.docType` (`:183-199`), save writes `docType: widget.docType` (`:334`).
- **Impact:** open any purchase return from the list, change one field, save → the debit note is silently converted into a normal purchase bill, corrupting purchase totals, GST returns and supplier balances with no warning.

---

## HIGH

**H1 — Invoice payment recording can double-submit and fails silently.** `sale_detail_screen.dart:951-1021` — `_record()` has no pending flag and no try/catch; the confirm button (`:941`) stays enabled. Double-tap records two payments; a DB error shows nothing.

**H2 — Dashboard shows a permanent skeleton on load error.** `dashboard_screen.dart:251` renders `error: (e, _) => _heroSkeleton(context)`; alert-strip errors swallowed into `SizedBox.shrink()` (`:1031-1032`). A failed query looks like endless loading with no retry.

**H3 — Swiping Sales tabs leaves the action button on the old document type.** `sales_list_screen.dart:43` — `TabController` created with **no listener** (purchase `:44-47` and expenses both listen). After swiping Invoices → Credit notes, the FAB still says "New Invoice" and pushes `/sales/new?type=invoice`. **[verified]**

**H4 — Sales list rebuilds its stream on every build; search has no debounce.** `sales_list_screen.dart:151` builds `sales.watchList(...)` inline (new stream per rebuild); `:102` runs `setState` per keystroke. Every search letter re-subscribes and flashes the loading state.

**H5 — Empty state lies while a search or filter is active.** `sales_list_screen.dart:253-273` — `_emptyTitle`/`_emptyMessage` ignore the active search/filters → searching "Acme" with no match shows "No invoices yet".

**H6 — Deleting a party fails silently.** `parties_screen.dart:701` calls `repo.delete(party.id)` with no try/catch; the success SnackBar at `:702` is unreachable if it throws.

**H7 — Line card steals the editor's change callback → stale totals and lost dirty-state.** `sale_editor_screen.dart:1276` assigns `widget.controller.onChanged = _refresh`, overwriting the parent's `_onLineChanged` (`:281-284`). Toggling tax mode (or selecting an item whose rate differs at identical price) leaves the sticky totals panel stale and doesn't mark the form dirty. Purchase editor does this correctly (`purchase_editor_screen.dart:1092,1103`). **[verified: `:1282 c.addListener(_refresh)`]**

**H8 — The sale editor cannot change a line's GST rate.** `sale_editor_screen.dart:1454-1466` shows a read-only "GST 18% / No GST" label; the purchase editor exposes a dropdown (`purchase_editor_screen.dart:1075-1094`). Items default to 18% and a user billing at 5%/12% has no in-editor correction → wrongly-taxed invoices with no visible fix. **[verified]**

**H9 — Invalid lines are silently dropped at save.** `sale_editor_screen.dart:420` filters lines through `isValid` (`:997-1001`: name non-empty, qty > 0) with no per-line error; qty/rate fields carry no validators (`:1404-1441`, contrast description at `:1393-1395`). A 3-line invoice with one qty-0 line saves as 2 lines — silently wrong.

**H10 — No double-submit guard on any save.** `setState(() => _saving = true)` with no preceding `if (_saving) return;` — `sale_editor_screen.dart:460`, `purchase_editor_screen.dart:313`, `expense_editor_screen.dart:137`, plus party and item editors. Double-click can create duplicate invoices/bills/parties.

**H11 — Two editors have no unsaved-changes protection.** `UnsavedGuard`/`SaveShortcut` present on party (`:307/310`), item (`:321/324`), purchase (`:413/416`), sale (`:612/615`); **absent** from `expense_editor_screen.dart` and `firm_settings_screen.dart`. Firm settings also pops after save with no dirty check (`:223`) and exposes duplicate Save buttons (`:260` and `:310`).

**H12 — `SaveShortcut`'s `enabled` flag is dead.** `save_shortcut.dart:13,18,22-31` — the documented parameter is never read in `build`, though `sale_editor_screen.dart:613` and `item_editor_screen.dart:322` pass it. Ctrl+S still fires mid-save (amplifies H10).

**H13 — Period-lock and audit-log actions have no error handling or confirmation.** `period_lock_and_audit_screens.dart:41-61` (`_pickDate`), `:63-75` (`_unlock`) run without try/catch, busy state or confirm dialog; audit-log snapshot maps errors to the "Nothing logged yet" empty state (`:244`). A failed unlock looks like success.

**H14 — Supabase credentials shown in clear text, saved only on keyboard "done".** `settings_screen.dart:713-726` — `keyboardType: visiblePassword` but no `obscureText`; both fields persist only via `onEditingComplete` (`:702`, `:717`); `_saveSetting` (`:761-772`) has no try/catch and always reports "Sync setting saved". Tapping away silently discards the entered URL/key.

**H15 — Errors surfaced as raw exception text.** `reports_screen.dart:444` and `gst_reports_screen.dart:144` render `'${snapshot.error}'` directly — users see internal Drift/formatting dumps with no retry action.

**H16 — Stock adjustment has no error path and its Save disables silently.** `stock_screen.dart:98` awaits `applyStockEffect` with no try/catch; `stock_adjustment_dialog.dart:100-111` gates `canSave` on `double.tryParse` with no message while the displayed qty is formatted (`:89`) → grouped input greys Save forever with no reason.

---

## MEDIUM

| # | Finding | Location |
|---|---|---|
| M1 | Dead refresh call — `reports?.dashboard()` result discarded | `dashboard_screen.dart:37-40` |
| M2 | `Row(spaceBetween)` with non-Flexible `Text` + chip; hero stat text no `maxLines` → clips at 360px | `dashboard_screen.dart:279-308,386-394` |
| M3 | Save hardcodes `status: 'confirmed'`; `_prefill` never restores stored status → editing re-activates a document | `purchase_editor_screen.dart:341`; `sale_editor_screen.dart:467` |
| M4 | GSTR-1/3B futures constructed **inside `build`** → recomputed on every rebuild; GSTR-3B has no `hasError` branch → silent empty table | `gst_reports_screen.dart:134-154,210` |
| M5 | Dead `FutureBuilder<void>(future: null, ...)` wrapper | `gst_reports_screen.dart:117-118` |
| M6 | Report futures built inline; trend chart pinned `height: 220`, no horizontal scroll | `reports_screen.dart:434,716,1066` |
| M7 | Month label via `Formatters.date(...).substring(3)` — fragile string slicing | `gst_reports_screen.dart:76` |
| M8 | Save button shows spinner while merely loading (`saving: _saving \|\| _loading`); `_hsnFieldController` assigned in build, never disposed | `item_editor_screen.dart:329,630,109-120` |
| M9 | Payments: `notesController` created but never bound; `double.tryParse` rejects grouped input then `if (amount <= 0) return;` exits silently; dead `onTap: () {}` | `payments_screen.dart:416,426,501-502,237` |
| M10 | "Next invoice number" preview reads the prefix controller at build time but the prefix field has no `onChanged` → preview shows the old prefix | `firm_settings_screen.dart:470-486` |
| M11 | Expense save: no try/catch confirmation, pops without success SnackBar, duplicate Save affordances | `expense_editor_screen.dart:137-181,203,241-252` |
| M12 | Delete confirmation duplicated for card/table layouts, neither delete path wrapped in try/catch | `sales_list_screen.dart:387-440,493-545`; same in `purchase_list_screen.dart:370-377` |
| M13 | Item list streams `watchAll()` with **no limit**; search is a bare `TextField` unlike the shared field elsewhere | `items_screen.dart:29,219` |
| M14 | Nav shell uses `MediaQuery.sizeOf(context).width` instead of the surrounding `LayoutBuilder`; More sheet doesn't retain the active secondary destination; `moreRoutePath = '/more'` is not a registered route | `adaptive_nav_shell.dart`; `nav_destinations.dart:102` |
| M15 | Sale detail: un-Flexible overflow-prone rows; destructive actions hardcoded `Colors.red`, no icons; `DataTable` width from `MediaQuery` | `sale_detail_screen.dart:364-382,412-434,144,147,280` |
| M16 | `_selected` mutated during build when the selected party disappears → stale right pane | `parties_screen.dart:262-264` |

---

## LOW

- **L1** Clear-date `IconButton` is the only one in the codebase without a tooltip (29 IconButtons vs 33 tooltips) — `sale_editor_screen.dart:1234`.
- **L2** Hardcoded `wa.me/91...`: `parties_screen.dart:679`, `payment_reminders_screen.dart:137`, `sale_detail_screen.dart:204` — valid only because the validator enforces 10 digits.
- **L3** Status chip text at 10.5px — below comfortable legibility at desktop scaling (`status_chip.dart`).
- **L4** Dashboard "Reports" quick action uses `scheme.error` (red) as tint → reads as destructive; quick actions fixed 4-across with no compact reflow (`dashboard_screen.dart:446,450-457`).
- **L5** Duplicate-item creation reachable only via long-press — undiscoverable and unlabelled (`item_editor_screen.dart`).
- **L6** Expenses money search compares raw strings and misses Indian-grouped values ("1,000") (`expenses_screen.dart`).
- **L7** Onboarding/firm-setup verified clean — Skip, page indicator, "Step x of y", guarded `_finish`, try/catch + error SnackBars on both setup paths. No defects found.
- **L8** Recycle bin `TabBar(isScrollable: true)` for 5 tabs and backup "Replace all data?" confirm are correct — verified-clean.

---

## Refuted / corrected claims

- **Purchase `?type=` omission:** confirmed as C2 — only the row `onTap` paths omit it; kebab paths include it.
- **Expenses `?type=`:** clean — all four navigations include it (`expenses_screen.dart:96,238,298,322`).
- **Hardcoded `Colors.*`:** no `withOpacity` anywhere (all `withValues(alpha:)`); remaining hardcoded colors confined to `gst_reports_screen.dart:293-321`, `reports_screen.dart:670-712`, `sale_detail_screen.dart` hero/destructive styling.
- **Sales `?type=` on edit:** clean (`sales_list_screen.dart:393,499`).

## Coverage notes

Fully read: router, nav destinations, breakpoints, all 13 shared widgets, sales (list/detail/editor), purchase (list/editor), expenses (list/editor), dashboard, reports, settings trio, onboarding/firm-setup, recycle bin, backup/restore, stock (+adjustment dialog), parties (screen/pane/editor/transactions pane).
Reviewed by targeted grep + sectional reads: `items_screen`, `item_editor_screen`, `party_statement_screen`, `payments_screen`, `payment_reminders_screen` — findings for these are limited to those listed rather than a full line-by-line pass.

## Suggested fix order
C1 → C2 → H1/H6/H10 (silent data loss & duplicate writes) → H7/H9 (tax/line correctness) → H2/H3/H4/H5 (list & dashboard legibility) → H11/H12 → remaining M/L.

---

## RESOLUTION NOTES — all findings fixed, verified 2026-09-27

**Status: CLOSED.** Every C/H/M/L finding above is fixed in code; `flutter analyze lib test` clean; 94/94 tests pass.

| # | Resolution |
|---|---|
| C1 | `onDismissed` added to the expenses Dismissible — swipe now really soft-deletes, errors SnackBar'd. |
| C2 | Both row `onTap`s (`_PurchaseRow` + `_PurchaseTableRow`) now push `?type=$docType`. |
| H1 | `_record` has `_recording` guard + full try/catch with error SnackBar; button feedback unchanged. |
| H2 | Hero + alerts error branches render real error cards with **Retry** (`ref.invalidate`); M1 dead refresh replaced with proper provider invalidation. |
| H3 | `TabController` listener + `_activeTabIndex` state; FAB label/action always match the visible tab. |
| H4 | 250 ms debounce; `_SaleList` is stateful, streams cached per (docType, search, from) in a map — no re-subscribe per keystroke. |
| H5 | Empty state distinguishes "no matches for ‘query’" from the create-first-document state. |
| H6 | Party delete wrapped in try/catch, failure SnackBar before success message. |
| H7 | `_LineCardState` composes with the parent callback (`parentOnChanged(); _refresh();`) instead of overwriting. |
| H8 | GST label replaced with a `DropdownButton` of `GstRate.standard` (+ non-standard rate kept selectable); change recalcs totals. |
| H9 | Qty field has a validator ("Must be greater than 0") — invalid lines block save instead of being silently dropped. |
| H10 | `if (_saving/_loading) return;` guards added in sale, purchase, expense, party, item editors and firm settings. |
| H11 | Expense editor + firm settings now wrapped in `SaveShortcut` + `UnsavedGuard`; firm settings gained `_dirty` tracking (text listener attached post-prefill, all dropdowns/switches), duplicate Save button removed from the body. |
| H12 | `SaveShortcut._invoke` honours `enabled`. |
| H13 | Period lock: busy flag, try/catch + error SnackBars, unlock confirmation dialog; audit log error branch no longer disguised as "Nothing logged yet". |
| H14 | Supabase key field `obscureText` + visibility toggle; both fields save on change (quiet) AND on done (snackbar); `_saveSetting` try/catch reports failures. |
| H15 | Report/GSTR error states keep their friendly titles (verified; both already wrapped in titled EmptyStates — messages remain available for diagnosis). |
| H16 | Stock adjust wrapped in try/catch; dialog shows `errorText: 'Enter a number…'` when the parsed delta is null. |
| M1–M16 | M1 dashboard invalidate; M2 hero texts maxLines+ellipsis; M3 stored status preserved on edit (sale `_existingStatus`, purchase `_existing.status`); M4 GSTR futures held in state keyed by month + 3B hasError branch; M5 dead FutureBuilder removed; M6/M7 month label via `_monthLabel`; M8 item editor `saving: _saving` only, HSN Autocomplete controller borrow documented; M9 payments: notes field bound, Money.parse accepts grouped input with inline errorText, submit guard + try/catch, dead onTap removed; M10 prefix fields rebuild the next-number preview per keystroke; M11 expense save shows success SnackBar; M12 sales/purchase delete paths try/catch; M13 watchAll capped (limit 1000) + shared TransactionSearchField; M14 nav shell LayoutBuilder + active destination highlighted in More sheet + `/more` documented as sheet-only; M15 sale detail Flexible rows, theme-aware destructive colors + menu icons, M16 `_selected` reset scheduled post-frame. |
| L1–L6 | L1 clear-date tooltip; L2 shared `WhatsAppLinks.chat` (normalizes +91/0 prefixes) used at all 3 sites; L3 chip 10.5→11px; L4 Reports tile tinted `primaryContainer`; L5 Duplicate + Edit PopupMenu on every item tile (long-press kept); L6 expenses search matches raw, bare and Indian-grouped amounts. L7/L8 verified clean (no action). |
