# 04 — Competitive UI Structure Research & Whole-App Revamp Plan

Scope: **structure, not colour.** What follows is (1) how the three reference
apps organise their UI, (2) the patterns they share, (3) what Atria already
does, and (4) the concrete structural changes applied to every screen.

Sources are the vendors' own knowledge bases / help centres, their store and
marketing material, and an independent GST-invoicing UX case study.

---

## 1. How the reference apps are organised

### 1.1 Vyapar

**Navigation model (desktop).** A left-hand main menu. `Reports` is a
*section*, not a screen: it fans out into grouped report categories.
The **Transaction reports** category is itself a list — `Sale`, `Purchase`,
`Daybook`, `All Transactions`, `Profit and Loss`, `Bill Wise Profit`,
`Sale Aging`, `Cash Flow`, `Trial Balance`, `Balance Sheet`.

**Every report shares one control strip.** Period filter
(Monthly / Quarterly / Yearly / Custom / "Between"), firm filter, godown
filter, a **graph toggle**, and two inline export actions (`xls`, `Print`).
Columns change per report, not the surrounding chrome.

**`All Transactions` is the master ledger.** One list, filtered by
`Period`, `Firm`, `Transaction Type`, `Godown`, with columns
`Party Name`, `Category`, `Received/Paid`. A `Daybook` is the same thing
scoped to one date.

**Mobile home.** Quick-create affordances first, then money summary cards
business owners live by — *To Collect*, *To Pay*, *Cash in Hand*, *Stock
Value* — then a recent-transactions list.

**Known weakness (his own blog + competitor reviews):** "complex UI, steep
learning curve, overwhelming for small shops". 35+ reports is a feature and
a liability: the reports screen needs *grouping*, not a flat wall.

### 1.2 myBillBook

**Navigation model.** Bottom navigation on mobile (one slot is effectively
`Settings`/`Me`). The knowledge base is organised into six top-level
collections, which is the real IA:

| Collection | Count |
|---|---|
| Getting Started | 6 |
| Billing & Invoicing | 49 |
| Inventory Management | 18 |
| Party Management | 8 |
| Accounting | 15 |
| Grow your business | 5 |

Two things to steal:

1. **Document types are *sub-entries of Billing*.** Invoices, quotations,
   orders, delivery notes, credit/debit notes are variants of one billing
   concept — not five top-level tabs.
2. **Accounting is a peer section** of Billing: it owns payments, expenses
   and ledger-style reporting, separate from the document lists.

**Dashboard.** "Overview of key metrics, recent transactions, important
notifications, quick access to common actions, business performance
insights" — i.e. actions first, then numbers, then insights. Same skeleton
as Vyapar's home.

### 1.3 Swipe

**Navigation model (mobile).** `Home` (a page of large action tiles, first
one being *Invoice*), `Parties` (with `+ New Customer`), `Products` (with
`+ New Product`), and `More` — a catch-all holding Bank details, Signature,
and other setup objects.

**Billing flow is a single linear editor.** Home → invoice → add customer
(search, or create) → add products (search, qty, continue) → per-line edit
→ custom fields → bank → signature → references/notes/terms → additional
charges → TDS/TCS → record payment → create. Long, but every step is a row
in one document, and the footer is the total.

**Known weakness (independent case study):** "no help with GST compliance,
feels cramped with features and information, overwhelming for first time
users, font size is too small." **Lesson: adopt the structure, not the
density.**

### 1.4 Independent case study (GST-invoicing UX)

- Zoho Invoice's strength was "good information architecture, well organised
  tabs **especially the invoice detail screen**, minimalistic look".
- Its weakness: "unusual side menu for navigation, confusing visual
  hierarchy."
- The designer's fix was to **align navigation with apps users already know
  (WhatsApp, GPay)** — home hub, bottom bar, tapping into a detail screen
  with a clear header and a sticky total/action footer.
- Explicit takeaway from that project: *information architecture, not
  ornament, is what removes the learning curve.*

---

## 2. The shared skeleton (what all three converge on)

1. **Home is an action hub, in this order:** greeting → primary create →
   quick-create row → money cards → recent transactions → insights.
2. **Four money numbers** run the business: *To receive*, *To pay*,
   *Cash in hand*, *Stock value*.
3. **One transaction list**, not seven. Filter chips by document type, a
   period control, and search — then rows.
4. **A row has four beats:** leading glyph → party/title → `doc-no · date`
   in muted small text → right-aligned **amount** with a status chip under
   it. Amounts use tabular figures.
5. **Reports are grouped categories** (`Transaction`, `Party`, `Item`,
   `Tax`, `Other`), and each report entry is a *row* with an icon, a label,
   a one-line description and a chevron — plus its own inline
   export/graph actions once opened. Not a wall of cards.
6. **Document types are behind one entry** with a segmented selector.
7. **Settings is a grouped list** of sections with icons and a chevron.
8. **Bottom bar = 4–5 destinations**; everything else lives one level down.

---

## 3. Where Atria already matches, and where it does not

**Already matching**
- Grouped rail with expandable document-type dropdowns (Sales ▸ Invoices /
  Quotations / …; Purchase ▸ Bills / Debit Notes).
- Bottom bar + `More` sheet on mobile; extended/compact rail on desktop.
- Dashboard has a greeting, a gradient hero, quick actions, KPIs, a trend
  chart, recent invoices and alerts.

**Structural gaps to close**

| Gap | Change |
|---|---|
| Dashboard stacks **hero stats and a KPI grid** — the same four numbers twice, in two visual languages | One money strip in the four-number vocabulary (*To receive / To pay / Cash in hand / Stock value*), then the secondary KPIs as a quieter grid |
| Quick actions sit **below** the hero | Quick-create row moves directly under the greeting, above the numbers (matches all three references) |
| List screens have search + period but **no document-type/filter chip row** | A shared chip row: document types on sales/purchase, stock state on items, party type/balance on parties, in/out on payments |
| No **count + total line** above a list | A shared results bar: `12 invoices · ₹2,34,000` |
| Reports is a **flat grid of cards** | Grouped into *Transaction / Party / Item / Tax / Other* sections of row-entries with descriptions |
| `More` sheet and rail are **un-grouped** | Both gain section labels (`MAIN` / `BUSINESS` / `SYSTEM`) |
| Settings lacks **icon + chevron section rows** | Grouped section list |
| Empty states are single-use | `EmptyState` is now height-safe (see note) and reused everywhere |

---

## 4. Implementation notes

- **No route/branch reordering.** `StatefulShellRoute.indexedStack` branch
  index maps 1:1 onto `NavDestinations.all`, so destinations may be
  re-labelled and re-grouped but **not reordered**. Doc-type children stay
  deep links (`/sales?type=quotation`).
- **Reuse the token layer.** No new colours; the violet system in
  `app_colors.dart` / `app_theme.dart` is the source of truth. New widgets
  take colour from `atriaColors(context)` and `ColorScheme`.
- **New shared widgets:** `atria_quick_actions.dart` (the create row) and
  `atria_list_toolbar.dart` (filter chips + results bar).
- **Height safety.** `EmptyState` (and anything that may sit inside a
  bounded `TabBarView`) is wrapped in a `LayoutBuilder` +
  `SingleChildScrollView` + `ConstrainedBox(minHeight)` pattern; a bare
  `Center` inside a bounded box overflowed by 33px on the Expenses screen
  before this revamp and the fix is now the house pattern.
- **Verification:** `dart analyze lib test` clean, `flutter test` green,
  goldens regenerated, Windows Release and Android Release APK rebuilt.

---

## 5. Second pass — the remaining dense screens

### 5.1 Reports: destinations become rows, not app-bar icons

The screen carried two unlabelled app-bar icons (`fact_check_outlined` → GST
returns, `inventory_2_outlined` → stock). Both were the only entry points to
those screens from the Reports branch, and neither is discoverable without
hovering for the tooltip — the opposite of the reference pattern, where every
report family is a *labelled row with a description*.

- New shared widget **`atria_nav_row.dart`** — `AtriaNavRow` (38px tinted
glyph, bold title, one-line description, chevron) and `AtriaNavRowList`
(a stack with consistent gutters). Tint defaults to brand primary; pass a
semantic colour for warning/ledger destinations.
- Reports now opens with a **Report library** group above the period selector:
*GST returns* (GSTR-1 / 3B / 2A reconciliation), *Stock summary* (quantity and
value, item wise), *Statement of account* (party ledger + PDF/Excel).
- The app-bar `actions` list is gone; nothing is now reachable only through an
icon.
- The period selector and the computed sections (GST card, sales-vs-purchase
trend, statements grid) are unchanged: the grid there is a *preview* of four
statements, not a navigation index, so it keeps the card treatment.

### 5.2 One filter control everywhere

The second pass removed the last three hand-rolled filter rows. All list
filters now use `AtriaSegmentedFilter`:

| Screen | Before | After |
|---|---|---|
| GST reports | `SegmentedButton<String>` | segmented filter (GSTR-1 / 3B / 2A) |
| Stock summary | single `FilterChip` "Low stock only" | segmented *All items* / *Low stock* |
| Party transactions pane | horizontal `ChoiceChip` row | segmented, scrollable |

### 5.3 Deliberately left as form controls

`SegmentedButton` / `ChoiceChip` still appear inside **editors, sheets and
settings** — money in/out in the payment sheet, tax mode, theme mode, the
item-editor switches, and Reports' own period selector (which opens a custom
date range). Those are inputs, not list filters; they keep the standard
Material control.

### 5.4 Verification for this pass

`dart analyze lib test` clean · **97/97 tests pass** · goldens regenerated ·
Windows Release and Android Release APK rebuilt.

New cover added with this pass — `test/ui_structure_regression_test.dart`:

- *reports screen lists its destinations as labelled rows* — renders
  `ReportsScreen` for real and asserts the three `AtriaNavRow`s exist, the old
  icon tooltip is gone, and **no exception** was thrown (a layout overflow
  fails here, not only in a golden's pixels).
- *expenses screen drives its two modes from the shared filter* — asserts
  `AtriaSegmentedFilter<int>` is present, `TabBar` is not, and tapping *Other
  Income* re-labels the create button to `Add Income`.

Both use the house widget-test shape (in-memory `AppDatabase.test`, seeded
firm, unmount-then-step teardown) so drift's stream teardown does not hang.

---

## 6. Invoice detail: the PDF preview (user report)

A screenshot of the invoice detail screen showed `Preview invoice PDF`
expanded into a component that did not look like part of the card:

- the viewer's background was a flat grey slab butting square against the
  card's rounded corners, with the page jammed to one side;
- `printing`'s own action bar was drawn **full card width in
  `Theme.primaryColor`** — a solid violet band inside a white card — with its
  two actions spread by `WrapAlignment.spaceAround` to the 25% and 75% marks
  and no labels, so `Print` and `Share` appeared as two unlabelled icons
  floating far apart with no relationship to each other.

**Fix — new shared widget `lib/shared/widgets/atria_pdf_preview.dart`:**

- `PdfPreview(useActions: false)` switches the built-in bar off entirely
  (which also drops its debug-only red switch from the bar).
- The viewer sits in a `ClipRRect`-rounded frame filled with
  `surfaceContainerHighest`, with 12px padding around the page plus a 6px page
  margin, so the page floats inside a rounded, inset surface instead of
  touching a square grey edge.
- The page itself gets `pdfPreviewPageDecoration` (white, `AppRadius.xs`,
  `AppShadows.card`) — a sheet of paper on a tinted desk.
- The actions move to a **footer row**: a `Print` text button, and a
  `Share PDF` `FilledButton.tonalIcon` on the right. That tonal button is the
  app's existing "export" button (`statement_of_account_screen.dart` uses the
  same one for PDF/Excel), so the preview speaks the app's language instead of
  the package's.
- `_PdfPreviewCard` passes the screen's own `_print()` / `_share()` flows, so
  the card and the app-bar menu run the same code (the share flow still
  pre-fills the WhatsApp message and UPI link).

**Palette stragglers in the PDFs.** The violet sweep had changed `_brand` but
left the neutrals behind: `invoice_pdf.dart` was still on the teal-era greys
(`0xFF161A18`, `0xFF5A605C`, `0xFFD8D5CD`, `0xFFF3F6F5`) and both PDFs still
had mint bands (`0xFFE6F4F1` grand-total row, `0xFFEFF3F2` footer/table
header). They now use the app's cool violet-grey tokens `#16141F`, `#565263`,
`#D4D0E0`, `#F6F5FA`, `#EDE9FE`, `#F5F3FF`.

### 6.1 The rupee sign was a placeholder box (found while chasing the above)

Inspecting the preview sent us into the PDF pipeline, where a long-standing bug
surfaced: **every `₹` in every generated PDF was drawn as a placeholder box.**

The `pdf` package's built-in Helvetica is a Type1 font with a 256-glyph WinAnsi
table, so `PdfType1Font.isRuneSupported` is false for anything above U+00FF.
`₹` is U+20B9, and the layout code's answer to an unsupported rune with no
`fontFallback` is `_addPlaceholder(...)` plus the debug line
`Unable to find a font to draw "₹" (U+20b9)` — which is exactly what a test run
of the old code prints.

**Fix:** new `lib/core/services/pdf_fonts.dart` attaches the app's bundled
**Inter** (which does carry `₹`) as a *fallback*, not a replacement:

```dart
pw.ThemeData.withFont(fontFallback: await PdfFonts.fallback())
```

`ThemeData.base()` — what a `Document` uses when no theme is passed — delegates
to `withFont()` with every slot null, so passing only `fontFallback` leaves the
base/bold/italic fonts, and therefore all metrics, line breaks and column
widths, exactly as they were. Only unsupported runes come from Inter. Loading
degrades to an empty fallback list if the asset cannot be read, so a PDF still
builds rather than failing.

`InvoicePdf.build` and `StatementExport.exportPdf` both now pass the theme.

**Proof (`test/pdf_font_test.dart`):** a PDF containing `₹1,234.00` embeds a
TrueType subset (`/FontFile2`) with the fallback and embeds none without it —
and the old path prints the "Unable to find a font to draw ₹" line, so the test
fails loudly if the fallback is ever unwired again.

**Verification:** a throwaway probe golden rendered `AtriaPdfPreview` in both
themes and was eyeballed in the browser (rounded frame, footer left/right,
no violet band); the probe and its PNGs were then deleted. Rasterisation
itself cannot run under the test runner (no pdfium), so the probe validated
the chrome, not the page. `dart analyze lib test` clean, tests green, both
release builds rebuilt.

**Golden regeneration note:** the goldens are capture-only and their teardown
can hang on this machine, so they are regenerated **one test at a time**
(`--plain-name <name> --update-goldens`), and the process is killed once the
PNG appears. Capturing a golden requires the tree to render without throwing,
so a written PNG is itself evidence the screen laid out cleanly.

## Follow-up: the document number was being used as a file path

**Reported:** every share/open attempt failed with
`Could not share: PathNotFoundException: Cannot open file, path =
'C:\Users\…\Temp\INV/2026-27/001.pdf' (OS Error: The system cannot find the
path specified, errno = 3)`.

**Cause:** the invoice number is a *series label* written the way it is
printed on the document — `INV/2026-27/001`. `_share()` and `_openPdf()` joined
it straight into a path:

```dart
File(p.join(dir.path, '${_invoice!.number}.pdf'))
```

so the OS read the slashes as directories and looked for
`Temp\INV\2026-27\001.pdf`, which does not exist. The failure is not
Windows-specific: Android's `printing` plugin does the same thing in
`sharePdf` (`new File(shareDirectory, name)`), and `shareXFiles` on the Windows
plugin writes `GetTempPath() + "\\" + name` in `print_job.cpp`. Any name with a
separator breaks all of them. `Printing.layoutPdf(name:)` is *not* affected —
that name only becomes the spooler job name (`docInfo.lpszDocName`).

**Fix:** one shared helper, `lib/core/utils/file_names.dart` →
`sanitizeFileName(name, {fallback})`. It is deliberately a blacklist — the
separators, the rest of the Windows-reserved set (`< > : " | ? *`) and control
characters collapse to `_`, runs are collapsed, and leading/trailing dots,
spaces and `_` are trimmed, because `Sharma & Sons` is a perfectly writable
name and stripping it to `Sharma _ Sons` would be vandalism for no gain.
`INV/2026-27/001` → `INV_2026-27_001`, `Sharma Traders & Sons` unchanged.

The existing `statement_export.dart` idiom
(`partyName.replaceAll(RegExp(r'[^\w-]+'), '_')`) was the seed for this; it now
calls the shared helper instead of carrying its own regex.

**Applied at every site that turns a user label into a path:**

| Site | Name source |
|---|---|
| `sale_detail_screen.dart` `_share()` | invoice number → temp file (the report) |
| `sale_detail_screen.dart` `_openPdf()` | invoice number → `atria/invoices` |
| `item_editor_screen.dart` `_printBarcodeLabels()` | item SKU is free text, `LABEL/1` was equally fatal |
| `settings_repository.dart` `exportToFile()` | `fileName` param is a public API surface |
| `statement_export.dart` `_write()` | party name |

Audited and left alone, with reasons: `gst_export_service._periodDir()` keys
folders by GSTIN — written *and* re-opened from the same raw string, and the
directory is created recursively, so escaping there would have *introduced* a
mismatch with `gst_reports_screen.dart`'s reopen path. `csv_export.dart` and the
logo copy in `firm_settings_screen.dart` only ever receive literals or a file
extension. `Printing.layoutPdf(name:)` keeps the readable number — it is a job
name, not a path.

**Proof (`test/file_names_test.dart`):** five cases, including the reported
`INV/2026-27/001` asserted via `p.dirname(p.join(temp, name)) == temp`, i.e. the
sanitised name is a *single* path component on the platform it runs on.

**Verification:** `dart analyze lib test` clean; full suite 104/104 (99 + 5
new); Windows Release and Android Release rebuilt.

## Follow-up: the UPI QR was painted on top of the terms and signature block

The next screenshot showed the invoice PDF with a dense grey QR-like block
sitting on the terms text and "Receiver's Signature", while the space beside
"Scan to pay via any UPI app" — where the QR belongs — was blank.

**Cause:** `UpiQr.widget` builds the code as ~1200 `drawRect` calls inside a
`pw.CustomPaint`. In `pdf`, `PdfGraphics.drawRect` only *appends* to the
current path; painting needs a `fillPath()`, which the painter never called.
Parsing the exported PDF's content stream showed the smoking gun: **1260 `re`
operators and not a single fill operator anywhere in the page**.

A pending path is not part of the graphics state, so it survives every
`q`/`Q`. The module rectangles kept accumulating across widget frames and were
then flushed by the next unrelated widget that called `fillPath()` — the
signature block's filled boxes — and painted under *that* widget's transform.
That is why the QR appeared exactly on the signature area, one widget late.
(`pdf`'s own `_BarcodeWidget` calls `setFillColor(...)` + `fillPath()` after
its bar loop, for this same reason.)

**Fix:** `canvas.fillPath()` at the end of the painter, so the path is closed
where it is built.

**Verification** — rasterisation is unavailable under `flutter test` (no
pdfium), so the render was checked with Chromium's own PDF viewer against a
copy of the real exported invoice served over loopback:

* a throwaway probe rebuilt the invoice's lower half twice — once with the old
  painter and once with the fix. The old one reproduced the user's artefact
  exactly (empty QR slot, texture across the terms and the receiver's
  signature line); the fixed one drew a correct QR beside the caption and left
  the signature block clean. Probe and PDFs deleted afterwards.
* `test/upi_qr_pdf_test.dart` pins the property from inside the test runner:
it inflates the page content stream and asserts the maximal run of `re`
operators is closed by `f` before the frame is restored, and that the code is
drawn at the requested size. Removing the `fillPath()` line makes it fail with
`Expected: 'f', Actual: 'Q'`, so the regression cannot come back silently.

**Verification:** `dart analyze lib test` clean; full suite 106/106 (99 + 5
filename + 2 QR); Windows Release and Android Release rebuilt.
