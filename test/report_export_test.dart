import 'dart:io';

import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/export/report_export_service.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every report inherits export from one screen, so the export rules are stated
/// once and hold once.
///
/// The two rules under test are the ones a CA hits first:
///
/// 1. **The window goes into the file.** A party statement covering an unstated
///    three months cannot be checked against anything, and the failure is silent
///    — the numbers are right.
/// 2. **Money goes out as a number.** `"₹1,00,000.00"` is a string. Paste that
///    column into a spreadsheet and `SUM` returns zero.
///
/// Rule 2 already caught one real defect: `Decimal.round(scale: 2)` returns the
/// value **unchanged when its own scale is already ≤ 2**, so `Decimal.fromInt(
/// 123456)` exported as `123456` while `123456.50` exported with its decimals. A
/// column mixing the two is read as text from the first row on.
void main() {
  const service = ReportExportService();

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  const spec = ReportSpec(
    id: 'export_test',
    title: 'Sale Purchase By Party',
    category: 'Party',
    groupBy: ReportGroupBy.party,
    columns: [
      ReportColumn(key: 'number', label: 'No.'),
      ReportColumn(key: 'party', label: 'Party'),
      ReportColumn(
        key: 'taxable',
        label: 'Taxable',
        kind: ReportValueKind.money,
      ),
      // A rate is never summed — see the grand-total test below.
      ReportColumn(
        key: 'rate',
        label: 'GST Rate',
        kind: ReportValueKind.percent,
      ),
    ],
  );

  ReportRow row(String party, Object taxable, {Object? rate}) => ReportRow(
    {
      'number': 'INV-1',
      'party': party,
      'taxable': taxable,
      'rate': rate ?? Decimal.fromInt(18),
    },
  );

  ReportResult fold(List<ReportRow> rows) => const ReportRunner().fold(
    spec: spec,
    window: window,
    rows: rows,
    groupKeyOf: (r) => '${r.cells['party']}',
  );

  /// The same result under a different spec, for the filename tests.
  ReportResult relabelled(ReportSpec other) {
    final base = fold([row('A', Decimal.fromInt(1))]);
    return ReportResult(
      spec: other,
      window: window,
      groups: base.groups,
      grandTotals: base.grandTotals,
      count: base.count,
      notes: base.notes,
    );
  }

  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('atria_report_export');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('the filename', () {
    test('carries the title and drops what a filesystem objects to', () {
      const awkward = ReportSpec(
        id: 'x',
        title: 'Sale / Purchase: By Party (FY26)',
        category: 'Party',
        columns: [],
      );
      final stem = ReportExportService.fileStem(relabelled(awkward));
      expect(stem, startsWith('Sale_Purchase_By_Party_FY26_'));
      expect(stem, isNot(contains('/')));
      expect(stem, isNot(contains(':')));
    });

    test('falls back to a name when the title has nothing usable in it', () {
      const blank = ReportSpec(
        id: 'x',
        title: '***',
        category: 'Party',
        columns: [],
      );
      final stem = ReportExportService.fileStem(
        ReportResult(
          spec: blank,
          window: window,
          groups: const [],
          grandTotals: const {},
        ),
      );
      expect(stem, startsWith('report_'));
    });
  });

  group('the header block', () {
    test('states the window, so the numbers in the file mean something', () {
      final block = service.headerBlock(fold([row('A', Decimal.fromInt(1))]));
      final text = block.map((l) => l.join(' ')).join('\n');
      expect(text, contains('Sale Purchase By Party'));
      // The span, not the preset name. "Custom" beside a figure is not a
      // period; two dates are.
      expect(text, contains('2026'), reason: 'the window is not in the header');
      expect(text, isNot(contains('Custom')));
      expect(text, contains('Grouped by'));
      expect(text, contains('Exported'));
    });

    test('carries the notes a source attached', () {
      final result = ReportResult(
        spec: spec,
        window: window,
        groups: fold([row('A', Decimal.fromInt(1))]).groups,
        grandTotals: const {},
        notes: const ['Books exceed the portal by 12.50'],
      );
      final text = service.headerBlock(result).map((l) => l.join()).join('\n');
      expect(text, contains('Books exceed the portal by 12.50'));
    });

    test('leaves the notes row out when there are none', () {
      final block = service.headerBlock(fold([row('A', Decimal.fromInt(1))]));
      expect(
        block.where((l) => l.isNotEmpty && l.first == 'Notes'),
        isEmpty,
      );
    });
  });

  group('CSV', () {
    test('exports money as a bare number a spreadsheet can sum', () {
      final csv = service.toCsv(
        fold([
          row('A', Decimal.parse('123456')),
          row('A', Decimal.fromInt(50)),
        ]),
      );
      expect(csv, contains('123456.00'));

      // The rule is about each *cell*, not the file — a CSV delimits with
      // commas, so "no comma anywhere" is not the claim. The claim is that no
      // figure carries a grouping separator or a currency sign inside it, which
      // is what turns the column into text on paste.
      for (final line in csv.split('\n')) {
        for (final cell in line.split(',')) {
          expect(cell, isNot(contains('₹')));
          expect(cell, isNot(matches(RegExp(r'\d,\d'))));
        }
      }
    });

    test('keeps two decimals even when the value already has scale', () {
      // The defect `exportNumber` was written to prevent. `Decimal.fromInt(100)`
      // round-trips through `round(scale: 2)` as "100", so a column would mix
      // "100" with "100.50" and the spreadsheet reads the first as text.
      final csv = service.toCsv(
        fold([row('A', Decimal.parse('100'))]),
      );
      expect(csv, contains('100.00'));
      expect(csv, isNot(matches(RegExp(r'(?<![\d.])100(?![\d.])'))));
    });

    test('writes one column per declared column, in order', () {
      final lines = service
          .toCsv(fold([row('A', Decimal.fromInt(1))]))
          .split('\n');
      final header = lines.firstWhere(
        (l) => l.startsWith('No.'),
      );
      expect(header, 'No.,Party,Taxable,GST Rate');
    });

    test('writes a subtotal per group and one grand total', () {
      final csv = service.toCsv(
        fold([
          row('A', Decimal.fromInt(100)),
          row('B', Decimal.fromInt(200)),
        ]),
      );
      // The label goes in column 1 — "No." here, because that is the column a
      // total's name belongs in — and the summable columns carry their figure.
      // The non-summable ones are blank rather than repeated per row, so the
      // subtotal cannot be mistaken for another transaction.
      expect(csv, contains('Party total,,100.00,'));
      expect(csv, contains('Party total,,200.00,'));
      expect(csv, contains('Total,,300.00,'));
    });

    test('leaves a non-summable column blank in the total row', () {
      // "Total 18%" is not a number, and printing one invites the reader to add
      // the column up. Two rows at 18% must NOT total to 36%.
      final csv = service.toCsv(
        fold([row('A', Decimal.fromInt(1)), row('A', Decimal.fromInt(1))]),
      );
      final totalLine = csv.split('\n').firstWhere((l) => l.startsWith('Total'));
      expect(totalLine, 'Total,,2.00,');
    });

    test('writes the footnote after the table, where a reader will find it', () {
      const withNote = ReportSpec(
        id: 'export_test',
        title: 'Party',
        category: 'Party',
        columns: [
          ReportColumn(key: 'label', label: 'Description'),
          ReportColumn(
            key: 'amount',
            label: 'Amount',
            kind: ReportValueKind.money,
          ),
        ],
        footnote: 'Quotations are excluded — they are not transactions.',
      );
      final result = const ReportRunner().fold(
        spec: withNote,
        window: window,
        rows: [ReportRow({'label': 'A', 'amount': Decimal.fromInt(1)})],
      );
      final csv = service.toCsv(result);
      expect(csv.trimRight(), endsWith('Quotations are excluded — they are not transactions.'));
      expect(
        csv.indexOf('Total'),
        lessThan(csv.indexOf('Quotations are excluded')),
      );
    });

    test('quotes a cell that carries a comma rather than emitting a column', () {
      final result = const ReportRunner().fold(
        spec: const ReportSpec(
          id: 'x',
          title: 'Party',
          category: 'Party',
          columns: [
            ReportColumn(key: 'label', label: 'Description'),
          ],
        ),
        window: window,
        rows: [
          ReportRow({'label': 'Sharma, Mohan'}),
        ],
      );
      expect(service.toCsv(result), contains('"Sharma, Mohan"'));
    });

    test('writes a UTF-8 BOM so Excel on Windows reads the file as UTF-8', () async {
      final result = const ReportRunner().fold(
        spec: const ReportSpec(
          id: 'x',
          title: 'Party',
          category: 'Party',
          columns: [ReportColumn(key: 'label', label: 'Description')],
        ),
        window: window,
        rows: [ReportRow({'label': 'ज्वेलर्स'})],
      );
      final file = await service.writeCsv(result, dir);
      final bytes = await file.readAsBytes();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      expect(await file.readAsString(), contains('ज्वेलर्स'));
    });
  });

  group('Excel', () {
    late Excel workbook;

    /// The grand-total row, found by its label rather than by a row index —
    /// an index would need re-counting every time the header block changes.
    List<Data?> totalRowOf(Sheet sheet) => sheet.rows.firstWhere(
      (r) => r.isNotEmpty && r.first != null && '${r.first!.value}' == 'Total',
    );

    setUp(() async {
      final file = await service.writeExcel(
        fold([
          row('A', Decimal.parse('123456')),
          row('B', Decimal.parse('50.5')),
        ]),
        dir,
      );
      expect(file.path, endsWith('.xlsx'));
      workbook = Excel.decodeBytes(await file.readAsBytes());
    });

    test('names the sheet after the report', () {
      expect(workbook.sheets.keys, contains('Sale Purchase By Party'));
    });

    test('puts money in as a number, not a string', () {
      final sheet = workbook['Sale Purchase By Party'];
      final cells = sheet.rows.expand((r) => r).whereType<Data>();
      final numeric = cells.where((c) => c.value is DoubleCellValue);
      expect(
        numeric.length,
        greaterThanOrEqualTo(3),
        reason: 'two rows plus the grand total, all numbers',
      );
      // No rupee symbol anywhere in the file: a symbol makes the cell text.
      for (final cell in cells) {
        expect('${cell.value}', isNot(contains('₹')));
      }
    });

    test('carries the window into the sheet', () {
      final sheet = workbook['Sale Purchase By Party'];
      final texts = sheet.rows
          .expand((r) => r)
          .whereType<Data>()
          .map((c) => '${c.value}')
          .where((v) => v.contains('2026'));
      expect(texts, isNotEmpty);
    });

    test('writes the grand total as a bold number', () {
      final totalRow = totalRowOf(workbook['Sale Purchase By Party']);
      final value = totalRow[2]!.value;
      expect(value, isA<DoubleCellValue>());
      expect((value as DoubleCellValue).value, closeTo(123506.5, 0.001));
      expect(totalRow[2]!.cellStyle?.isBold, isTrue);
    });

    test('leaves the percent column out of the total row', () {
      final totalRow = totalRowOf(workbook['Sale Purchase By Party']);
      // Column 2 is money and is a number; column 3 is the percent and must
      // not be. "Total 18%" is not a figure anyone can act on.
      expect(totalRow[2]!.value, isA<DoubleCellValue>());
      expect(
        totalRow.elementAtOrNull(3)?.value,
        anyOf(isNull, isA<TextCellValue>()),
        reason: 'a summed percentage is nonsense',
      );
    });
  });

  group('the one-line summary', () {
    test('counts rows, not groups', () {
      // The distinction is the whole point: a report that hides a group
      // swallowing its members reports the group count and looks short.
      final result = fold([
        row('A', Decimal.fromInt(1)),
        row('A', Decimal.fromInt(1)),
        row('B', Decimal.fromInt(1)),
      ]);
      expect(result.count, 3);
      expect(ReportExportService.describe(result), 'Sale Purchase By Party · 3 rows');
    });

    test('says "row" for one, not "1 rows"', () {
      final result = fold([row('A', Decimal.fromInt(1))]);
      expect(ReportExportService.describe(result), endsWith('1 row'));
    });
  });

  group('integrity still holds on the exported figures', () {
    test('what the file totals is what the table totals', () {
      final result = fold([
        row('A', Decimal.parse('123456')),
        row('B', Decimal.parse('50.5')),
      ]);
      expect(
        ReportIntegrityChecks.assertIntegrity(result).isClean,
        isTrue,
        reason: 'the export prints these numbers, so a bad total is a bad file',
      );
      final csv = service.toCsv(result);
      final totalLine = csv.split('\n').firstWhere((l) => l.startsWith('Total'));
      expect(totalLine, contains('123506.50'));
    });
  });
}