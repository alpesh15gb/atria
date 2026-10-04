# Atria

Offline-first Indian accounting and GST billing. Flutter (Windows desktop and
Android), drift/SQLite on the device, Riverpod, QuickBooks-Online-inspired UI.

The books live on the machine you run it on. Nothing leaves the device unless
you sign the business in to a server.

## What it does

- **Sales** — invoices, quotations, sales orders, delivery notes, credit notes,
  with per-FY transactional numbering, and a counter-sale (POS) screen.
- **Purchases** — bills, purchase orders, debit notes; reverse charge; TDS.
- **GST** — a `Decimal`-exact engine (inclusive/exclusive, invoice-discount
  apportionment per line, CGST/SGST/UTGST/IGST, cess). GSTR-1 (B2B, B2CL, B2CS,
  CDNR, CDNUR, HSN, document issue) and GSTR-3B (3.1, 3.2, 4, 5), exported as
  portal-shaped JSON plus Excel-readable CSV, and a fiscal-year summary. GSTR-2A
  import and reconciliation.
- **Accounting** — a chart of accounts, journal vouchers, a trial balance, a
  balance sheet and per-account ledgers. Documents post into the ledger at read
  time, so an edited invoice changes the books immediately.
- **Money** — receipts and payments with a cheque lifecycle (in hand, deposited,
  cleared, bounced: a bounced cheque releases the invoice it settled).
- **Stock** — an immutable movement ledger, stock summary, TSPL/ZPL barcode
  labels.
- **Books you can trust** — recycle bin, period lock, append-only audit log, and
  a backup/restore plus Vyapar `.vyb` import.

## Requirements

| | |
| --- | --- |
| Flutter | 3.47.x (Dart 3.13) |
| Desktop | Windows 10 or later (x64) |
| Mobile | Android 8.0 or later |
| Tooling for a release build | Inno Setup 6 (`installer/README.md`) |

## Build and run

```bash
flutter pub get
flutter run -d windows            # or: flutter run -d android
flutter analyze
flutter test                      # ~340 tests; goldens are excluded, see below
```

Schema changes go through drift code generation, and the generated `*.g.dart`
files are committed:

```bash
dart run build_runner build --delete-conflicting-outputs
```

A schema change means bumping `schemaVersion` in
`lib/core/database/app_database.dart` **and** adding the matching clause to
`onUpgrade` — an upgraded install must end up identical to a fresh one, and
`test/firm_purge_test.dart` discovers firm-scoped tables from `sqlite_master` so
a table that is not taught to the purge fails the suite.

### Goldens

Light and dark captures of the main screens live in `test/goldens/`. They are
tagged `golden` and excluded from the default run (each holds drift streams open
and teardown is slow). Regenerating them needs `exclude_tags: golden` in
`dart_test.yaml` commented out first — `--tags golden` cannot override an
exclude. See the comment in that file.

## Printing

Two different things, on purpose:

| | Receipts | Labels |
| --- | --- | --- |
| Encoding | ESC/POS | TSPL / ZPL |
| Paper | 58mm or 80mm till roll | 50×25mm sticker, gap-sensed |
| Where | sale detail → **Print receipt**, and the POS screen | item → label |
| Extras | auto-cut, cash-drawer kick | copy count, darkness |

Both go through the same transport layer (`lib/core/printer/`), configured in
**Settings → Label printers**:

- **Windows print queue** (default) — sends a `RAW` job through `winspool.drv`,
  so any driver-installed USB or network printer works and no port name has to
  be typed in.
- **Network** — a raw TCP connection to `host:port` (usually 9100), for a
  printer with its own IP.

**Windows only, with one exception.** The spooler transport talks to
`winspool.drv` and is compiled for Windows; on Android and macOS it reports
that printing is unavailable rather than failing at the last step. The network
transport is not platform-specific, but a till printer that is reachable by IP
is the usual way to print from a phone or a Mac.

The label path has never been driven against real hardware — it is built from
the TSPL/ZPL command references and covered by encoder tests, so treat the first
run on a new printer as a checkout: print one label, check the gap sensing and
the darkness, then trust it.

## Server (optional)

Atria is offline-first: with no server configured, everything above works and
the sync outbox is simply left untended.

**Settings → Atria account** signs a business in (the same credentials ApexSync
serves), and **Settings → Sync** shows what is waiting and sends it. Signing in
is also what enables **erase this business on the server**, which is otherwise
disabled because there is no way to prove who is asking.

The base URL defaults to `https://api.apexbooks.in` and can be overridden at
build time with `--dart-define=ATRIA_API_BASE_URL=...`.

## Installers

See `installer/README.md` for the Windows installer, code signing and the
auto-update contract. The Android APK is signed from `android/key.properties`
when that file exists and with the debug key when it does not — only the
release-signed APK may be distributed.

## Project layout

```text
lib/core/          engine, database (tables + repositories), api, printer, theme
lib/features/      one folder per area: sales, purchase, ledger, reports, ...
lib/shared/        the widgets every screen is built from
test/              ~340 tests; goldens/ holds the captures
installer/, windows/  packaging
audit/             the QBO-parity and deployment notes
.claude/DECISIONS.md  why the code is the way it is — read this before changing it
```

`CLAUDE.md` and `.claude/DECISIONS.md` are the project's memory. Adding a table,
changing a posting rule or taking a shortcut worth explaining belongs in
`DECISIONS.md`.
