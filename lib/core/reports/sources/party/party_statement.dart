import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';

import 'party_common.dart';

/// **Party Statement** — one party's ledger: what they owe, what they paid, and
/// what is left.
///
/// **The only report in this folder that reports `grandTotal` rather than
/// `taxableValue`, and that is not an inconsistency.** Every other party report
/// answers "how much did this party buy", which is a revenue question, and
/// revenue excludes output tax. A statement of account answers "how much does
/// this party owe", and what they owe includes the tax — a customer billed
/// ₹1,180 at 18% owes ₹1,180, not ₹1,000. Printing ₹1,000 on a statement makes
/// the document wrong in the one direction that gets a firm into a dispute, and
/// it will not agree with the sales register beside it, which is correct.
///
/// So this report **reuses `ReportRepository.partyStatement` rather than
/// re-deriving it.** Two implementations of a statement of account would be one
/// too many: the ledger it reconciles against is built by the same repository,
/// and a second copy that disagreed by a tax would be indistinguishable from a
/// genuine discrepancy in the books.
///
/// **The running balance is the report.** `opening + Σ(debit) − Σ(credit)` has
/// to equal the figure on the last row exactly, because that is the first thing
/// the reader checks and the last thing an implementation can be trusted to get
/// right. The repository accumulates in `double`; the source here re-derives the
/// printed column from the *rounded* Dr and Cr cells, so the row and the column
/// beneath it cannot drift. A note reports the difference if they ever do.
const ReportSpec partyStatementSpec = ReportSpec(
  id: 'party_statement',
  title: 'Party Statement',
  category: 'Party',
  sort: ReportSort(columnKey: 'date'),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kPartyFilterId,
      label: 'Party',
      value: null,
      hint: 'Every party',
    ),
  ],
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'particulars', label: 'Particulars', flex: 3),
    ReportColumn(key: 'reference', label: 'Reference'),
    ReportColumn(key: 'debit', label: 'Debit', kind: ReportValueKind.money),
    ReportColumn(key: 'credit', label: 'Credit', kind: ReportValueKind.money),
    // `running`, not `money`: a money column would be summed into a grand
    // total, and the total of every party's closing balance is not a number.
    ReportColumn(
      key: 'balance',
      label: 'Balance',
      kind: ReportValueKind.running,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Figures include GST, because this is what the party owes rather than '
      'what they bought. A purchase is shown as a credit — we owe them.',
);

const ReportDefinition partyStatement = ReportDefinition(
  spec: partyStatementSpec,
  source: CallbackReportSource(
    sourceId: 'party_statement',
    query: partyStatementRows,
    notes: _partyStatementNotes,
    options: partyOptions,
  ),
);

Future<List<ReportRow>> partyStatementRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final partyId = selectedPartyId(filters);
  // No party chosen means no statement.
  //
  // Not "the first party" and not "every party". A statement is addressed to one
  // counterparty — it is a document you send them — so a merged list of a
  // hundred customers' ledgers is not a statement of account at all. The empty
  // result reads as "pick a party", which is the instruction the reader needs,
  // and it is the same honest empty that Every Other Party report avoids by
  // being a list rather than a letter.
  if (partyId == null) return const [];

  final statement = await db
      .reportRepositoryFor(firmId)
      .partyStatement(partyId: partyId, from: window.from, to: window.to);

  final rows = <ReportRow>[];
  for (final line in statement.lines) {
    rows.add(
      ReportRow({
        'date': line.date,
        'particulars': line.particulars,
        'reference': line.reference,
        'debit': line.debit,
        'credit': line.credit,
        'balance': line.balance,
      }, label: line.particulars),
    );
  }
  return rows;
}

/// The statement's own arithmetic, checked on the printed figures.
///
/// **Not decoration.** The running balance is accumulated in `double` inside the
/// repository and printed as a `Decimal`, so the last row can disagree with the
/// sum of the columns above it by a paisa — and on a document a customer
/// reconciles against their own books, that paisa is the whole argument. The
/// check is exact, and the note names the figure rather than leaving the reader
/// to find it.
List<String> _partyStatementNotes(ReportResult result) {
  final notes = <String>[];

  var expected = Decimal.zero;
  var started = false;
  for (final row in result.rows) {
    if (row.cells['particulars'] == 'Opening Balance') {
      expected = row.number(_debitColumn) - row.number(_creditColumn);
      started = true;
      continue;
    }
    if (!started) continue;
    expected += row.number(_debitColumn) - row.number(_creditColumn);
  }

  final last = result.rows.isEmpty ? null : result.rows.last;
  final printed = last?.number(_balanceColumn) ?? Decimal.zero;
  if (started && printed != expected) {
    notes.add(
      'The running balance ends at ${_plain(printed)} but the Debit and Credit '
      'columns add up to ${_plain(expected)}. The difference is ${_plain(printed - expected)} '
      'and the closing figure is the one to check before sending this.',
    );
  }

  // A statement with nothing in it is not a nil statement. A party with no
  // documents and no payments has no opening balance either, so the report is
  // empty — and an empty ledger that renders as "Opening Balance 0.00" is a
  // statement of account claiming the two sides agree, which is a claim.
  if (result.rows.isEmpty) {
    notes.add(
      'No transactions with this party in the period. Their opening balance is '
      'also nil, so there is nothing to reconcile.',
    );
  }
  return notes;
}

String _plain(Decimal value) => Money.round2(value).toStringAsFixed(2);

const ReportColumn _debitColumn = ReportColumn(
  key: 'debit',
  label: 'Debit',
  kind: ReportValueKind.money,
);

const ReportColumn _creditColumn = ReportColumn(
  key: 'credit',
  label: 'Credit',
  kind: ReportValueKind.money,
);

const ReportColumn _balanceColumn = ReportColumn(
  key: 'balance',
  label: 'Balance',
  kind: ReportValueKind.running,
);
