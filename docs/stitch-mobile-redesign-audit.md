# Stitch mobile redesign ? 11 October 2026

Implemented from `stitch_minimal_unique_ui_redesign` (all six screen references and Executive FinTech DESIGN.md).

## Shared mobile system
- Warm cream canvas, teal actions, rounded white surfaces and floating navigation dock. Dark mode uses deep green neutrals and mint accents.
- Bundled Manrope and Hanken Grotesk fonts work offline; bundled Inter supplies currency glyph fallback. Font OFL licenses are in assets/fonts.
- Reused mobile list headings, primary actions, scrollable header/search/filter areas, document cards, inventory cards, form groups, account menu and dashboard action/module cards.
- Dashboard, sales/purchase/quotation lists, items, parties, payments, expenses, reports, settings and editors use real existing repositories/providers. POS has a separate payment review step with a persistent order total.
- Existing desktop presentation, GST accounting, document formats, cloud sync and interface scaling remain in place. No schema migration or backend deployment.

## Behavior fixes
- Mobile system appearance now follows system brightness; explicit light/dark preferences work.
- Business switcher actually selects available books and handles errors.
- Party tabs distinguish All, Customers and Vendors accurately.
- List titles and primary actions stay visible alongside document tabs.
- Shared list headers scroll away on short/scaled screens rather than squeezing records to zero height.
- Long business names fit when interface scaling enlarges controls.
- Invoice/purchase line input rows no longer rely on an incorrect intrinsic height.
- POS does not request barcode-label printing by default without a printer. Mobile checkout no longer reserves most of the cart area for payment settings; adding an item dismisses the phone keyboard.

## Verification
- `flutter analyze --no-pub lib test tool/stitch_mobile_audit_test.dart`: no issues.
- Full suite: 1,174 passed.
- Visual audit: 15 routes ? 2 viewport sizes (360?640, 412?892) ? 3 interface scales (0.85, 1.0, 1.3), plus dark mode and checkout at both sizes/scales.
- Checkout audit searches a saved item by SKU, reviews payment, completes a sale and checks the persisted invoice and stock decrement.
- Mobile invoice/purchase creation, validation, settings saves, business switching, party filtering and immediate scale changes verified by widget tests.
- Rendered screenshots inspected in `build/import-audit/stitch-mobile`; preview.png combines six screens. All sample records exist only in the isolated in-memory audit fixture, never production app data.
- Computer-use native launch attempted; Windows returned `GetCursorPos failed: Access is denied (0x80070005)`. No device/native-click verification claimed.

## Deliverables
- `dist/ApexBooks-Android-debug-2026-10-11-stitch.apk`
- `dist/ApexBooks-Windows-2026-10-11-stitch.zip` (fresh release-mode Windows bundle)
- Normal app entry point `lib/main.dart`; audit harness excluded.

## Scope limits
No fake growth percentages, verified-business claims, camera scanner, product photographs, register IDs, payment integrations or invented report results were copied from the design. Existing unavailable reports remain explicitly unavailable. Android is a debug build; release signing remains a separate configuration requirement. Production cloud deployment remains untouched as instructed.
