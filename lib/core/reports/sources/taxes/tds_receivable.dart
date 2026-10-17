import 'package:drift/drift.dart';

import '../../../database/app_database.dart';
import '../../catalogue/report_catalogue.dart';
import '../../engine/report_result.dart';
import '../../engine/report_source.dart';
import '../../spec/report_spec.dart';
import '../../window/report_window.dart';
import '../transaction/transaction_common.dart';
import '../gst/gst_common.dart' show windowFrom, windowTo;

const tdsReceivable = ReportDefinition(
  spec: ReportSpec(
    id: 'tds_receivable',
    title: 'TDS Receivable',
    category: 'Taxes',
    columns: [
      ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
      ReportColumn(key: 'number', label: 'Voucher'),
      ReportColumn(key: 'reference', label: 'Reference'),
      ReportColumn(key: 'narration', label: 'Description', flex: 3),
      ReportColumn(
        key: 'debit',
        label: 'TDS recorded',
        kind: ReportValueKind.money,
      ),
      ReportColumn(
        key: 'credit',
        label: 'Settled / reversed',
        kind: ReportValueKind.money,
      ),
      ReportColumn(
        key: 'net',
        label: 'Net movement',
        kind: ReportValueKind.money,
      ),
    ],
    footnote: 'Reads journal postings to TDS receivable account 1310. Record customer deductions through a journal voucher. This is ledger movement, not a Form 26AS download or proof of tax credit.',
  ),
  source: CallbackReportSource(
    sourceId: 'tds_receivable',
    query: tdsReceivableRows,
  ),
);

Future<List<ReportRow>> tdsReceivableRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final entries = db.journalEntries;
  final lines = db.journalLines;
  final accounts = db.accounts;
  final query =
      db.select(lines).join([
        innerJoin(entries, entries.id.equalsExp(lines.entryId)),
        innerJoin(accounts, accounts.id.equalsExp(lines.accountId)),
      ])..where(
        entries.firmId.equals(firmId) &
            accounts.firmId.equals(firmId) &
            accounts.code.equals('1310') &
            entries.isDeleted.equals(false) &
            entries.date.isBetweenValues(windowFrom(window), windowTo(window)),
      );
  return [
    for (final row in await query.get())
      ReportRow({
        'date': row.readTable(entries).date,
        'number': row.readTable(entries).number,
        'reference': row.readTable(entries).reference ?? '',
        'narration':
            row.readTable(lines).narration ?? row.readTable(entries).narration,
        'debit': dec(row.readTable(lines).debit),
        'credit': dec(row.readTable(lines).credit),
        'net': dec(row.readTable(lines).debit - row.readTable(lines).credit),
      }),
  ];
}
