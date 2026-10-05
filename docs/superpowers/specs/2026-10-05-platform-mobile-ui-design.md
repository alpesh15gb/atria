# Mobile (Android) UI — design spec

_Date: 2026-10-05 · Status: draft for review · Nothing in this spec has been built._

## The decision

Apex Books gets **two UIs, chosen by platform, not by width**.

- **Windows is untouched.** The side rail, the dense tables, the card dashboard
  all stay exactly as they are. Zero risk to the desktop user.
- **Android gets its own layout**, following the Vyapar reference screenshots in
  `mobile reference/` (20 images, Vyapar's current Android app).
- **Reports on mobile render as cards**, per the reference grammar: the figure
  that matters is visible (the `emphasise` column), the rest is one tap away.
- **Mobile export is Excel, plus portal JSON for GST returns.** CSV / PDF /
  print stay desktop-only. Portal JSON comes from `GstReturnBuilder`, not from a
  generic report dump — see "Resolved decisions" §2.

## Why platform, and not width

The app today branches on width via `lib/core/responsive/breakpoints.dart`
(23 of 208 lib files import it). Width is the wrong axis for this decision:

| Case | Today (width) | Wanted (platform) |
|---|---|---|
| Windows at 1920px | desktop | desktop ✅ same |
| Windows dragged to 700px | **phone UI** | desktop ✅ fixed |
| Android phone at 360dp | phone | phone ✅ same |
| Android tablet at 1260dp | **desktop UI** | mobile, width-capped |

Both broken rows are the cases where a shrink or a stretch produces a layout
nobody wants. Desktop users keep their tables at any window size; Android users
get one coherent phone UI at any screen size.

### The tablet problem, and how it's handled

A 1260dp Android tablet given phone cards would look broken — cards stretched
across the full width. The reference has the same issue and avoids it by being
phone-only.

**Fix: cap mobile content at 560dp and centre it.** One number, applied in the
existing `AtriaContentWidth` wrapper, so a tablet or unfolded device shows a
deliberate centred phone column rather than a stretched one. Desktop is
unaffected because the cap lives only in the mobile branch.

## What the reference grammar actually is

Read across all five representative screenshots:

| Reference pattern | Apex equivalent | Exists? |
|---|---|---|
| Bottom nav, 5 items | `AdaptiveNavShell` → `_BottomShell` | yes |
| Card lists, no columns | `AtriaLineGrid` card path | yes |
| Icon tile grid for "create" | `AtriaCreateMenu` | yes |
| Scrollable status filter pills | `report_filter_bar.dart` | yes |
| Status / warning badges | `StatusChip.doc` | yes |
| Floating `+` FAB on lists | — | **new** |
| Bottom-sheet pickers | — | **new** |
| Export button | `_ExportButton` | yes, needs narrowing |

The consistent rule: **no tables, no horizontal scroll, no multi-column forms
on Android.** A wide figure goes right-aligned and prominent (see the Parties
screen: `You Collect ₹31580.00` as a full-width chip; the Bills screen: amount
right-aligned, status as a coloured ribbon).

## Architecture: three tiers

### Tier 1 — Platform seam (the foundation)

One new file: `lib/core/responsive/platform_ui.dart`.

```dart
enum UiSurface { mobile, desktop }

/// True when the app should render its Android phone layout.
///
/// Deliberately `defaultTargetPlatform`, not `Platform.isAndroid`: it resolves
/// correctly under `flutter test` (where `dart:io`'s `Platform` reports the
/// host OS — Windows — and would make every mobile test lie).
extension PlatformUi on TargetPlatform {
  bool get isMobileUi => this == TargetPlatform.android || this == TargetPlatform.iOS;
}
```

**The test-host trap is the reason for this exact spelling.** `Platform.isAndroid`
returns false inside `flutter test` on this Windows machine, so any test written
against it would pass for the wrong reason and then fail on the device.
`defaultTargetPlatform` is overridable in `tester.platformDispatcher`.

### Tier 2 — Reports (smallest, highest value — do first)

`lib/shared/widgets/report_data_table.dart` already has the right shape. It
flattens every group into a sealed `_Line` list — `_Heading` / `_Data` /
`_Subtotal` — in `_lines()` (line 106), then renders that one list **two ways**:
a table (line 333) and cards (line 128).

So the data layer is already platform-agnostic and stays untouched:

- `report_spec.dart` — unchanged
- `report_runner.dart` — unchanged
- all 47 `sources/` — unchanged
- CSV / Excel / PDF / print builders — unchanged

**Only the renderer's choice function changes** — pick card vs table by
platform instead of by width. That is a one-line behavioural change in a file
that already has both renderers written and tested.

Export menu narrows per platform: Android shows **Excel** plus **Portal JSON**
on GST returns; desktop keeps CSV, Excel, PDF, Print. Portal JSON is *not* a
generic report dump — it is `GstReturnBuilder`'s return payload, sequenced with
Phase 4d. See "Resolved decisions" §2.

### Tier 3 — Shell, lists, and the mobile dashboard

- **`AdaptiveNavShell`** — pick `_BottomShell` on Android unconditionally;
  keep the width-based rail on desktop so a narrow window stays desktop.
- **List screens** — cards on Android (already available via `AtriaLineGrid`),
  tables on Windows. Add the FAB.
- **Mobile dashboard** — the Vyapar shape: Sales/Purchases figures, a `Create`
  tile grid, a `Quick Access` tile grid. Both grids already exist as
  `AtriaCreateMenu`; this is composition, not invention.
- **Bottom sheets** — the one genuinely new construction. Used for
  customer/product pickers inside the mobile editors.

## What is explicitly NOT changing

- All repositories, services, database, schema, sync, PDF templates, exports.
- Every desktop screen.
- The report data layer and all 47 report definitions.
- `unsaved_guard`, permissions, member roles — nothing about behaviour.

No database migration. No schema change. This is presentation only.

## Rollout

Phase 1 reports → Phase 2 shell + lists → Phase 3 dashboard + FAB + bottom
sheets.

Phase 1 alone makes the 47-report library usable on Android, which is the
largest share of the value for the smallest share of the work.

## Testing approach

Two viewport widths can no longer prove platform behaviour, because a widget
pumped at 360dp is now mobile by platform *and* desktop by width — they need to
be separable:

- Set `tester.platformDispatcher.defaultTargetPlatformOverride =
  TargetPlatform.android` to assert the mobile tree.
- Leave it unset (desktop) to assert the desktop tree.

The existing width-pinned tests keep passing without modification, because
desktop keeps its width-driven behaviour. Only tests that assert the *phone*
layout while running on the desktop host need the override added — and those
are the ones that must be found by audit, not assumption.

**Verification is revert-proofing.** Each fix is reverted in place and the
failure observed before it is kept, per the project's established practice.

## What the screenshots actually show (re-read 2026-10-06, first-hand)

The table above and the decisions below were written by reading these images at
a distance. Re-reading them directly, several things were **wrong or missing**,
and they are corrected here rather than left to be discovered mid-build.

**The bottom nav is five items: Home · Bills · Products · Parties · More.** A
filled icon plus a bold label when selected. Correct in the original table.

**The list card leads with the name and puts the figures right, not the
figures on their own row.** Products: name left, price right-bold, quantity
above it in grey. Bills: party name left, amount right-bold, document number on
the second line.

**Warning states are a corner ribbon, not an inline chip.** "Overdue by 211
days" sits on the card's top-right edge in an amber block; "Qty: -3.00 UNT" in
red. The ribbon overhangs the card's rounding, which is what makes it read as
attached to the card rather than floating inside it. An inline chip is a
different shape and the original spec did not mention it.

**The status pills carry a count badge.** "All Transactions ①" — the selected
pill is filled blue and the count sits in a white circle. Five pills in a
scrolling strip, cut off at the right edge, which is the answer a 360dp screen
needs and is exactly what `wide: false` already does.

**The filter row is `Filter` on the left, sort name on the right** — both with
their own affordance, and the sort name is tappable ("Default").

**The summary card sits above the pills**: a `Total Amount ⌄` with its figure on
the left and `Pending` with a red figure on the right, with the search field and
the date pill sharing the card above them. Pending is red because pending money
is money the firm does not have.

**The empty state is prose plus one blue text link**, not a button: "You've seen
all This Year transactions. To view others, pick new dates." → `Select Date
Range`. It explains *why* the list is empty before offering the way out.

**The FAB is a rounded square, bottom-right, above the nav bar.** Blue, `+`.

**Section headers are small grey caps** — `PREFERENCES`, `APPEARANCE`,
`LAYOUT`, `HEADER & FOOTER` — above a grouped card of rows. Each row is title +
description on the left and a chevron or a value on the right. This is the
settings-list grammar, and it is reusable for anything grouped.

**The editor's pickers are full-width rows with a `⊕` and a blue label**, not
dropdowns: `⊕ Select Customer`, `⊕ Select Products`, under a grey section
heading (`Customer`, `Products`, `Addresses`, `More`). `More` is a collapsible
card of rows — Bank/signature — that is open in the reference.

**The Select Business sheet** is: title, then one row per firm with a circular
avatar, the firm name, its GSTIN, `Edit Company` / `Share` in blue, and a
selected-radio at the right; then `+ Add new Business` centred in blue. It opens
from the firm name in the header.

**25 files are in `mobile reference/`, not the 20 this spec claimed**, and at
least four are byte-identical duplicates of others. `reports (1).jpg` is the
Sales/Bills list, not a reports menu, and `reports (2).jpg` is a Document
Settings screen — the filenames do not describe their contents and must not be
used to guess at what an image shows.

### Still not built, from the images above

Nothing. All of it shipped in `2e3386e` and `ff17d25`:

- The 560dp content cap is **wired**, in `AtriaContentWidth` and applied by the
  **shell** (so every branch gets it, not just the three screens that used the
  widget). Editors and detail routes are exempt — the invoice line grid is the
  one screen that wants the width.
- `MobileFab` — rounded square, renders nothing on desktop.
- `MobileCreateGrid` + `MobileQuickAccessGrid`, both four across, mounted under
  the figures on the phone dashboard only. The tiles are **spelled out**, not
  sliced off `atriaCreateActions`: the desktop order is QuickBooks' and its first
  eight have no purchase in them. Quick Access is the app's own destinations, not
  the reference's — four of its eight are e-way bills, e-invoicing, GST filing
  and bank reconciliation, none of which exist here.
- `CornerRibbon` + `RibbonCard` — the warning block the spec missed.
- The filter pills carry the count badge on the selected one and are filled
  solid on a phone, tinted on desktop.
- The export menu narrows on mobile: Excel, plus the portal payload for a return
  that has an upload. `writePortalPayload` in `report_view_page.dart`.
- The **Select Business** sheet: avatar, name, GSTIN, `Edit Company` / `Share`,
  a selected ring, and a centred `+ Add new Business`.

**Still not built:** bottom-sheet pickers inside the mobile editors. The reference
uses full-width `⊕ Select Customer` rows rather than dropdowns; Apex's editors
still open their pickers as dialogs on a phone. That is the largest remaining gap
between Apex and the reference on a phone, and it touches the sale, purchase and
expense editors, so it is worth doing properly rather than as a side-effect.

## Resolved decisions (2026-10-05)

### 1. Which figure leads a report card — `emphasise`, not a heuristic

`ReportColumn` already declares this. It carries `emphasise`, documented as
"Rendered in the strong style — the row's identifying figure", and 47 specs
already set it. The card renderer leads with the `emphasise` column; when a
report declares none, it falls back to the last money column (a total), then to
the first.

**This closes a mistake in the first draft**, which proposed guessing from the
first non-empty money column — wrong for exactly the reports where the reader
wants the total, which is most GST returns. No new mechanism is needed; the
declaration already exists and needs auditing per report, not inventing.

### 2. JSON is for uploading to the GST portal — so it is not a report export

A generic `writeJson` over `ReportResult` was the wrong shape for this purpose.
The portal needs a specific payload, and **`GstReturnBuilder` already produces
one**: `buildGstr1`, `Gstr1Report.toJson()` (line 543), and a
`computeGstr1Hash` over it. That is a purpose-built return, not a dump of
whatever columns a report happens to have.

So there are two different JSONs and only one of them is wanted:

| JSON | Source | Scope | Status |
|---|---|---|---|
| **Portal upload** | `GstReturnBuilder.toJson()` | GST returns only | builder exists; ships with Phase 4d |
| Generic report export | — | — | **dropped** |

**Dependency:** `sources/` currently holds only `item_stock`, `party`,
`transaction`, and the catalogue still has placeholders. No GST report sources
exist yet, so portal JSON cannot ship until **Phase 4d (the six GST reports)**.
It is sequenced there rather than presented as available now.

Export menu per platform: Android shows **Excel** plus **Portal JSON** (GSTR
reports only, greyed out elsewhere); desktop keeps CSV, Excel, PDF, Print.

### 3. Firm switching — a bottom sheet under the company name

Tapping the firm name at the top opens the `Select Business` bottom sheet, as
in the reference: one row per business with avatar, GSTIN, `Edit Company` /
`Share`, then `+ Add new Business`. Windows keeps the rail menu.

This is the only new bottom-sheet construction besides the editor pickers, and
it reuses the sheet.

### 4. What must NOT be copied from the reference

The reference is Vyapar's shipping app, and several of its elements are its
monetization and marketing surface rather than its design language. Apex ships
none of these and must not gain them:

- **Ad / promo banners.** The "Upload with SwipeAI", "One-click e-Invoicing &
  e-way bills", "Add Custom Fields" and "Export/ SEZ / Multi currency"
  banners. They interrupt the list and advertise a product Apex does not have.
- **Plan badges.** `PRO`, `ADVANCED`, `BETA`, "Valid Forever", "Unlimited".
  Apex has no plan tiers, so the badge would name a thing that does not exist.
- **SwipeAI / OCR upload.** Referenced in screenshot 3. Apex has no OCR; that
  screen is not being built.

Everything else in the reference — cards, badges for real state, FABs, filter
pills, bottom sheets — is grammar and is fair game. The rule of thumb: copy the
**layout**, never the **upsell**.