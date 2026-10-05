import 'dart:convert';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import '../../../database/repositories/repository_extensions.dart';
import 'gst_common.dart';

/// **GSTR-2A Reconciliation** — your purchase books against what your
/// suppliers actually filed.
///
/// **Why this report exists and what it is not.** The reference menu lists
/// "GSTR 2". GSTR-2 is populated by the portal from every registered
/// supplier's return and **no application can produce it** — it is the portal's
/// own data, not yours. Printing a GSTR-2 from local books would be an
/// invention dressed as a return, so this slot ships as the reconciliation
/// instead: the one thing you can legitimately do with GSTR-2A, which is find
/// out which of your supplier's invoices they did not report, and therefore
/// which input tax credit will be blocked in 3B.
///
/// **It needs the portal's file.** A reconciliation against nothing is not a
/// reconciliation. The JSON is imported through GST Reports → GSTR-2A, and
/// stored per firm and per return period; this report reads that stored file
/// for the window it is asked for. With nothing imported for the period it
/// returns no rows and says so, rather than quietly showing "everything
/// matches" — which is the answer that costs a firm real money.
///
/// **The period is keyed on the month, not the day.** A GSTR-2A is filed monthly
/// and the portal's file carries one period, so the stored JSON is looked up by
/// the month the window falls in. Asking for 1–15 April will not silently read
/// May's file.
const ReportSpec gstr2aReconciliationSpec = ReportSpec(
  id: 'gstr2a_reconciliation',
  title: 'GSTR-2A Reconciliation',
  category: 'GST',
  sort: ReportSort(columnKey: 'difference', descending: true),
  columns: [
    ReportColumn(key: 'invoice', label: 'Invoice', flex: 2, emphasise: true),
    ReportColumn(key: 'status', label: 'Status', flex: 2),
    ReportColumn(
      key: 'booksTaxable',
      label: 'Books taxable',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'booksTax',
      label: 'Books tax',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'portalTaxable',
      label: '2A taxable',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'portalTax',
      label: '2A tax',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'difference',
      label: 'Difference',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'Your purchase bills against the GSTR-2A JSON you downloaded from the '
      'portal. "Books only" means you recorded an invoice the supplier never '
      'reported — the credit will be blocked. "2A only" means they reported it '
      'and you did not record it. "Mismatch" means the values differ. Import the '
      'file through GST Reports → GSTR-2A first; nothing imported for this '
      'period means nothing to compare, and this report stays empty rather than '
      'claiming every invoice matches. Purchase debit notes appear as negative '
      'book rows because they reverse their bill\'s credit.',
);

const ReportDefinition gstr2aReconciliation = ReportDefinition(
  spec: gstr2aReconciliationSpec,
  source: CallbackReportSource(
    sourceId: 'gstr2a_reconciliation',
    query: gstr2aReconciliationRows,
    notes: _gstr2aNotes,
  ),
);

/// Where the imported portal JSON lives, per firm and per return period.
///
/// **One key per month, stored under the firm.** A firm can import April's 2A
/// and May's 2A and must see each against its own period — keying only by firm
/// would show whichever file was imported last, which is how a clean April
/// reconciliation gets checked against May's invoices.
String gstr2aStorageKey(DateTime month) =>
    'gstr2a_${month.year}_${month.month.toString().padLeft(2, '0')}';

/// The first calendar month the window covers — the return period a GSTR-2A
/// file belongs to.
DateTime _periodOf(ReportWindow window) {
  final from = windowFrom(window);
  return DateTime(from.year, from.month);
}

/// Reads a portal GSTR-2A file the firm has already imported, or null.
///
/// Returns null rather than throwing on a corrupt or absent file: this is a
/// report source running behind a screen, and an unreadable file is a reason to
/// show nothing, not to fail the whole report list.
Future<Map<String, dynamic>?> readImportedGstr2a(
  AppDatabase db,
  String firmId,
  ReportWindow window,
) async {
  final raw = await db.settingsRepository.get(
    gstr2aStorageKey(_periodOf(window)),
    firmId: firmId,
  );
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Stores a portal GSTR-2A file against its return period.
///
/// Written by the GST Reports screen's import, and here so the key and the read
/// cannot drift apart — a key written in one place and read in another is a
/// report that silently finds nothing.
Future<void> storeImportedGstr2a(
  AppDatabase db,
  String firmId,
  DateTime month,
  Map<String, dynamic> json,
) =>
    db.settingsRepository.set(
      gstr2aStorageKey(DateTime(month.year, month.month)),
      jsonEncode(json),
      firmId: firmId,
    );

Future<List<ReportRow>> gstr2aReconciliationRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  if (!await firmIsGstRegistered(db, firmId)) return const [];

  final json = await readImportedGstr2a(db, firmId, window);
  // Nothing imported for this period. Returning an empty report is the honest
  // answer; the alternative — a report where every row says "matched" because
  // both sides are empty — is a false clean bill of health.
  if (json == null) return const [];

  final firm = await (db.select(db.firms)..where((f) => f.id.equals(firmId)))
      .getSingleOrNull();
  final reconciliation = await Gstr2aReconciliation.fromPortalJson(
    json,
    db: db,
    firmId: firmId,
    from: windowFrom(window),
    to: windowTo(window),
    firmGstin: firm?.gstin ?? '',
  );

  return [
    for (final row in reconciliation.rows)
      ReportRow({
        'invoice': row.invoiceNumber,
        'status': _statusLabel(row.status),
        'booksTaxable': _optDec(row.booksTaxable),
        'booksTax': _optDec(row.booksTax),
        'portalTaxable': _optDec(row.portalTaxable),
        'portalTax': _optDec(row.portalTax),
        // Signed so a books-only row reads as credit at risk and a portal-only
        // row reads as credit not yet claimed: both are differences, and the
        // direction is which side is missing.
        'difference': _optDec(row.booksTax) - _optDec(row.portalTax),
      }, label: row.invoiceNumber),
  ];
}

/// What the reader sees, rather than the wire value.
///
/// The slugs (`books_only`) are what the reconciliation stores and what a
/// programmer reads; a shopkeeper needs to know what to *do*, and "in your
/// books, not in theirs" is the answer.
String _statusLabel(String status) => switch (status) {
      'matched' => 'Matched',
      'books_only' => 'In your books, not in 2A',
      'portal_only' => 'In 2A, not in your books',
      'value_mismatch' => 'Value mismatch',
      _ => status,
    };

/// A nullable figure as an exact [Decimal], with a missing side as zero.
///
/// **Zero, not blank.** A difference is computed from both sides, and a blank
/// cell here would make the reader do the subtraction themselves on the one row
/// type where doing it wrong costs a blocked credit. The direction is carried by
/// the sign.
Decimal _optDec(double? value) =>
    value == null ? Decimal.zero : dec(value);

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _gstr2aNotes(ReportResult result) => [
      'Reconciles purchase bills and debit notes against the imported portal '
      'GSTR-2A for the return period the window falls in. Requires an imported '
      'file; the report is empty without one.',
    ];