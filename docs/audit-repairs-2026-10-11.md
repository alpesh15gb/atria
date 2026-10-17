# Audit repairs — 11 October 2026

This records repairs to the 18 findings in [the original audit](../BUGS_FOUND_2026-10-11.md). The original audit and its observation probes remain historical evidence. No live backend deployment or customer-book edits were performed.

| Finding | Repair |
| --- | --- |
| B01 | Payload-bearing legacy delete messages apply the soft-deleted row state; only payload-free tombstones remove rows. Invoice lines survive recycle/restore with foreign keys enabled. |
| B02 | Sync pull derives item stock caches from the firm’s stock movements after the page is applied. |
| B03 | Sync pull rebuilds document settlements from linked payment history, including deleted/bounced payments, without inventing a new document revision. Documents without linked payment history retain imported settlement snapshots. |
| B04 | Catalogue edits retain the latest stock and opening stock, and reject missing/deleted items. |
| B05 | Payment edits check both the original and replacement dates against the period lock. |
| B06 | Expense/income edits reread the original row inside the transaction and check both dates. |
| B07 | Manual stock adjustments enforce master-data permission in the repository; unauthorized adjustment controls are disabled. |
| B08 | Typing immediately rebuilds and arms item and party unsaved-change guards; the same correction applies to sales editors. |
| B09 | POS carts arm an unsaved-change guard. Both system back and the app-bar fallback protect the cart. |
| B10 | Bank opening balances use an explicitly signed amount formatter. Other amount fields retain their existing unsigned behavior. |
| B11 | Dashboard cash in hand reads the cash ledger, including expenses, income, openings and journals. Receipt/payment movement totals remain separate. |
| B12 | Dashboard receivables/payables use party outstanding balances, including openings and unallocated payments, while retaining walk-in document dues. A party’s net debit is receivable; its net credit is payable. |
| B13 | Bank/cash opening balances enter the date-bounded ledger with a capital contra. Ledger reports also refresh on bank-account writes. |
| B14 | Backup restoration inserts loans before their transaction children. |
| B15 | Expense/income lists explicitly request uncapped data so search and totals include every matching row. |
| B16 | Sales, purchase, payment and expense permanent purges enqueue sync tombstones within the deletion transaction. |
| B17 | The POS footer stacks at narrow widths/high text scale. Populated cart headings and line controls also reflow, fixing an additional overflow found during the repair pass. |
| B18 | Stock-adjustment dialog content scrolls when the keyboard reduces available height. |

## Validation

- Regression coverage: `test/audit_repairs_20261011_test.dart` and `test/audit_ui_repairs_20261011_test.dart`.
- Layout checks cover Windows and Android, app scale 150%, OS text scale 150%, a populated POS cart, and a 300 px keyboard inset.
- Financial checks exercise real repositories and sync pull, period-lock rejection, permissions, backup restoration with production foreign keys, and dashboard/ledger reconciliation.
- Logs and screenshots: `build/import-audit/repairs-2026-10-11/`, `repairs-full-tests.log`, `repairs-final-analyze.log`, and `repair-ui-final.log`.
- Android visual checks run through Flutter’s Android platform simulation; no physical Android device was connected.

## Release signing

- Android application ID: `com.apexbooks.app`; version `1.0.0`, build `2`.
- A private RSA 3072-bit release key was created with user authorization at `C:\Users\Administrator\.apexbooks\signing\apexbooks-release-20261011.jks`. Credentials are stored beside it in `release-credentials.json`. Back up both privately; future Android updates require this same key. Neither belongs in Git or a distributed artifact.
- `android/key.properties` is ignored by Git. Release Gradle tasks now fail when release signing is missing, instead of falling back to the debug key.
- The APK’s release certificate SHA-256 is `fcdfc1eb0f6ab9965bc6d593cb912850559062e1ab2ff5669e4998530f98f694`.
- Existing debug-signed installations cannot accept this release-signed APK as an in-place update. Export/back up their books before any uninstall/reinstall.
- The Windows installer is unsigned: no Windows code-signing certificate was supplied. Its stable installer AppId is retained.
- Installer compiler: Inno Setup 6.7.3, downloaded from the [official distribution](https://jrsoftware.org/isdl.php), with a verified Pyrsys B.V. Authenticode signature.

Final artifact paths, hashes, installer verification and final test results are recorded in `dist/RELEASE-2026-10-11.md` after packaging.
