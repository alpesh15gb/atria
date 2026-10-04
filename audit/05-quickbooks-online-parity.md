# 05 — QuickBooks Online Parity: information architecture, placement and fields

Scope: rebuild Atria's **chrome, navigation, screen anatomy, field order and
palette** so a QBO user can find every control where they expect it. Not a
feature port — see [What is deliberately *not* QBO](#what-is-deliberately-not-qbo).

Sources (read, not remembered):

- E-Tech, *QBO US Manual 2026* §4.1 "The dashboard and left navigation" —
  dashboard cards, the nine left-navigation headings, and the rule that a
  section appears only when its feature is on.
- Intuit, *Create invoices* (help article, updated 8/5/2026) — the invoice
  screen's field order and the Manage / Customization / Payment options /
  Design / Recurring / Reminders blocks.
- Intuit, *What Advisors Need to Know About the New QuickBooks Online
  Interface* (2025-08-26) — the 2025 redesign: My Menu at the top of the left
  navigation, settings gear at the bottom, visual-only first phase.
- Porte Brown, *New Business View for QBO* — the nine Business-view headings
  (Get Things Done, Business Overview, Get Paid and Pay, Customers and Leads,
  Payroll, Bookkeeping, GST, Apps, Bookmarks) and "staff come from the settings
  cog at the bottom of the left navigation".
- Intuit brand palette (`#2CA01C` green, `#0077C5` blue, `#393A3D` charcoal,
  `#F4F5F7` page grey, `#D4D7DC` hairline).

---

## 1. Information architecture: QBO headings → Atria branches

QBO groups the app into nine headings; Atria has twelve route branches. The
mapping keeps every branch reachable and does not invent new ones.

| QBO heading | QBO pages | Atria rail row | Route / branch |
|---|---|---|---|
| **Dashboard** | Dashboard | Dashboard | `/dashboard` (0) |
| **Sales** | Invoices, Estimates, Sales receipts, Credit notes, Products and services, Customers | Invoices, Quotations, Sales orders, Delivery notes, Credit notes, Payments received, Products and services, Customers | `/sales?type=…`, `/payments` (7), `/items` (2), `/parties?type=customer` |
| **Expenses** | Vendors, Bills, Expenses | Bills, Debit notes, Expenses, Vendors | `/purchase?type=…`, `/expenses` (8), `/parties?type=supplier` |
| **Reports** | All reports, Statements | Reports, Statements of account, Stock summary | `/reports` (4), `/statements` (6), `/stock` (9) |
| **Taxes** | VAT/GST returns, tax centre | GST returns | `/gst-reports` (10) |
| **Accounting** | Chart of accounts, Reconcile, Journal entries | *(none — see gaps)* | — |
| **Payroll / Projects / Apps / Bookmarks** | — | *(not applicable)* | — |
| **Settings** (gear, bottom of the pane) | Company, Sales, Expenses, Account and settings | Settings, Company profile, Data and backup, Recycle bin, Period lock, Audit log | `/settings` (11) + sub-routes |

Where Atria has one screen for two QBO pages, the rail reaches it twice with a
preselecting query (`Customers` / `Vendors` → `/parties?type=…`), which is why
`PartiesScreen` grew an `initialType`.

**Branch order is load-bearing.** `NavDestinations.all` is indexed by the
`StatefulShellRoute.indexedStack` branch order in `app_router.dart`, and the
mobile bottom bar treats the first five as its slots. Rail rows may be
*relabelled* freely; reordering means reordering the router too. Rows carry
either a `branchIndex` (tap switches branch, preserving per-branch state) or a
deep-link route (tapped with `push`, because a branch switch cannot carry a
query string).

## 2. Chrome

| QBO | Atria |
|---|---|
| Green **Create** button, top-left of the chrome, opening one menu of every "new …" action | `AtriaCreateButton` (`atria_create_menu.dart`) at the top of the rail, in the dashboard header, and at the top of the mobile More sheet. One shared list `atriaCreateActions`, grouped Sales / Money / Purchases / Lists. |
| One app-wide white band **above both the nav pane and the page**, holding the logo, the company switcher, search, the gear and the avatar | `AtriaTopBar` (`atria_top_bar.dart`), mounted once by `AdaptiveNavShell` — for the rail shell and the phone shell alike. The wordmark is aligned to the 236px nav column; the compact rail shows the logo only. |
| Product-wide search (pages *and* documents) | The field opens `showAtriaGlobalSearch` (`atria_global_search.dart`): matching navigation pages, plus live invoice matches from the sales repository once two characters are typed. Below 720px the field collapses to a magnifier button. |
| Company switcher next to the logo, account menu at the far right | `_BusinessSwitcher` (Company profile, Data and backup) and `_AccountMenu` (Company profile, Audit log, Settings) — both real routes. |
| White header strip with a hairline under it, on a grey page | `appBarTheme`: `surface` background + `Border(bottom: outline)`; scaffold stays `#F4F5F7`. |
| Left navigation grouped under all-caps headings, selected page on a tinted strip | Extended rail (`≥ Breakpoints.medium`, 236px): the wordmark now lives in the top bar, so the pane opens with **Create**, then `MAIN / SALES / EXPENSES / REPORTS / TAXES / SETTINGS` with one row per page. Selected row = `primaryContainer` chip, bold green label, 3px green left bar. |
| Icon-only rail on a narrow screen, tooltips on hover | Compact rail (`≥ Breakpoints.compact`, 64px): same rows, icons only. |
| Settings gear pinned to the bottom of the pane | Settings is the last section; the rail footer carries the "stored on this device" note. |
| Bottom navigation on mobile, overflow under "More" | Unchanged in shape, but the More sheet is now generated from the same `NavDestinations.sections`, so desktop and mobile teach one map. |

## 3. Screen anatomy

### 3.1 Invoice editor — field order

QBO's order (per the help article): customer → invoice date → due date → terms
→ line table (Product/Service, Description, Qty, Rate, Amount) → discount /
shipping → tax → message and attachment → design / payment options / recurring
/ reminders → send. Atria's editor now follows the same spine:

| Position | QBO | Atria |
|---|---|---|
| Header left | Customer block (Add customer →, billing address under it) | Customer card: `Select customer` dropdown, GSTIN • phone, address, place of supply |
| Header right | Invoice date, Due date, Terms, P.O. no. | Invoice date, Due date (same row as the customer block on `≥ medium`, stacked below it on a phone) |
| Lines | One bordered table, hairlines between rows, `Qty / Rate / Amount` per row | `_LineTable` — one bordered surface, `Divider` between lines, each line row: `#`, item type-ahead, remove; description; **Qty | Rate | Disc % | Amount**; GST rate + inclusive toggle + HSN |
| Under the table | "Add lines" / "Clear all lines" links | "Add lines" green text button, left-aligned |
| Then | Totals block, right-aligned under the last line | `EditorTotalsPanel(inline: true)` in a 460px right-aligned column: Subtotal, item/invoice discount, taxable value, CGST/SGST/IGST, cess, shipping, round off, **Total**, credit-limit warning, "Mark as fully paid" |
| Footer of the page | "Message on invoice", "Terms & conditions" | "Message on invoice" (open by default), "Discount, shipping and round off" |
| Actions | Save and send ▾ / Save and close / ⋮ More / Cancel | Top bar: Save and new (new documents) + **Save and close** — on every width. QBO has no floating action button anywhere in the product, and the bar already carries Save, so the compact-width FAB was a duplicate and is gone (`AtriaGradientFab` deleted). |

`EditorShellBody.single` is the new full-width, no-side-rail body mode the
invoice page uses; the two-pane mode stays for the purchase and expense
editors until they are converted.

### 3.2 Dashboard

QBO's dashboard is a card grid: Business snapshot, movement figures, Profit and
loss, Expenses, Bank accounts, overdue invoices. Atria's order is now:

1. **Business snapshot** — `Business snapshot` title + month, `Total sales this
   month`, the figure, invoice count, hairline, then To receive / To pay / Cash
   in hand / Stock value on the same rule. (Was a violet gradient hero; QBO has
   no gradient band on a dashboard.)
2. KPI tiles (Income, Expenses, Profit, …).
3. Two columns on `≥ medium`: **Profit and loss** chart (3/5) beside
   **invoices owed to you** + alerts (2/5); stacked below that width.
4. **Get things done** — the quick-create vocabulary as green action links
   inside a card, the way QBO's onboarding checklist reads. The Vyapar-style
   tile strip is gone.

### 3.3 Lists

Every list page (Sales, Purchase, Products and services, Parties, Payments,
Expenses, Stock summary) now uses the same four-part anatomy, in QBO's order:

| Part | Widget | Notes |
|---|---|---|
| Page heading, **actions at its right edge** | `AtriaPageHeader` + `AtriaPrimaryAction` / `AtriaHeaderIconAction` (`atria_page_header.dart`) | The page names itself; there is no app bar repeating the title and **no FAB**. On phone widths the heading wraps and the actions move under it. |
| Search | `TransactionSearchField` | Scoped to the list you are on — the chrome's search is the product-wide one. |
| Filter row | `AtriaFilterBar` + `AtriaAdaptiveFilter<T>` (`atria_list_toolbar.dart`) | `Type: Invoices ▾   Date: This month ▾` — hairline-bordered selects on the page, the way QBO's web filter row reads. On phone widths the same widget falls back to the segmented pill row, which is what QBO's own mobile app uses. |
| Table | `TransactionTableHeader` / `TransactionTableRow` / `TransactionTableTotals` | Flat header strip with a hairline under it; rows separated by hairlines; the column sums close the table as a total line instead of floating above the list as a summary card. |

Still true: panels are hairline-bordered first and shadowed second (`AtriaCard`);
status chips keep their semantic colours (paid green, partial amber, unpaid grey,
sent blue); money columns stay tabular-figure right-aligned (`MoneyText`).

## 4. Palette and geometry (`lib/core/theme`)

| Token | Was (violet fintech) | Now (QBO) |
|---|---|---|
| `primary` | `#6D28D9` | `#2CA01C` |
| `primaryDark` / `primaryDeep` | `#5B21B6` / `#4C1D95` | `#248615` / `#14690B` |
| `primaryContainer` | `#EDE9FE` | `#E4F1E0` |
| `link` (secondary/quiet actions) | saffron `#F97316` | `#0077C5` |
| `info` | `#2563EB` | `#0077C5` |
| `success` / `error` / `warning` | `#059669` / `#DC2626` / `#D97706` | `#218214` / `#E43834` / `#C77700` |
| `paper` / `surfaceVariant` | `#F6F5FA` / `#EEECF5` | `#F4F5F7` / `#F4F5F7` |
| `ink` / `inkSecondary` / `outline` | `#16141F` / `#565263` / `#D4D0E0` | `#393A3D` / `#6B6C72` / `#D4D7DC` |
| `brandGradient` | violet 600→900 | flat green (`#2CA01C` → `#218214`) — QBO has no brand gradient |
| `heroGradient` | violet→ember | charcoal band `#3D3E42` → `#2B2C2F` |

Geometry: `AppRadius` drops from 10/14/18/24/32 to **4/6/8/12/16** (4px fields
and buttons, 12px cards); `AppShadows.card` from an 18px violet blur to a 2px
neutral one; type scale densified to 13px body / 13.5px controls / 19px page
titles. Inputs became white boxes with a hairline edge and a 2px green focus
ring (they were borderless grey fills), text buttons are blue links, tab strips
are green underlines, and checkboxes/switches use the neutral grey ramp.

## 5. What this pass did *not* do

- **No new accounting modules.** Chart of accounts, a banking register,
  reconcile, journal entries, projects, payroll and estimates have no backing
  tables in Atria, so the Accounting heading is empty rather than a dead link.
  QBO's "Banking" chapter is therefore absent; payments live under Sales →
  Payments received, which is where a QBO user looks for them after an invoice.
- **No email send.** QBO's primary action is "Save and send"; Atria has no mail
  transport, so the primary stays "Save and close".
- **Terms / P.O. number / shipping address fields** do not exist in the sale
  schema, so the header's right column carries only the dates.
- Estimated/actual "days to get paid" and QBO's bank-feed widgets are not
  modelled.

## 6. Regression cover

- `test/editor_shell_test.dart` now asserts the QBO wording ("Save and close",
  "Add lines", "Message on invoice", "Discount, shipping and round off", and a
  totals block whose label is "Total").
- `test/nav_shell_regression_test.dart` (#"every rail row opens the branch it
  names") walks `NavDestinations.sections` instead of the old flat list, on a
  desktop-sized surface so the labelled rail renders — the icon-only rail has no
  labels to tap.
- `test/ui_structure_regression_test.dart` still covers Reports and Expenses.

## 7. Second pass: the application chrome and list anatomy

The pass above changed the theme, the rail's grouping and the editor's field
order. Auditing what was *left* found four structural tells that no amount of
re-tinting could hide, because they are Material's, not Atria's:

| Tell | Where it was | Why it reads as "not QBO" |
|---|---|---|
| A per-page `AppBar` | 24 screens | Every page grew its own title bar, so the business you are in, search and the account controls were either absent or duplicated per screen |
| A floating action button | 7 list screens + the invoice editor | QBO has no FAB anywhere in the product |
| Chip rows used as filters | 9 screens, two of them stacked (type + period) | QBO's filter row is a strip of labelled selects; pills everywhere read as an Android app |
| A summary card above each list | Sales, Purchase, Expenses, Payments | QBO totals close the table, they do not float above it |

What changed:

- **`AtriaTopBar`** (`lib/shared/widgets/atria_top_bar.dart`) — the app-wide band:
  wordmark aligned to the nav column, business switcher, product-wide search,
  settings gear, initials avatar. Mounted once by `AdaptiveNavShell`, above both
  the rail and the page. The wordmark left the rail, which now opens at Create.
- **`showAtriaGlobalSearch`** (`lib/shared/widgets/atria_global_search.dart`) —
  the panel the band's search opens: navigation pages, plus live invoice matches.
  It starts no query until something is typed.
- **`AtriaPageHeader` / `AtriaPrimaryAction` / `AtriaHeaderIconAction`**
  (`lib/shared/widgets/atria_page_header.dart`) — the in-page heading with its
  actions at the right edge, wrapping under the title on phone widths.
- **`AtriaFilterBar` / `AtriaAdaptiveFilter<T>` / `AtriaFilterSelect<T>`**
  (`lib/shared/widgets/atria_list_toolbar.dart`) — one filter control that is a
  labelled select on a desktop window and the segmented pill row on a phone.
  `periodSegments()` (in `period_selector.dart`) gives every screen the same
  three windows under one `Date:` label.
- **`TransactionTableTotals`** (`transaction_list.dart`) — the column sums as a
  total line closing the table; the flat header strip gained a hairline.
- **Deleted `AtriaGradientFab`** and the `EditorShell.floatingActionButton` hook:
  the action bar carries Save on every width, so the FAB only duplicated it.
- Screens migrated: Sales, Purchase, Products and services (was "Items"),
  Parties, Payments, Expenses, Stock summary. App bars: 24 → 17, and the 17 that
  remain are editors and detail pages, which QBO also gives a strip.

Still not QBO, and deliberately so: there is no email transport, so the invoice
editor's primary action stays "Save and close" rather than "Save and send";
Customers and Vendors share one Parties screen (QBO keeps them apart) so the
page title stays "Parties" while the filter names the side; and the dashboard
keeps KPI tiles and a stock-value stat strip, which QBO spreads across reports.

Regression cover updated in step: the shell now needs a `ProviderScope` (its
chrome reads the active firm), and three assertions that encoded the old titles
and controls were moved to the new ones. `dart analyze lib test` is clean,
**106/106 tests** pass, and the `light_sales` / `light_items` / `light_parties`
goldens were regenerated with no overflow or exception in the render.

---

## 6. The forms themselves: Excel-simple entry, Tally-precise totals

Sections 1–5 rebuilt the chrome. This pass rebuilt what a user actually spends
their day inside — the create/edit screens — around one sentence: *type it like
a spreadsheet, read it like a ledger.*

### One anatomy, five editors

Before: the invoice editor was a single centred column with the totals under the
last line, while the purchase bill still used a **two-pane form + sticky
summary rail**, and the expense, item and party editors each hand-rolled their
own section cards with a second `FilledButton` at the foot of the form. Three
different ideas of "a form".

Now every editor is the same page, top to bottom — the two-up header band
(subject on the left, dates on the right), the line grid, the totals
right-aligned under the last line, then the collapsible sections:

| Piece | Lives in | Used by |
| --- | --- | --- |
| `AtriaEditorForm` | `shared/widgets/atria_form_section.dart` | all 5 editors |
| `AtriaFormSection`, `AtriaFormFieldRow` | same | all 5 editors |
| `AtriaLineGrid`, `AtriaGridInput`, `AtriaUnitPicker`, `AtriaGstRatePicker` | `shared/widgets/atria_line_grid.dart` | sale, purchase |
| `AtriaTotalsBlock` | `shared/widgets/editor_totals.dart` | sale, purchase |
| `AtriaTaxModePill` | `shared/widgets/tax_mode_toggle.dart` | sale, purchase |
| `EditorShell.hint` keyboard strip | `shared/widgets/editor_shell.dart` | sale, purchase, expense |

The **purchase editor lost its side rail**: charges are edited in a link
section, so the rail only repeated the form, and the eye had to travel to it on
every keystroke. The **expense editor lost its bottom Save button** (one primary
action, in the action bar) and gained Save & new. The **item and party editors**
lost theirs too, and their `AtriaCard` + `SectionHeader` pairs became
`AtriaFormSection`s.

### Simple as Excel

`AtriaLineGrid` is a real sheet on a desktop window: a grey header band naming
each column, a numbered gutter, hairline separators, and cells that are
**borderless until focused** — on focus the theme's green ring outlines exactly
one cell, which is the spreadsheet's active-cell cue and nothing else moves.

Columns, identical on an invoice and a purchase bill: `Item / Description ·
HSN/SAC · Qty (+ unit) · Rate · Disc % · GST · Amount`.

- **Tab** walks the row, **Enter** advances and, at the end of the sheet, starts
  a new line with the caret already in its item cell.
- The gutter shows the line number and becomes a **delete** button on hover.
- The line's **unit is editable per line** (Tally's UOM), not just inherited
  from the item.
- **HSN/SAC is editable per line** on both sides — it was a read-only "HSN
  —" label on the invoice and absent entirely on the bill.
- Descriptions are no longer typed twice: the invoice line carried *two* fields
  bound to the same controller (`Item` and `Description`). One cell, one value.
- On a phone the sheet re-flows into a labelled card per line — the same
  widget tree, so the two layouts cannot drift.

A quiet strip under the sheet states the keyboard model once:
`Tab → next cell · Enter → next line · Ctrl+S → save & close`.

### Precise as Tally

`AtriaTotalsBlock` is now the only place the breakdown is written, so an invoice
and a purchase bill cannot disagree about what a total means: Subtotal, Item
discount, Invoice discount, Taxable value, **CGST/SGST printed with the rate**
(`CGST 9%`, not a bare `CGST`), IGST, Cess, the caller's extra charges, Round
off, Total. Per-line amounts come from the same `LineTotals` the document total
uses (`_LineController.taxLine` → one engine view per line), so the figure in
the Amount cell and the figure in the total are computed once.

### Overflows the revamp surfaced

Writing the layout guard (`test/editor_layout_regression_test.dart`) found four
pre-existing phone-width overflows that no test had covered, three of them in
editors that shipped before this pass:

- a `DropdownButton` sizes to its **widest item**, so any unexpanded dropdown
  overflows its field on a phone — party GST type (25px) and state (352px),
  purchase supplier (14px), expense category and payment mode (86/182px), item
  unit (31px). All now `isExpanded: true` with ellipsised items.
- the item editor's `SegmentedButton`s (icon + label per segment) do not shrink;
  the icons are dropped below 420px.
- `AtriaFormSection` was a decorated `Container`, which hides a `ListTile`'s
  background and ink and trips a framework assertion — it is a `Material` now.

### Verification

`dart analyze lib test` is clean and **122/122 tests** pass (106 before, +7 for
the new shared anatomy in `test/editor_anatomy_test.dart`, +9 mounting every
form at 1200px and 400px in `test/editor_layout_regression_test.dart`). The six
list-screen goldens are untouched: this pass changed editors, not list
screens.

## 8. The width of the page, and the phone layout

The feedback that opened this pass was *"why are we wasting left and right
area, also mobile should be proper"*. Both were real, and both were measurable:
the editor body was capped and centred (`EditorShellBody.single(maxFormWidth:
1140)`) and the phone grid had come out too tall and too quiet.

### The form owns the page

`EditorShellBody` no longer centres anything. The body is the form, full stop,
and `AtriaEditorForm` owns the only fixed measure on the page — a **page gutter
of 16 / 24 / 32** as the window grows (16 on a phone, 32 at 1600px+).

Measured off the real render (1680×950 window, 237px rail), by scanning the
rendered PNG for where content begins and ends (`tool/ink_extent.py`):

| | before | after |
| --- | --- | --- |
| line sheet, 1680px window | 1140px wide, ~120px grey each side | **1395px**, 24px gutter each side |
| phone gutter | 24px | **16px** (380 of 412px used) |

The extra width had to go somewhere useful, so:

- `AtriaSectionColumns` (new, in `atria_form_section.dart`) lays the section
  cards **two-up** once two real columns fit (≥1196px of body width) and stacks
  them below that. A section needs 592px before a second column is worth it,
  because under that its own `AtriaFormFieldRow`s collapse and the card is
  mostly margin. Party, item and expense forms now use the width this way
  instead of one long ribbon of half-empty fields.
- the header band's right slot (the dates) is capped at `min(520, 42%)`: a date
  pair stretched across half of a 1680px window reads as an empty field, not a
  roomier one, so the subject block absorbs the rest.
- the sheet's column shares were retuned for a wide sheet: the prose column
  (`Item / Description`, flex 6) carries the slack and the figure columns stay
  tight enough to read a column of numbers down.
- `EditorShellBody` lost its dead two-pane `summary` rail — every editor had
  moved to one column, so the old constructor was only a way to reintroduce it.

### The phone got its own cell style

`AtriaGridCellMode` (new, `shared/widgets/atria_grid_cell.dart`) is set by the
grid once it re-flows: in the **sheet** a cell stays borderless (the green focus
ring is the whole affordance, as in Excel); in the **stacked card** the same
cell is hairline-boxed, because there the labels sit above the cells and a
borderless input looks like plain text. `AtriaGridInput`, the item type-ahead
and both bare dropdowns read the mode, so a phone cell looks like a field
without the sheet growing boxes. `ItemTypeAheadField.decoration` became a
builder for exactly this reason — it is constructed above the grid but must ask
its question from inside it.

Cells also pair **two-per-row in the sheet's own column order** now (HSN | Qty,
Rate | Disc, GST | Amount, with the line's identity in the card header) instead
of pairing only numeric neighbours and stranding a lone field on its own row,
and the boxed unit picker gets 78px inside the Qty cell where the sheet gives it
50.

### Verification

`dart analyze lib test` clean; **125/125 tests** (+3 in
`test/editor_layout_regression_test.dart`). The three new ones pin the numbers
above rather than the pixels: the invoice sheet starts within 32px of the page
gutter and covers >90% of a 1680px window while the totals block stays ≤470px;
the party sections are two columns at 1680px and one column (16px gutter) at
400px; and a grid cell's border is transparent in the sheet and visible on a
phone. Every form also now mounts at **1680px** in the parametrised layout
guard, so the wide layout is covered too.

`tool/visual_dump_test.dart` gained `kWide` (1680×950) captures of the invoice,
bill, item, party and expense editors, and `tool/ink_extent.py` measures the
margins of any of them.

## 9. Bringing existing books across: the Vyapar importer

Migration is the one parity feature a competitor cannot copy, and it is the
question every Vyapar user asks first. This pass adds
**Settings → Data & backup → Import from Vyapar**: pick a `.vyb` backup, see what
is inside it, and the company lands in Atria as its own firm.

### What a `.vyb` actually is

Not an export format at all. It is a ZIP archive holding exactly one `.vyp`
entry, and that entry is an **unencrypted SQLite 3 database** — Vyapar's own
working file. There is no parsing of proprietary structures: the tables
(`kb_firms`, `kb_names`, `kb_items`, `kb_transactions`, `kb_lineitems`,
`kb_paymentTypes`, `kb_tax_code`, `kb_txn_links`, `txn_payment_mapping`) are
read directly, with only the columns that exist, because Vyapar's schema grows
between releases.

Document type codes were decoded from Vyapar's **own seed data** —
`terms_and_conditions` names the document and `tnc_txn_type_mapping` maps that
template to its type code — rather than guessed:

| code | document | Atria `docType` |
| --- | --- | --- |
| 1 | Sale Invoice | `invoice` |
| 24 | Sale Order | `sales_order` |
| 27 | Estimate / Quotation | `quotation` |
| 83 | Proforma Invoice | `quotation` |
| 30 | Delivery Challan | `delivery_note` |
| 2 | Purchase Bill | `bill` |
| 28 | **Purchase Order** | `purchase_order` |
| 3 / 4 | Payment In / Out | `payments` |

`28` being a purchase *order* rather than a bill is the trap here: it is paid in
advance, so its `txn_payment_mapping` rows look exactly like a settled bill's.
Anything not in the table is counted and named in the result instead of being
guessed at, so a backup holding returns or journal entries says so rather than
corrupting stock or the GST returns.

### The rules that make the imported books agree with the old ones

Verified against a real 275 KB backup (Apex Integrations, 18 parties, 67 items, 57 transactions):

* **Line rates are GST-exclusive.** `kb_lineitems.priceperunit` is the taxable
  rate even where `txn_tax_inclusive` is set, so Atria's own GST engine
  reproduces Vyapar's line totals instead of inflating them.
* **Balances come from Vyapar.** `txn_balance_amount` already nets the payments
  recorded in `txn_payment_mapping` — but *not* the payments recorded as
  transactions of their own, so only those are subtracted again. Getting this
  backwards would have halved every partially-paid invoice.
* **Stock is reconciled, not double-counted.** An item's opening stock is
  Vyapar's *current* stock minus the net effect of the invoices and bills being
  imported, so closing stock lands exactly on Vyapar's figure. (The same
  question, inverted, for party balances.)
* **Opening balances absorb the remainder.** A party's opening balance is
  Vyapar's balance minus what the imported documents explain — which came out at
  **₹0.00** for all 18 parties, i.e. the documents explain everything, and the
  figure only moves when a backup holds something Atria does not import.
* **Numbers are kept.** A Vyapar invoice numbered `19` stays `19`; only genuine
  repeats inside one series get a `-2` suffix.

Result on the real backup: 18 parties, 67 items, 90 documents (27 invoices, 23
quotations, 1 bill, 3 purchase orders, 3 payments-as-documents), 19 payments,
0 skipped → invoices total ₹10,72,956 with **₹1,73,203 outstanding, exactly the
party balance Vyapar was showing**.

### Bugs this surfaced in existing code

Bulk creation is the harshest test of id generation, and four generators were
derived from the clock alone. Windows reports time in coarse ticks, so
back-to-back inserts produced **identical primary keys**:

* `ItemRepository.createUnit` and `createCategory` (millisecond only) — an
  import of 67 items creates several units in the same tick.
* `AuditRepository.log` (microsecond only) — one row per mutation, 200+ in an
  import.
* `FirmRepository._uuid`, `PartyRepository._newId`, plus the payment and expense
  ids, were the same shape with a clock component appended.

All now use `IdUtils.newId()` (time-ordered UUID v7), keeping their readable
prefixes. `stock_movement_ids.dart` had already been fixed this way, with a
comment describing exactly this failure.

The importer also passes `affectStock: false` for Vyapar orders and estimates,
because `SalesRepository.save` excludes quotations and delivery notes from the
stock ledger but **not** `sales_order` — saving one deducts stock.

### Verification

`dart analyze lib test` clean; **135/135 tests**, +10 in
`test/vyapar_import_test.dart`. The suite builds a miniature `.vyb` from scratch
(same table and column names, zipped with a SQLite file inside) so it runs
anywhere, and additionally imports the developer's real backup when one is on
the desktop, asserting the outstanding total reconciles to Vyapar's own figures.
It covers the document-type decoding, preview-without-writing, party typing
(Vyapar does not separate customers from suppliers — the documents decide), the
expense heads that are names but not parties, stock reconciliation, number
de-duplication, and the rollback that removes a half-imported firm.

### GST registration: the company, and each party

Two different questions, and Vyapar answers them in two different places.

**The company.** `kb_firms` has no registration flag at all — a company with no
GSTIN is simply one that is not registered. The switch lives in
`kb_settings` as **`VYAPAR.GSTENABLED`**. When it is `0` (or the firm row holds
no valid 15-character GSTIN) the import now: leaves the firm's GSTIN and PAN
null, keeps the state code from `firm_state` (its address and the place of
supply still need it), applies **no inter-state IGST anywhere** — inter-state
already requires a firm GSTIN — and says so in its own warning rather than
looking like a clean import. It deliberately does **not** zero the tax Vyapar
recorded: that would rewrite the totals the user recognises.

**Each party.** The authoritative field is **`name_customer_type`**
(1 = registered, 0 = unregistered), not the GSTIN's length. The real backup
confirms it: all 11 parties with `1` carry a 15-character GSTIN and all 7 with
`0` carry none. It now maps straight onto Atria's `gstType`. A party flagged
registered whose GSTIN is unusable is marked unregistered — nothing downstream
can treat a GSTIN-less party as B2B — and the drop is reported instead of
happening silently.

**The bug behind the question.** Inter-state was being derived from the two
state codes alone, so an unregistered buyer in another state was charged IGST
while the sale editor charges the identical invoice CGST/SGST. The importer now
uses the editor's exact rule: both sides GST registered, *then* compare states.
This is not only a split problem — GSTR-1 uses `isInterState` to separate
**B2CL from B2CS**, so a large unregistered inter-state invoice would have been
filed in the wrong table.

In the real backup: firm registered (GSTENABLED=1, `36CZFPM0045M2Z7`), 9 parties
registered in Telangana, one registered each in **Assam** and **Delhi** (those
two correctly attract IGST), and **7 unregistered parties with no state
recorded** — for those the place of supply falls back to the one Vyapar stamped
on the transaction, which is better than leaving it blank.

**Verification:** `dart analyze lib test` clean; **139/139 tests**, +4 in
`test/vyapar_import_test.dart`, one per case above.

## 10. Polishing every screen: one scale, not dozens of hand-tuned values

The revamp of §6-§9 rebuilt the *anatomy* of every screen. This pass went after
what was left: the same widget drawing itself slightly differently on different
screens, and a design system that was declared but not used.

### The measurement had to be fixed first

The layout audit (`tool/visual_audit_test.dart`) walks the element tree and
reports, per screen, every distinct text style, icon size, radius, padding and
contrast failure. Its numbers were wrong.

`StatefulShellRoute.indexedStack` keeps every visited branch alive and lays the
inactive ones out at the *same origin* as the active one, so each screen's
report contained the dashboard's widgets at identical coordinates — the tell was
`"Total sales this month"` appearing at `272,166` in all six screen reports.
Flutter hides those branches with a private `_VisibilityScope` inherited widget
rather than `Offstage`, so the walk now skips it (and counts what it skipped, so
a future Flutter upgrade that renames it cannot silently reintroduce this).

Fixing that exposed a second problem: `/dashboard` was **never measured at
desktop size**. Initialization loads the persisted onboarding flag and active
firm *into* the same controllers the harness was setting, so setting them first
meant they were overwritten and the route redirected to `/onboarding`. The
report now prints the route it actually landed on (`landed on: /dashboard`) and
would have flagged `REDIRECTED`. Every finding below is from the corrected
harness.

### Field icons were 50% too big, on every screen

`InputDecorator` wraps `prefixIcon`/`suffixIcon` in
`IconTheme.merge(IconThemeData(size: 24))` — a hard-coded 24 that sits *inside*
the app's `iconTheme`, so it beats it. Every one of the ~55 field glyphs in the
product rendered at 24 while every other icon sat at 16-18. Two fields had
noticed and patched themselves with `size: 18`; they were the only two that
looked right.

`DropdownButton.iconSize` is the same trap: a literal `24.0`, no theme hook, 20
dropdown carets. `AtriaFieldIcon` now states the size once for fields, and every
dropdown states `iconSize: AppIconSize.md`.

Icon sizes across all 32 screens: **15 distinct → 12**, and the six remaining
are exactly the six `AppIconSize` tokens (14/16/18/20/22/44). The last stray
`24` is gone; the 28/40/53.4px glyphs (an empty state, a swipe hint, and an
onboarding hero sized `size * 0.46`) are now `AppIconSize.empty`.

### Five avatars became one

A private `_Avatar` in the party list plus four hand-rolled `CircleAvatar`s
(dashboard, party transactions pane ×2, payments) used radii **16/18/20/22/24**,
four initials font sizes — one derived as `radius * 0.82`, which is where the
app's single 14.8px text style came from — and three different tints. The same
firm name rendered as **"SB"** in the party list, **"ST"** in the top bar (first
and last word) and **"S"** in the transactions pane.

`AtriaAvatar` has two radii, six tones built from token pairs, and one initials
rule. Both pairs are surface-plus-its-own-ink, never an accent on a tint of
itself: the dashboard's brand-green-on-pale-green initials measured **2.54:1**,
failing AA outright.

### The page frame could still be re-implemented

The party editor hand-rolled the scroll view, the gutter and the section columns
that `AtriaEditorForm` already owned, so on a 1680px window it kept a 24px
gutter where the invoice, item and expense editors stepped to 32, and a 16px
section gap where they used 12. It now uses the shared frame — `header` became
optional for forms with no document band.

The same drift existed one level down: `AtriaListPage` applied a 20px gutter to
the heading, search and filters, while five list bodies spelled their own
*16*px inset into their `ListView`, so on a desktop window the rows sat 4px left
of the search box directly above them. The frame now owns the body gutter too,
and `AtriaPageHeader` uses the gutter token (it was a literal 20, which on a
phone put the heading 4px right of everything it was heading).

`AtriaResultsBar` carried its own 20px inset *and* inherited the list's, so
Sales' results line sat 16px right of the rows it summarised.

### Every empty state was off-scale

`EmptyState` alone carried a 28px glyph, 10px and 14px radii, a 36px inset and
an 18px gap — which is why the same empty state looked different on Purchases,
Expenses and Parties. Radii: **11 distinct → 8**; the remaining `2.0` was
`AppSpace.xxs` used as a *radius* on two chart legends.

### The plural bug the audit caught

`AtriaResultsBar` appended a bare `s`, so the party list read **"6 partys"**.
`Formatters.pluralise` now handles the two English rules the app's nouns need
(`party → parties`, and sibilants → `es`), with an override for irregulars.

### Off-scale type, removed

`12.5px` (Sale detail hero label), `10px` (the line grid's phone column heads,
below the app's own 11px floor), `32px` (the hero total), and the derived
`14.8px` — all now `labelMedium`, `labelSmall`, `displayLarge` and a token
avatar respectively. 119 distinct paddings remain (the nav rail's 14/8/10/8 and
its 2px indicator corner were two of the most-rendered, and are now 16/8/12/8
and the pill token) — that is the honest remaining debt, and the two screens
with none of it are Dashboard and Reports, which use **zero** `AppSpace` /
`AppIconSize` / `AppPage` tokens between them.

### Save moved to where the thumb is

Every editor put its only Save in the app bar — the top-right corner of a 412px
viewport, under the hand holding the phone. On phone widths Save now lives in
`EditorBottomBar`, pinned above the bottom edge (and above the keyboard), with
Save & new beside it when the document has one; the app bar keeps the title and
the exit. Desktop is unchanged.

### Verification

`dart analyze lib test` clean. **139/139 tests pass**, including
`editor_layout_regression_test.dart`, which pins exactly one
`FilledButton('Save and close')` at 1680px, 1200px **and 400px** — so the bar
moved on phones without the button multiplying. The six light-mode goldens were
regenerated. Audit deltas: icon sizes 15 → 12, radii 11 → 8, stray 24px icons
123 → 0.

## 11. Production-readiness pass: a line-by-line bug hunt

The §6-§10 passes rebuilt how the app looks. This pass read the write paths,
the GST engine's callers, every editor's save flow and the export services end
to end, and fixed what a line-by-line read turned up. Grouped by where the
money would have gone wrong.

### Stock ledger

| Bug | Fix |
|---|---|
| Saving a **sales order** deducted stock — the save path excluded only quotations and delivery notes, so the importer worked around it with `affectStock: false` while a directly-saved order still drained the ledger | The exclusion set is now one named constant (`quotation`, `sales_order`, `delivery_note`) in `SalesRepository.save`, and `restore()` shares the *same* rule — previously restore re-posted stock for a quotation/order/delivery note that had never deducted, so a delete+restore cycle *gained* stock |
| A **cancelled** invoice, restored from the bin, re-applied the stock its delete had reversed | `restore()` skips cancelled documents' stock re-application (the same documents the ledger treats as settled) |

### GST returns (wrong table = wrong filing)

| Bug | Fix |
|---|---|
| **GSTR-2A reconciliation never matched anything.** The books side was keyed on Atria's *internal bill number*, the portal side on the supplier's invoice number — two unrelated strings | Books key on `supplierInvoiceNumber` (falling back to the internal number only when absent) |
| **GSTR-3B Table 3.1(c) was always 0.** Nil-rated/exempt sales (every line 0%) were lumped into 3.1(a) taxable outward supplies | An all-zero-tax document now lands in 3.1(c); a taxable supply always posts tax > 0, so the discrimination is safe |
| **CDNUR** flagged a credit note B2CL at `taxableValue >= 250000` while the invoice bucket used strict `>` — a ₹2,50,000.00 note was filed in a table the portal would reject | Same strict `>` as the B2CL bucket |

### Editors (crashes, resurrections, silent wrongs)

| Bug | Fix |
|---|---|
| Ctrl+S on a purchase editor's **"Bill not found"** state crashed — `SaveShortcut` stayed armed and `_saveCore` dereferenced a null `_existing!` | The save path re-reads the bill and reports "This bill no longer exists" instead |
| **Editing a binned document resurrected it.** Every editor loaded through `getById` (which does not filter deleted rows); the repositories' upsert then cleared `isDeleted`, re-posting stock and re-counting balances for a document no list shows | Sale, purchase, expense, item and party editors all refuse a deleted row — with a message — and the sale editor's save re-checks before writing |
| **Opening an editor armed the unsaved-changes guard.** Controller listeners were attached in `initState` *before* the async prefill, so every programmatic `text =` fired `_markDirty`; the comments claiming "listeners only fire on user input" were wrong (item, party, and the sale line controllers registered them **twice** — prefill marked dirty *and* keystrokes notified twice) | The sale line controller listens exactly once, after prefill; the item and party editors clear the flag once prefill completes (the form is a spinner until then, so no user input is lost) |
| A **due date before the invoice/bill date** was pickable — the document landed in the overdue reminders the moment it was saved | Both date pickers floor the due date at the document date (legacy rows clamp instead of asserting) |
| **"Mark as fully paid" appeared on credit notes** where it silently did nothing — the repository zeroes `balanceDue` for non-invoices | The checkbox renders only for invoices |
| The **credit-limit banner** kept quoting the pre-save outstanding after Save & New | It reloads the party's outstanding after every save |
| Editing a bill silently **re-enabled round-off** (`_prefill` hardcoded `true` — the sale editor already recovered the flag from the stored column) | Recovers it from `roundOff != 0` like the sale editor |
| The expense editor happily **overwrote an income row's category** with an expense one when a deep link carried the wrong `type`, and accepted a **GST amount larger than the total** | Type mismatch bounces with the deleted rows; GST ≤ total is validated |

### Exports

| Bug | Fix |
|---|---|
| The Excel **statement's closing balance sat in the Debit column** | It lands under Balance |

### Verified

`dart analyze lib test` clean. **139/139 tests pass.** Windows release rebuilt
(`build\windows\x64\runner\Release\data\app.so`) and the Android APK rebuilt
(still debug-signed — no release signing config yet; that remains the one
known blocker between this code and a Play Store upload).

## 12. Field-report pass: what the first real books surfaced

The first user report after §11 — with screenshots from the imported Apex
Integrations books — named eight issues. Every one traced to a real defect:

| Report | Root cause | Fix |
|---|---|---|
| Dashboard cards have no proper borders | `_KpiCard`, `_InvoiceTile`, `_AlertCard` and the hero skeleton drew shadow-only decorations, and on a bright wall / low-contrast monitor a 4%-opacity shadow is invisible | Hairline `outline` borders on every dashboard card; `AtriaCard` and the shared `TotalsCard` / `TransactionRow` gained the same border so no surface in the app is shadow-only |
| Amount/Balance columns not properly shown | `TransactionTableRow`'s money cells stretched to their full `Expanded` width (left-aligned text in a right-aligned column) and the totals line ran each `label value` pair inline, sliding left of the Amount column | Money cells right-align under their right-aligned headings; the totals line stacks label-over-value, right-aligned per column |
| Payments received has no Edit | The payment sheet was create-only; the row kebab had only Delete | `PaymentRepository.update()` (recomputes both linked documents — an edit can re-point the link) and an Edit action opening the same sheet pre-filled |
| Bill MC2025-26/7164 (27 Mar) missing from Bills | Every list defaulted to **This Month**; March is outside September's window. The bill was never lost — the filter hid it | Confirmed no data bug; the period filter (This Month / This FY / All Time) is the answer, and the totals card + search work over the filtered window as designed |
| Imported purchase orders not visible | The purchase list offered only Bills / Debit notes — a `purchase_order` document had **no segment, no rail entry, no numbering series** | New **Purchase orders** tab + rail entry; `DocSequence.purchaseOrder` with a `PO-` prefix (**schema v5** migration); convert-to-bill flow (`?from=` seeding, `markConverted` badge, stock stays untouched until the bill lands) — the mirror of the sales-side quotation → invoice flow |
| There should be a purge endpoint in Settings | Purging existed per row in the recycle bin only | **Empty recycle bin** in Settings → Data & backup: counts the bin first, blocks behind typing PURGE, purges every entity class row by row, reports how many were refused for sitting in a locked period, and writes one audit entry |
| Company profile is centred, make it full screen | The firm editor capped itself at 760px inside a `Center` | Full width; `_FieldRow` already groups fields two-up so the width is used |
| Dashboard company switcher shows nothing | `_showFirmSwitcher` read `allFirmsProvider` with a one-shot `.valueOrNull` — an unwatched FutureProvider is still loading at tap time, so the sheet opened empty | The sheet is a `Consumer` that **watches** the provider (spinner → list), and the dashboard warms it in `build` |

Two further defects the pass surfaced while in the files:

- **Paying a bill flipped it back to Unpaid.** `PaymentRepository._recomputeLinkedDoc`
  signed every linked payment as `+payment_in / −payment_out`, so a bill
  settled by a `payment_out` derived a negative paid amount the moment any of
  its payments was deleted or restored. The sign now follows the linked
  document's side of the books (receipts for invoices, payments-out for bills).
- The purchase rows showed payment status for orders ("Unpaid") instead of
  their lifecycle — orders now badge **Converted** once billed, like the sales
  side.

### Verified

`dart analyze lib test` clean; **139/139 tests pass** on the v5 schema (the
suite's in-memory databases exercise the migration path). Windows release and
the Android APK rebuilt.

## 13. App-wide UI/UX + logic sweep (Vyapar screenshots)

Triggered by a batch of Vyapar screenshots and a "there are bugs ui/ux and
logics app wide" report. Every item below is a real defect found by reading the
code, not a cosmetic preference.

### Lists

| Bug | Fix |
|---|---|
| **The sales Status column always read "Confirmed".** `_statusText` returned the *document* status for every type, and every saved invoice is stored `status == 'confirmed'` (`SalesDraft.status` default; the editor only preserves it on edit). So a settled invoice, a partially paid one and a long-overdue one all printed the same word, and Paid / Partial / Unpaid were never visible anywhere in the list. Credit notes and delivery notes also inherited lifecycle words that say nothing about them | The status word is now TYPE-AWARE: an invoice returns `null` (falling back to its payment state, with **Overdue** when a balance is past its due date — the same rule the dashboard and reminders use), estimates and orders show Open / Converted / Draft, delivery notes and credit notes show Issued / Draft, cancelled wins everywhere |
| **A text search could not fail.** `ExpensesScreen._matches` compared the digit-stripped query against the raw amount without first checking it was non-empty — and `String.contains('')` is true for every string, so searching "zzz" matched every row and "No matches" was unreachable | The numeric branch is gated on a non-empty stripped query |
| The **Date filter was invisible in the empty state.** With "This Month" selected (the default) a list with no rows in that window said "No invoices yet" / "No purchase bills" — which is exactly how "my March bill is missing" was reported twice | Sales, purchase and payments empty states now name the window (`Nothing in This Month`) and point at **All Time**. The list screens themselves are unchanged |
| **Payments had no date filter**, so the "Cash & Bank balances for the period shown" summary actually totalled all of history | Payments gained the same `Date:` filter as every other list, and its empty state names the window |

### Payments

| Bug | Fix |
|---|---|
| The payments list built a **fresh Drift watch inside `build`** (`repo.watchList(...)` inline). Every keystroke in the search field handed the `StreamBuilder` a different stream: it unsubscribed, dropped its data and flashed the full-page spinner while the user was still typing | The stream is cached per (type, period) like the sales and parties lists, and the row count / summary read from the cached snapshot |

### Dashboard

| Bug | Fix |
|---|---|
| **"Cash in hand" was month-to-date net receipts.** `totalReceived − totalPaid` are windowed figures, so a business that simply had not been paid this month read **₹0.00** in hand while still owed money | `DashboardSummary` gained lifetime `cashIn` / `cashOut`; the hero nets those, and the windowed totals stay where they belong (the KPIs, which now carry a `This month so far · since <date>` caption so Purchases ₹0.00 next to a non-zero GST figure cannot be misread as a lifetime total) |

### Recycle bin

| Bug | Fix |
|---|---|
| Every amount was interpolated as `'₹${Money.of(x)}'` — raw `Decimal.toString()`, so `₹18000.0` instead of `₹18,000.00`, and the `₹` was hardcoded rather than the currency token | Amounts go through `Formatters.money` |
| The "delete forever" warning was hard-coded to `'party records'` / `'item records'`, so binning a **payment** warned about items and parties | Each tab passes its own `purgeNote` (locked period for documents, "used on any invoice" for parties, "has stock history" for items); the empty state is no longer parties/items-specific either |

### Navigation robustness

| Bug | Fix |
|---|---|
| Four call sites dismissed a dialog / bottom sheet and then pushed a route **through the same, now-deactivated context** (`Navigator.pop()` then `context.push(...)`) — the parties action sheet's View Statement and Edit Party, and both of the global-search dialog's open paths. This is the same failure class as the Android blank More-sheet fixed earlier, and it is timing-dependent, so it works in debug and breaks under load | The router is resolved *before* the pop (`final router = GoRouter.of(context)`) and used for the push |

### Deliberately not changed

- **Negative Stock value shown in the hero** (`−₹9.74 L` in the screenshot) is
  arithmetic on real data, not a display bug: negative on-hand quantity is
  allowed by design (billing can precede the purchase entry — Vyapar warns
  rather than blocks too, and the importer's own test asserts a negative
  balance), and the same `currentStock × salePrice` sum backs the Stock screen's
  "Stock at sale" and the Items "Stock value (sale)" tiles. Valuing the hero at
  cost instead would have made three screens disagree. Left as-is on purpose.
- **Custom date range on the lists.** Reports already had one
  (`ReportsScreen._Period.custom`); the lists still offered This Month / This FY
  / All Time. That is a feature, not a defect, so this pass only made the
  existing window visible in the empty state. Shipped in §14.

### Verified

`dart analyze lib test` clean. **141/141 tests pass** (two new regression tests
in `test/list_ux_regression_test.dart` cover the expenses search and the sales
status label). Windows release rebuilt
(`build\windows\x64\runner\Release\atria.exe`) and the Android APK rebuilt
(75.4 MB).

## 14. Custom date range on the lists

The one gap §13 named and left as a feature: Reports had a Custom period
(`_Period.custom`) while Sales, Purchase, Expenses and Payments offered only
This Month / This FY / All Time. Reconciling a single quarter meant opening All
Time and scrolling past everything else.

### One window type, four screens

| Piece | What it does |
|---|---|
| `PeriodRange` (`lib/shared/widgets/period_selector.dart`) | The window itself: `from` / `to` to query with, the label to print, the two picked days, and one `cacheKey` per distinct window. A custom window closes at the end of its last day (23:59:59) and orders its two picks, so choosing "To" before "From" still gives a sensible range instead of an empty one |
| `PeriodCustomRange` | The hairline From/To pills, ported from the reports screen's `_datePill` — same `showDatePicker`, same `firstDate: 2020` / `lastDate: today` — so a custom window is chosen and reads the same in both places |
| `periodSegments()` | Now offers Custom beside the three named windows, so all four `Date:` filters gained it at once, wide (select) and phone (pill row) alike |
| `PeriodRange.emptyWindowMessage(noun)` | One sentence for the period-aware empty state — "between dd MMM and dd MMM. Widen the range…" for custom, "from dd MMM onwards…" for the named windows — instead of four near-copies |

The named windows deliberately stay **open-ended at the top** (`to == null`),
as they were: a document dated later today must never be cut off. Only a custom
window closes.

### Wiring

- **Sales** — `_SaleList` takes the whole range and keys its cached Drift watch
  on `cacheKey` instead of on `from` alone, so moving only the To day
  re-subscribes.
- **Purchase and Payments** — the same change to their cached `_streamFor`
  keys, with `watchList(..., to:)` carrying the upper bound the repositories
  already supported.
- **Expenses** — `_periodProvider` became `_rangeProvider`; both row providers
  (Expenses and Other income) query through it, and the Net P&L title reads the
  range's label. Its empty state now distinguishes "nothing recorded" from
  "nothing inside this window" like the other three lists, with the create
  action reserved for All Time.
- **No repository changed**: `from` / `to` were already there, applied as
  `isBiggerOrEqualValue` / `isSmallerOrEqualValue`. Only the screens never
  passed `to`.

### The overflow the new tests caught

Dropping two date pills into the desktop filter strip overflowed its `Row` —
96px at an 800px window, and worse at a large text scale. Two fixes: the wide
filter strip is now a horizontal scroll region (the phone pill row always
was), and `PeriodCustomRange` is a `Wrap`, so the pills stack instead of
clipping on a narrow window. Page actions stay pinned to the right edge.

### Verified

`dart analyze lib test` clean. **148/148 tests pass** —
`test/period_range_test.dart` adds seven: the window arithmetic (whole days,
ordered picks, open-ended named windows, per-window cache keys, Custom present
in the filter segments) plus two widget tests on the Sales list proving the
custom window really is closed at the top (an invoice dated 45 days out is
hidden by the To bound, while the same query without it returns the row) and
that the phone layout offers Custom and the pills that follow it. Windows
release rebuilt (`build\windows\x64\runner\Release\`) and the Android APK
rebuilt.

## 15. Migrating from Swipe: `tools/swipe_to_vyb.py`

Atria could already read a Vyapar company backup, and that importer is the one
place GST, stock, numbering and party balances are reconciled. Swipe therefore
gets no second importer: the migration is a **converter** that reads Swipe's
official Partner API and writes a Vyapar-shaped `.vyb`, which Atria imports
through the path that is already tested against a real backup.

### The source

`https://app.getswipe.in/api/partner`, `Authorization: Bearer <API key>` (a key
generated in the dashboard's API Integration tab, scoped to one company, rate
limited to 1 request/second). Endpoints used:

| Endpoint | Gives |
|---|---|
| `GET /v2/doc/list?document_type=&start_date=&end_date=&payment_status=&num_records=&page=` | one page of documents per type |
| `GET /v2/doc/{hash_id}` | the document in full — party, address, items with tax rate and HSN, discounts, amounts |
| `GET /v2/payment/list?start_date=&end_date=&status=success` | payments in and out, each with `linked_docs[]` |
| `GET /v2/product/list`, `/v2/customer/list`, `/v2/vendor/list` | catalog and parties |

The list endpoint deliberately carries no line items, so the converter fetches
each document by `hash_id` and caches every response to disk: a second run
rebuilds offline with `--from-json`, and a network hiccup is not a re-export.

### The two traps the verification caught

| Trap | Fix |
|---|---|
| **Swipe's `amount_pending` is already net of payments.** Emitting it as Vyapar's `txn_balance_amount` alongside a linked payment transaction made Atria deduct those payments twice, so a fully settled bill kept showing a balance | `txn_balance_amount` is now `total − payments recorded on the document itself`, exactly the figure Vyapar stores (its own docs note that separate payment transactions are *not* deducted there), and the importer's link subtraction lands on Swipe's pending figure |
| **A payment transaction's amount lives in `txn_cash_amount`.** The first generated file put the amount nowhere the importer reads: both standalone payments were silently counted as `skipped` and only the document-level UPI receipt came through | Payments now carry their amount in `txn_cash_amount`, matching what the real Vyapar backup does |

Both were caught by the new test, not by reading the code — which is the point
of asserting on the imported books rather than on the generated SQL.

### Verified

`dart analyze lib test` clean; **152/152 tests pass**, four of them new in
`test/swipe_vyb_import_test.dart`, which imports the generated fixture through
`VyaparBackupReader` + `VyaparImportService` and asserts the books: two invoices
with their lines and intra-state CGST/SGST, a purchase bill part-paid by a cash
payment out (₹5,000 paid, ₹4,440 still owed — not ₹940 either way), a standalone
NEFT receipt settling its invoice, a UPI receipt from the document's own payment
modes, party types inferred from which side of the book each party appears on,
and a cancelled invoice skipped rather than imported as a sale.

### Known limits (stated, not hidden)

- **Expenses.** Swipe's Partner API exposes no expense endpoint (the document
  types are invoice, purchase, estimate, pro-forma, delivery challan, purchase
  order and the returns). This script still takes an expenses export from that
  page (`--expenses-file`); §16's web-session exporter reads the module itself.
  Either way expenses are written the way Vyapar writes them — heads as
  `name_type = 2` categories plus `journal_entry` rows — and **now import as
  Atria expenses**; §16 taught the reader to decode those journals.
- Sales and purchase returns have no Vyapar document code Atria maps, so they
  are reported and skipped rather than guessed into a credit note.
- Cancelled documents are skipped (they are not books) and named in the summary.
- The firm's own GSTIN cannot be read from the API: pass `--firm-gstin` (the
  state follows from it) or every supply is treated as local, which the run
  warns about.
- `tools/sample_swipe_cache/` holds canned API responses so the converter and
  its test can run with no account at all.

## 16. Migrating from Swipe without an API key: `tools/swipe_web_to_vyb.py`

§15 needed a Swipe **Partner API key**, and on this account that turned out to
be behind a paid plan ("that is premium version"), which left the whole
converter unusable for the person it was written for. Swipe's API access and
Swipe's *web app* are not the same thing, though: the web app has to read the
same book, so its own calls are available to anyone who is signed in.

So the export now has a second front door. `tools/swipe_web_to_vyb.py` makes the
calls `app.getswipe.in` makes in the user's own browser session and writes
**exactly the same `.vyb`** as §15 — same format layer, same `Books` model, the
same `VyaparWriter`. There is still no second importer, and therefore still no
second set of rules for GST, stock or party balances.

### Getting the token

Sign in, open the browser console, and `copy(localStorage.accessToken)`. That is
the whole setup: the token is a bearer token for the session and it is sent only
to `app.getswipe.in`. Testing confirmed the API accepts **only** that header —
the `DeviceHash`, `X-Request-ID`, `sentry-trace` and `Request-Timestamp` headers
the app also sends are not checked, so a copied token is genuinely sufficient.

### The endpoints, and how they were found

The web API is undocumented. Every route here was recovered by reading the
build's own JavaScript (`getAPI("menu", "path")` call sites in the lazy-loaded
chunks) and then confirming each one against the live session:

| What | Call | Notes |
| --- | --- | --- |
| documents | `POST /api/v2/doc/get_transactions` | `page` is **0-based**; `payment_status: 3` means every status, as the app itself sends |
| one document | `POST /api/v2/doc/get_invoice` | takes `new_hash_id` — **not** `hash_id`, **not** `id` — plus `document_type`, `is_pdf: false`, `identifier` |
| payments | `POST /api/v3/payments/timeline` | the settled document is `linked_docs[].doc_serial_number`; the row's own `serial_number` is the *payment's* number |
| expenses | `POST /api/expenses/get` | the module §15 could not reach at all |
| one expense | `POST /api/expenses/get_expense` | by `serial_number`; only called when the list row lacks a category or amount |
| parties | `POST /api/v2/customer/get`, `/api/v2/vendor/get` | rows arrive under `allData` |
| items | `POST /api/v3/products/search` | `variant_id` is part of the identity, or variants collapse into one item |
| categories | `POST /api/expenses/get_categories` | `indirect_income` heads are income, not expenses, and are left out |

Three things about this API are worth writing down because each one presents as
a different, plausible-looking failure:

* **`get_transactions` 500s on an incomplete `filters` object.** Every key
  (`invoice_type`, `payment_mode`, `filtered_users`, `status`, `is_export`,
  `type_of_doc`, `prefixes`) must be present. A missing key looks like a broken
  token or a broken endpoint rather than a bad body.
* **`get_invoice` wants `new_hash_id`.** Passing the list row's `hash_id` as
  `id` returned "Document not found" from three different paths, which nearly
  killed the whole approach — the line items were reachable the entire time.
* **The web shape is not the Partner shape.** `qty`/`price`/`tax` here,
  `quantity`/`unit_price`/`tax_rate` there; `36-TELANGANA` for the state; dates
  as `08 Mar 2026` *and* `Sun, 08 Mar 2026 00:00:00 GMT` in the same record.
  A normalising layer maps all of it onto the flat documents the writer already
  expected, so `VyaparWriter` did not have to learn a second dialect.

### Expenses now reach the books

§15's "next piece of work" is done. Vyapar keeps an expense as a `journal_entry`
that debits an expense head and credits Cash or a bank account, and the reader
did not look at those tables. It does now, and `VyaparImportService` writes them
as Atria expenses.

The reader is deliberately **shape-based rather than taxonomy-based**, because
neither Vyapar's journal layout nor `other_accounts.account_type` is documented
anywhere Atria can verify. An entry is imported only when it is unambiguous:

* exactly two lines, one debit and one credit, of equal positive amounts;
* the debit/credit side readable from `amount_type` (or a negative amount);
* one side a Cash/bank account and the other side not — recognised by *name*
  (`cash`, `bank`, `a/c`, the usual bank names), because the account-type codes
  cannot be trusted across versions;
* a transfer between two money accounts, or a multi-line adjustment, is counted
  and reported rather than guessed at. A misread journal would move money
  between accounts silently, which is worse than not importing it.

Accounts Atria cannot classify stay out of the cash column, so an unknown ledger
can never be credited as if it were the bank.

### Verified

`dart analyze lib test` is clean, and the suite is **158/158** (was 152; six new
tests). `test/swipe_web_vyb_import_test.dart` imports a `.vyb` generated from
`tools/sample_swipe_web_cache/` and asserts the whole book: two invoices with
their lines and intra-state CGST/SGST, a supplier bill part-paid in cash
(₹5,000 paid, ₹4,440 still owed), a Net Banking receipt that settles its invoice
in full, a UPI receipt taken from the document's own payment modes, party types
inferred from which side of the book each party appears on, a cancelled invoice
skipped, **two expenses read back as expenses** (Rent ₹15,000 in cash, Internet
₹1,180 out of the bank, one of them only reachable through the detail call), and
Swipe's expense categories available to post against.

The two bugs the new tests caught were both in the mapping, not the format:
`catalog()` was keyed on the Partner API's `id` while web lines carry
`product_id`, so every line pointed at a phantom item and lost its name to the
line description; and the expense accounts were written under their lower-cased
lookup key (`rent`), so the reader's category did not match what the user typed.

The fixture also caught that Swipe sends an empty rich-text description as
`"<p></p>"`, which would have landed in every product's description field —
markup is now stripped and empty markup treated as absent.

### Known limits (stated, not hidden)

- Swipe's web API is private and can change without notice. Everything here was
  confirmed against build `v1.25.56-3-gef53999a1`; the script fails loudly with
  a readable message rather than importing a partial book.
- The session token is a credential. It is sent only to `app.getswipe.in`, and
  `--cache` stores responses, never the token — but a token pasted into a shell
  command stays in that shell's history, so `SWIPE_TOKEN` or `--token-file` is
  the better habit.
- Sales orders and pro-forma invoices are not in the web API's document types,
  so §16 covers invoices, bills, estimates, purchase orders, delivery challans,
  payments and expenses. §15 (Partner API) still gets the wider document set.
- Pagination past the first page has not been exercised: every list on this
  account fits in one page. The loop stops on a short page and on
  `total_records`, so a long book should walk correctly, but that is untested.
- Expenses are matched to `journal_entry` rows by shape. A real Vyapar company
  with manual journals of the same shape will see them as expenses — which is
  what they are, in accounting terms, but it is a behaviour change for existing
  Vyapar backups, not only for Swipe ones.

## 17. Counter sales and barcode labels: TSC and Zebra

The gap analysis called this out as the largest remaining functional hole for a
retail user: "POS + quick-bill mode, thermal printing" and
"multi-godown/batch-expiry/unit conversion" were the two lists where Atria could
not do what the shop's till does. The Counter sale screen and the label printer
stack close the first half of it. Batch/expiry and unit conversion stay open.

It is worth being precise about what "thermal printing" now means here, because
the gap analysis used that phrase for two different things and only one of them
is done. What exists is **label** printing: TSPL and ZPL, the command languages
of thermal *label* printers (TSC, Zebra). What does not exist is **receipt**
printing — ESC/POS, the language of a thermal till roll. A counter sale today
prints stickers for the goods; it does not print a customer receipt. Treat that
as the remaining half of item 12, not as a detail.

The work is four pieces: a printer profile, two encoders, two transports, and a
screen. Each was built to be inspectable on its own — a label that comes out
wrong is much easier to diagnose when you can read the bytes that were sent.

### The profile (`lib/core/printer/printer_profile.dart`)

`PrinterProfile` is what the operator configures once and every later print
reuses: brand (`tsc` or `zebra`), transport (`network` or `usb`), label size in
millimetres, dpi, darkness, speed, gap sense, copies, and the printer's address
or Windows queue name. It is a plain value type with `toJson`/`fromJson`,
`copyWith`, value equality, and `parseList`/`encodeList` so the whole set lives
in one settings row (`thermal_printers`) plus a `thermal_default_printer` id.

Two decisions worth recording:

* **Dots per millimetre come from the printer's own convention, not from
  `dpi / 25.4`.** TSPL *defines* a 203 dpi head as 8 dots/mm and a 300 dpi head
  as 11.8 dots/mm, and interprets `SIZE` with those figures. Deriving 7.992
  would lay every coordinate about 0.1% short of where the firmware looks —
  invisible on a short line and a millimetre out by the bottom of the label.
* **A hand-edited settings row is clamped, not rejected.** `fromJson` repairs
  out-of-range and missing values and `parseList` tolerates a corrupt blob by
  reading it as no printers, so a bad settings row can never block a shop from
  printing. The tests pin both behaviours.

### The encoders (`lib/core/printer/label_encoder.dart`)

`LabelDocument` is one sticker — title, barcode, symbology, price line,
strikethrough line, subtitle, footer, copies. `LabelEncoder.forProfile` picks
`TsplEncoder` or `ZplEncoder`, so **the brand is one branch in one place** and
the layout, the money formatting and the validation are shared.

Money arrives already formatted by Atria's own `Formatters.money`; the encoder
only translates glyphs the printer has (`₹` → `Rs`), because a second opinion
about how money reads is the one thing that must never disagree with the
invoice. Non-ASCII is not dropped, it is reported: a TSPL built-in font is
single-byte, so a Cyrillic or Devanagari cursor would desynchronise the string
literal, and the encoder refuses rather than printing mojibake.

Barcodes are validated before they are sent, per symbology — `BarcodeSymbology`
carries each one's TSPL name (`128`/`EAN13`/`39`) and ZPL command
(`^BC`/`^BE`/`^B3`) — and an EAN-13 check digit is *computed* and appended rather
than accepted from the user. A wrong check digit is refused with a readable
message instead of printed for a scanner to reject in front of a customer.

| | TSPL (TSC) | ZPL (Zebra) |
| --- | --- | --- |
| label size | `SIZE w mm, h mm` | `^PW`/`^LL` in dots |
| gap sense | `GAP a mm, 0 mm` | `^MNY` / `^MN` |
| darkness / speed | `DENSITY`, `SPEED` | `~SD`, `^PR` |
| barcode | `BARCODE x,y,type,...` | `^BYw,r,h` + `^BC`/`^BE`/`^B3` |
| copies | `PRINT n,1` | `^PQn` |

### The transports (`lib/core/printer/printer_transport.dart`)

`PrinterConnection` is an interface with the branch in `forProfile` alone,
because a TCP socket and a Windows print queue are genuinely different
problems.

* **Network** — raw TCP to port 9100. This is the one transport that works
  everywhere Atria runs (Windows, Android, Linux) with no native code and no
driver, which is why 9100 is the port every network label printer listens on.
* **USB / installed printer** — the Windows spooler, via `winspool.drv` over
  `dart:ffi`. Seven entry points (`OpenPrinterW` … `ClosePrinter`) bound **once
  and lazily**, since opening the library per job would leak a handle on every
  label. The print queue listing goes through `Get-Printer` rather than the
  registry, because the registry stores ports (`USB001`,
  `IP_192.168.1.50`) while the operator knows the names Windows shows them; a
  failure there degrades to a text field instead of blocking setup.

Failures are translated. A printer that is switched off, unplugged or on
another subnet surfaces as a sentence an operator can act on, never as a socket
error string. `probe()` exists so settings can answer "is this address right"
*without* wasting a label.

### The Counter sale screen (`lib/features/pos/pos_screen.dart`)

`/pos`, outside the navigation shell on purpose — the counter takes the whole
window, and it is reachable from the shell as "Counter sale (POS)".

It does **not** re-implement billing. It produces the same `SalesDraft` the
sales editor produces, through the same `GstEngine` and the same
`SalesRepository`, so a counter sale and an invoice are the same document with
the same tax arithmetic. That was the decision the user made when asked, and it
is the reason the screen is a cart and a payment pane rather than a second
billing engine.

* Search adds a barcode or name straight to the cart; quantity edits, line
  removal, and a party picker for a registered buyer.
* Intrastate/interstate, inclusive/exclusive and the tax mode come from the
  item and the party, exactly as the editor derives them — the screen shows the
  CGST/SGST or IGST split rather than deciding it.
* Completing the sale writes the invoice, then offers to print the labels for
  the lines that were just sold, and remembers the last job so `_reprintLast`
  can repeat it without re-reading the invoice.
* The cart only clears once the sale has actually been written — a failed save
  leaves the basket intact, which is the one behaviour a till must not get
  wrong.

Label printing is also reachable from the item editor, so stock can be labelled
when it arrives rather than only when it leaves. A loose item prints one
sticker; a quantity prints one per unit.

### Verified

`dart analyze lib test` is clean and the suite is **186/186** (was 158; 28 new).
`test/thermal_printer_test.dart` covers the parts that fail silently in the
real world: profile clamping and round-tripping, corrupt settings, EAN-13 check
digits (accepted when right, refused when wrong), per-symbology validation,
the TSPL and ZPL byte streams for both resolutions, the control-character
folding that stops an item called `Gear ^XZ` from terminating a ZPL job early,
the single-byte safety rule, rupee spelling, multi-label job assembly, and that
a whole sticker's contents fit inside the sticker.

Two of the tests are on the screen, because "the counter bills through the same
engine as the editor" is the claim the whole design rests on and it is worth
nothing unchecked. They scan an item the way a wedge scanner does (type, enter)
and then assert the *stored* invoice: ₹1,000 at 18% walk-in lands as taxable
₹1,000, CGST ₹90, SGST ₹90, IGST ₹0, grand total ₹1,180 with the round-off
applied, `isInterState` false, and — because "Taken in full" is the default —
a `payment_in` of ₹1,180 that leaves `balanceDue` at zero. The second test scans
a code that matches nothing and asserts the till says so and still refuses to
write a zero-rupee invoice.

Two bugs the tests caught were both real and both invisible on screen: the
203 dpi conversion above, and the control-character test itself, which turned
out to be asserting a double space that the whitespace collapse had already
removed.

### Known limits (stated, not hidden)

- **No label has been printed on a physical printer.** The byte streams are
  asserted against the TSPL and ZPL command sets, and the transports are
  exercised for failure handling, but nothing here has driven real hardware.
  Zebra is verified by command syntax only — there was no Zebra on hand.
- **USB printing is Windows-only.** The spooler path is `winspool.drv`; on
  Android and Linux the transport falls to network, so settings marks a USB
  profile as unreachable there rather than failing at print time.
- **No label designer.** Size comes from presets or two fields; there is a
  fixed layout. A shop wanting its own artwork needs more than this.
- **No receipt printing.** The counter prints barcode labels, not a bill. There
  is no ESC/POS encoder and no till-roll layout, so "thermal printing" in item
  12 is half done: a sale at the counter still has to go through the OS print
  dialog for a customer copy. This is the most likely next piece of this work.
- **No cash drawer, no customer display, no keyboard-wedge scanner capture.**
  The search box accepts a scanned code because a wedge scanner types into the
  focused field, but there is no explicit scanner mode or drawer kick command.
- **Batch/expiry and unit conversion remain open** from the same gap-analysis
  line. A batch-managed item cannot be sold through the counter yet.
- The printer-profile settings row is not migrated: it is read-and-write
  through the settings table with no schema version, so a future shape change
  needs a tolerant reader (the current one is, deliberately).
