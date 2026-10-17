# UI, UX and logic audit - 10 October 2026

## Fixed

- Desktop shared page actions occupied the middle of the header. Actions now align with the right gutter and wrap when necessary. Confirmed in the rebuilt native invoice list and a geometry regression test.
- Mobile invoice payment filters retained selections of hidden documents. Filters now clear selection; select-all and bulk actions use only the filtered rows. Added a regression covering selection, filter changes and returning to all transactions.
- Mobile invoice result count described the unfiltered list. It now reports the visible rows. Confirmed Paid shows zero invoices for an unpaid sample dataset.
- An asynchronous settings read could overwrite a newly chosen appearance or complete after its controller was disposed. Added revision and lifecycle guards and two delayed-read tests.
- Dashboard invoice shortcut said Open sales ledger while opening invoices. Changed to View invoices; corrected retry punctuation.
- Repaired bank-statement test fixtures: Drift companion parameter types and an alleged cheque that was actually created as cash. Updated the dashboard inset test to measure the redesigned first heading while retaining its no-double-inset assertion.

## Visual and interaction checks

Used the computer-use skill against the running native Windows app, backed by a disposable in-memory database (tool/ui_audit_app.dart). Inspected desktop dashboard, invoice list, invoice editor and customer selection; phone-width editor, catalogue picker, selected product pricing, save, resulting invoice list and paid filter.

Saved a sample Ganesh Stores invoice with Brass Tap 15mm: quantity 1, rate 145, GST 12%, resulting amount 162.40. The invoice saved and appeared in the list. Rebuilt and reopened after fixes; confirmed the right-aligned desktop action and correct zero count under Paid.

The phone harness runs the actual app at 412 logical pixels with Android layout selection on Windows. This is not a physical Android/iOS or soft-keyboard test. Desktop automated text entry did not reliably populate the product field through the UI driver; the mobile catalogue selection/save flow succeeded.

## Verification

- Full Flutter test suite: 1,136 passed (build/ui-audit-final-tests.log).
- Windows debug build succeeded (build/ui-audit-fixed-build.log).
- Targeted static analysis of modified controller/list/header, audit regression tests and native harness: passed (build/ui-audit-targeted-analysis.log).
- Repository-wide analysis is not clean: 483 diagnostics, including unresolved test functions/packages under the separate server/api project and existing warnings (build/ui-audit-analyze.log). These were not treated as a clean pass.

This is a verified audit pass of the exercised flows, not a claim that every screen or external integration is defect-free. Physical-device keyboards, printing, cloud connectivity and production data were not exercised.


## App-wide interface size and expanded visual audit

Settings ? Appearance & size offers 85%, 100%, 115% and 130%, plus reset to 100%. Selection applies immediately to the whole app and is saved locally for this device, independently of the active firm. Operating-system text scaling remains respected. Shared responsive components adapt to the resulting available space.

### Additional fixes

- Appearance choices now wrap cleanly, update while the mobile sheet is open, and remain reachable by scrolling.
- Narrow payment summaries stack instead of clipping amounts.
- Mobile report subtotals show labelled figures; long report explanations open in a scrollable sheet.
- Journal references and invoice dates stack when horizontal space is insufficient.
- Trial balance and account-ledger rows use labelled mobile figures, preserving complete amounts.
- Statement download actions wrap; report summary cards become full-width on phones.
- Settings version details wrap; invoice-template thumbnails no longer overflow by one pixel.
- Mobile document tabs use single-line labels, including ?Quotes?.

### Coverage and evidence

- 223 capture cases passed at 130% in dark mode and at 85% in light mode. Cases include desktop/mobile routes, 46 report catalogue entries on both layouts, editors, settings, onboarding and account ledger. Scrollable screens were exercised through their lower content as well as their first viewport.
- Additional core sweeps passed at 100% dark and 115% light. Account-ledger captures were repeated after its final mobile layout fix.
- Full Flutter suite: 1,142 passed before the final account-ledger layout change; 39 ledger and interface-scale tests passed after that change.
- Targeted analysis of the scale controller, settings, reports and ledger: no issues found.
- Final Windows release build succeeded (`build/scale-release-build.log`).
- Native Windows computer-use checks exercised appearance selection, reset, scrolling and desktop/phone navigation using disposable sample books.
- Capture gallery: `build/visual/index.html`. Logs: `build/scale-complete130.log`, `build/scale-complete85.log`, `build/scale-verified-tests.log`, `build/scale-latest-ledger-tests.log`, `build/scale-latest-analysis.log`.

These checks cover the exercised sample-data states. Empty report states do not certify every populated-data combination. The phone layout runs on Windows at phone width; physical Android/iOS, native keyboards, camera scanning, printer hardware, cloud integrations and production data still require device/integration testing. Repository-wide analysis limitations noted above remain.
