# GST registration and cloud sync audit — 11 October 2026

## Registration behavior

Business setup and company settings share an explicit GST registration selector. A registered business requires a valid GSTIN; an unregistered business stores no GSTIN. The same registration policy is used across entries, accounting, reports and invoice output.

New unregistered-business sales and POS entries cannot charge GST or cess, including through repository calls with taxable catalogue defaults. Their editors, invoice details, PDF and thermal output omit GST columns. GST return navigation and report exports are unavailable for unregistered businesses. Registered interstate B2C sales can charge IGST even when the customer has no GSTIN.

Supplier GST can still be recorded by an unregistered business. It is included in purchase expense and stock cost, with no input tax credit. Purchase bills and expenses snapshot credit eligibility so changing the business registration later does not reclassify old documents. New non-GST other-income entries do not collect GST. Purchase reverse charge is not offered for new non-GST entries.

Schema 14 adds credit-eligibility snapshots with guarded migration from schema 13. Existing records default to their previous accounting treatment; existing taxed invoices are preserved. No automatic rewriting of historical user books was performed. Cost backfill and restore use the same gross-cost policy as new purchases.

## Cloud behavior

Each device signs in to the same account once and retains its own refreshable session. Saves request sync after a 300 ms debounce. Foreground apps check for remote changes every five seconds and catch up immediately on resume. Explicitly disabling sync is respected; offline changes stay queued.

Sync operations are serialized. Fresh installations discover the account's authorized businesses. Retained invoice line IDs can receive edits, removed lines send deletion records, and journal pages are applied transactionally. Mounted reports, GST summaries and invoice details refresh after book changes. Invoice lists now reset their cached stream and selection when the active business changes; details stop showing the previous business's invoice.

The local backend adds an authenticated, bounded long-poll option to its existing changes endpoint. The app remains compatible with the currently deployed server through five-second polling. **The backend was not deployed**, as requested. Production authenticated desktop-to-phone sync and simultaneous offline edit conflicts have not been verified on hardware.

## Verification

- Final full app suite: 1,163 passed, including business-switch list/detail regressions.
- Final analyzer: no issues across `lib`, `test` and the disposable audit harness.
- Full-suite, analyzer and build logs are in `build/import-audit/` under `gst-cloud-*`.
- Backend: 79 tests passed, including authenticated long-poll wake-up; analyzer clean.
- Two local databases and a local HTTP journal verify fresh-device discovery, retained-line updates, removed lines and idempotent replay.
- Latest `10-10-2026_03.39.15_Apex_Integrations_VypBackup.vyb` reconciliation passed without touching live books.
- Native Windows disposable preview visually confirmed non-GST sales 200, purchase payable 236 and stock cost 118; registered sales 236 with IGST 36 and GST return navigation. Switching businesses exposed the cached-list issue above.
- Further native interaction was blocked by Windows capture/input returning Access denied. Mobile layout is covered by automated tests; no Android hardware verification is claimed.

The audit harness in `tool/gst_registration_audit_app.dart` uses only in-memory sample books. Shipping builds use the normal application entry point. Android builds remain debug-signed because release signing is not configured.

Fresh local builds completed successfully:

- `dist/ApexBooks-Windows-2026-10-11.zip` — complete Windows release folder, including the freshly compiled `data/app.so`.
- `dist/ApexBooks-Android-debug-2026-10-11.apk` — debug-signed Android APK.

The existing Kotlin Gradle Plugin compatibility warning from `package_info_plus` and `share_plus` remains; it did not prevent the current APK build.
