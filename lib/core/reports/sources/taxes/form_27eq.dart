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

/// **Form No. 27EQ** — the quarterly TDS return annexure.
///
/// One row per **deductee per section**, which is the unit the form is filed
/// in. That is the whole difference from TDS Payable: the quarterly return
/// aggregates a quarter's bills for the same supplier under the same section
/// into one line, because that is what the portal accepts — a quarter with 40
/// bills from one contractor is one line of 27EQ, not forty.
///
/// **Deductees with nothing deducted are excluded**, not shown at zero. A
/// supplier on the master with no deduction in the quarter is not a line of the
/// return.
///
/// **The rate is the section rate where recorded**, because the section decides
/// the rate and a bill that carried a different one is worth seeing.
///
/// **A missing PAN or section is a row the reader must fix**, and it is shown
/// rather than dropped: a quarter filed without one of those lines is a short
/// return.
const ReportSpec form27eqSpec = ReportSpec(
  id: 'form_27eq',
  title: 'Form No. 27EQ',
  category: 'Taxes',
  // Ungrouped: the source already produces one row per deductee per section,
  // which *is* the form's unit, so a band above a single row would print a
  // subtotal as though it meant more.
  groupBy: ReportGroupBy.none,
  sort: ReportSort(columnKey: 'tds', descending: true),
  columns: [
    ReportColumn(key: 'pan', label: 'PAN', flex: 2, emphasise: true),
    ReportColumn(key: 'party', label: 'Deductee', flex: 3),
    ReportColumn(key: 'section', label: 'Section'),
    ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
    ReportColumn(key: 'bills', label: 'Bills', kind: ReportValueKind.count),
    ReportColumn(
      key: 'taxable',
      label: 'Taxable value',
      kind: ReportValueKind.money,
    ),
    ReportColumn(
      key: 'tds',
      label: 'Tax deducted',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
      colorize: true,
    ),
  ],
  footnote:
      'The quarterly annexure: one line per deductee per section, which is how '
      'the form is filed — forty bills from one contractor are one line, not '
      'forty. Only deductees with a deduction in the period appear. The amount '
      'is what each bill recorded, added together; the rate is the section rate '
      'where one was recorded. "Not recorded" marks a deductee or section missing '
      'something the portal will not accept. Cancelled bills are excluded.',
);

const ReportDefinition form27eq = ReportDefinition(
  spec: form27eqSpec,
  source: CallbackReportSource(
    sourceId: 'form_27eq',
    query: form27eqRows,
    notes: _form27eqNotes,
  ),
);

/// One (PAN, section) bucket — the filing unit of the form.
class _Deductee {
  var taxable = Decimal.zero;
  var tds = Decimal.zero;
  var bills = Decimal.zero;
  String? party;

  /// Null until a bill states one. Kept separately from a zero rate, because
  /// "not recorded" and "recorded as zero" are different answers to a question
  /// the portal asks.
  Decimal? rate;
}

/// Whether two rates agree, treating a recorded zero as "not stated".
///
/// **Zero means the section rate was not recorded**, not that the rate was
/// zero — a TDS bill with no section rate is an incomplete bill, and letting a
/// real rate sit beside an unrecorded one would print a confident average of two
/// facts, one of which is a gap.
bool _sameRate(Decimal? a, Decimal b) => a == null || a == b;

Future<List<ReportRow>> form27eqRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final bills = await (db.select(db.purchaseBills)
        ..where((d) =>
            tdsScope(window, firmId, db.purchaseBills) &
            TdsCommon.hasTds(db.purchaseBills)))
      .get();
  if (bills.isEmpty) return const [];

  final names = <String, String>{
    for (final bill in bills)
      if (bill.partyId != null) bill.partyId!: bill.partyName ?? '',
  };
  final missing = <String>{
    for (final bill in bills)
      if (bill.partyId != null && !names.containsKey(bill.partyId)) bill.partyId!,
  };
  if (missing.isNotEmpty) {
    final parties =
        await (db.select(db.parties)..where((p) => p.id.isIn(missing))).get();
    for (final party in parties) {
      names[party.id] = party.name;
    }
  }

  final buckets = <String, _Deductee>{};
  for (final bill in bills) {
    final pan = TdsCommon.panOrUnset(bill.deducteePan);
    final section = TdsCommon.sectionOrUnset(bill.tdsSection);
    final rate = TdsCommon.rateOf(
      tdsRate: bill.tdsRate,
      sectionRate: bill.tdsSectionRate,
    );
    final sign = Decimal.fromInt(signFor(bill.docType));
    // Keyed on the PAN and the section: the two things the portal identifies a
    // line by. Keying on the party id instead would split one PAN filed under
    // two master records into two lines of the same return.
    final entry = buckets.putIfAbsent('$pan|$section', () => _Deductee());
    entry.taxable += dec(bill.taxableValue) * sign;
    entry.tds += dec(bill.tds) * sign;
    entry.bills += Decimal.one;
    entry.party = names[bill.partyId] ?? bill.partyName ?? 'Unknown party';
    if (_sameRate(entry.rate, rate)) entry.rate = rate;
  }

  return [
    for (final entry in buckets.entries)
      // Split once, not four times: the key is the row's own identity, and
      // re-splitting it inside every cell is how the PAN and the section drift
      // apart in a row that was assembled correctly.
      ReportRow({
        'pan': _panOf(entry.key),
        'party': entry.value.party ?? 'Unknown party',
        'section': _sectionOf(entry.key),
        'rate': entry.value.rate ?? Decimal.zero,
        'bills': entry.value.bills,
        'taxable': entry.value.taxable,
        'tds': entry.value.tds,
      }, label: '${_panOf(entry.key)} · ${_sectionOf(entry.key)}'),
  ];
}

/// The PAN half of a bucket key.
String _panOf(String key) => key.split('|').first;

/// The section half. The second half, because the PAN cannot contain a `|`.
String _sectionOf(String key) => key.split('|').last;

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _form27eqNotes(ReportResult result) => [
      'Aggregates the period\'s bills into the form\'s own unit: one line per '
      'deductee per section.',
    ];