# Architecture Memory

## System overview

Atria is an offline-first, single-codebase Flutter app for Indian MSMEs: GST-compliant
invoicing, purchase bills, party ledgers, stock, expenses, financial reporting
(GSTR-1/2, P&L, Day Book, receivables/payables ageing), and A4 PDF generation.

## Stack

- Flutter 3.47.2 / Dart 3.13.2 (at `C:\flutter\bin\flutter.bat`), Windows dev.
- Riverpod (`flutter_riverpod ^2.6.1`) for state + DI; providers in
  `lib/core/state/providers.dart`, repos scoped by `activeFirmIdProvider`.
- Drift (`^2.21.0`, resolves 2.35.0) on SQLite, WAL mode, FKs enforced.
  DB file: `getApplicationSupportDirectory()/atria/atria.db`.
- `go_router` `StatefulShellRoute.indexedStack` + `AdaptiveNavShell`
  (NavigationRail on desktop, BottomNav + "More" sheet on mobile).
- Exact arithmetic via `decimal` + `rational` (no IEEE-754 for money).
- PDF via `pdf` + `printing`. Charts `fl_chart`. Icons `phosphor_flutter`.

## Components

- 14 Drift tables: `firms`, `firm_members`, `parties`, `categories`, `units`, `items`,
  `stock_movements`, `sales_invoices`, `sales_invoice_items`, `purchase_bills`,
  `purchase_bill_items`, `payments`, `expenses`, `app_settings`, `sync_queue`.
- Repos in `lib/core/database/repositories/`; firm-scoped access via extension methods in
  `repository_extensions.dart` (e.g. `db.expenseRepositoryFor(firmId)`).
- Engines: `gst_engine.dart` (intra/inter/UTGST splits, inclusive back-calc, round-off,
  rate-wise aggregation) and `document_numbering.dart` (FY-aware numbering).

## Gotchas learned while linting (2026-09-25)

- **Extension methods need an explicit import.** `report_repository.dart` calls
  `db.*RepositoryFor(...)` and must `import 'repository_extensions.dart';`.
- `enum DocSequence` lives in `firm_repository.dart`, **not** `document_numbering.dart`.
- `Decimal.zero` is not a compile-time const — never use it in a `const` context.
- Drift 2.35.0: `customInsert`'s `updates` takes `Set<ResultSetImplementation>`
  (`{table}`), not `{TableUpdate.onTable(table)}`.
- Drift column comparisons want the column-vs-column form:
  `t.currentStock.isSmallerOrEqual(t.lowStockAlert)`, not `...Value(...)`.

## Constraints

- No version control in `D:\Atria` (not a git repo). Edits are untracked.
- `flutter.bat` emits its summary on stderr; PowerShell surfaces exit 1 on success.
