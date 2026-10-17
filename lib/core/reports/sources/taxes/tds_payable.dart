import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';
import 'tds_common.dart';

/// **TDS Payable** — tax deducted at source and owed to the government.
///
/// One row per bill that carried a deduction, which is the unit a 26Q is
/// quarterly return of: the deductee, the section, the rate, and the amount.
///
/// **The amount is the stored `tds`, never re-derived from the rate.** The bill
/// recorded what was actually deducted, which is a function of that bill's
/// taxable value and the section rate applied to it. Multiplying the rate by
/// today's figure would produce a different number on any partly exempt bill,
/// and a 26Q that disagrees with the bill is a query.
///
/// **A debit note reverses.** It returns goods, so the deduction on it is
/// negative and comes off the quarter's liability — the same doc-type sign rule
/// the GST reports use. Summing it positive overstates what is owed.
///
/// **A bill with no section recorded is shown, flagged, not hidden.** The reader
/// has to fix it before filing; a report that quietly leaves it out is a report
/// that gets filed short.
const ReportSpec tdsPayableSpec = ReportSpec(
  id: 'tds_payable',
  title: 'TDS Payable',
  category: 'Taxes',
  sort: ReportSort(columnKey: 'tds', descending: true),
  columns: [
    ReportColumn(key: 'date', label: 'Date', flex: 2),
    ReportColumn(key: 'number', label: 'Bill', flex: 2),
    ReportColumn(key: 'party', label: 'Deductee', flex: 3, emphasise: true),
    ReportColumn(key: 'pan', label: 'PAN', flex: 2),
    ReportColumn(key: 'section', label: 'Section'),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'tds',
      label: 'TDS deducted',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'One row per bill that carried a deduction, which is what a 26Q is a '
      'return of. The amount is the deduction recorded on the bill, not the '
      'rate re-applied to it — a partly exempt bill was taxed on its own taxable '
      'value. A debit note reduces the quarter, because a return reverses the '
      'deduction. "Not recorded" means the bill is missing a section or PAN and '
      'cannot be filed until it is fixed. Cancelled bills are excluded.',
);

const ReportDefinition tdsPayable = ReportDefinition(
  spec: tdsPayableSpec,
  source: CallbackReportSource(
    sourceId: 'tds_payable',
    query: tdsPayableRows,
    notes: _tdsPayableNotes,
  ),
);

Future<List<ReportRow>> tdsPayableRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final bills =
      await (db.select(db.purchaseBills)..where(
            (d) =>
                tdsScope(window, firmId, db.purchaseBills) &
                TdsCommon.hasTds(db.purchaseBills),
          ))
          .get();
  if (bills.isEmpty) return const [];

  // The party name as filed, with the master's as a fallback for a bill whose
  // name was cleared.
  final names = <String, String>{
    for (final bill in bills)
      if (bill.partyId != null) bill.partyId!: bill.partyName ?? '',
  };
  final missing = <String>{
    for (final bill in bills)
      if (bill.partyId != null && !names.containsKey(bill.partyId))
        bill.partyId!,
  };
  if (missing.isNotEmpty) {
    final parties = await (db.select(
      db.parties,
    )..where((p) => p.id.isIn(missing))).get();
    for (final party in parties) {
      names[party.id] = party.name;
    }
  }

  return [
    for (final bill in bills)
      ReportRow({
        'date': bill.billDate,
        'number': bill.number,
        'party': names[bill.partyId] ?? bill.partyName ?? 'Unknown party',
        'pan': TdsCommon.panOrUnset(bill.deducteePan),
        'section': TdsCommon.sectionOrUnset(bill.tdsSection),
        'rate': TdsCommon.rateOf(
          tdsRate: bill.tdsRate,
          sectionRate: bill.tdsSectionRate,
        ),
        'taxable': dec(bill.taxableValue),
        // Signed by the document type, so a debit note comes off the quarter.
        'tds': dec(bill.tds) * Decimal.fromInt(signFor(bill.docType)),
      }, label: bill.number),
  ];
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _tdsPayableNotes(ReportResult result) => [
  'Reads purchase bills and debit notes in the window. Only bills that '
      'actually carried a deduction are listed.',
];
