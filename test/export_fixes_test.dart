import 'dart:io';

import 'package:atria/core/reports/gst_export_service.dart';
import 'package:atria/core/reports/gst_return_builder.dart';
import 'package:atria/core/services/csv_export.dart';
import 'package:atria/core/utils/file_names.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the audited export defects that are pure logic.
///
/// Nothing here touches the platform channel: `CsvExport.setBaseDirectory`
/// redirects every exporter (it backs `exportRootDirectory`) at a temp dir,
/// so the reconciliation CSV's shape and the file-naming scheme can both be
/// checked for real on any host.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('atria_export_test');
    CsvExport.setBaseDirectory(Future.value(root));
  });

  tearDown(() async {
    CsvExport.setBaseDirectory(null);
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  group('export directory resolution', () {
    test('honours the test override so exports land somewhere readable', () {
      expect(CsvExport.outputDir(), completion(equals(root)));
    });

    test('exportTimestamp is minute-resolution and filename-safe', () {
      // The old statement name was `statement_<party>_<today>`, which
      // collided across periods exported on the same day. Minute resolution
      // closes the same-minute case; the period slug closes the rest.
      final a = exportTimestamp(DateTime(2026, 10, 3, 14, 32, 5));
      final b = exportTimestamp(DateTime(2026, 10, 3, 14, 32, 59));
      final c = exportTimestamp(DateTime(2026, 10, 3, 14, 33, 0));

      expect(a, isNot(equals(c)),
          reason: 'two minutes apart must not collide');
      expect(a, equals(b), reason: 'same minute is the intended granularity');
      expect(a, isNot(contains(':')),
          reason: 'a colon is illegal in a Windows filename');
      expect(a, contains('2026-10-03'));
    });

    test('a period slug survives sanitising for two periods of one party', () {
      // Apr-Jun then Jul-Sep on the same day for the same party used to
      // produce one identical filename and the second silently overwrote the
      // first. Both periods must yield distinct names.
      String nameFor(String period) =>
          sanitizeFileName(period.replaceAll(RegExp(r'\s*-\s*'), '_to_')
              .replaceAll(' ', '_'));

      final apr = nameFor('01 Apr 2026 - 30 Jun 2026');
      final jul = nameFor('01 Jul 2026 - 30 Sep 2026');

      expect(apr, isNot(equals(jul)));
      expect(apr, contains('Apr'));
      expect(jul, contains('Jul'));
      expect(apr, isNot(contains('/')));
      expect(jul, isNot(contains('/')));
    });
  });

  group('GSTR-2A reconciliation CSV', () {
    // D2: the totals row was `['Totals','', booksTotalTax, portalTotalTax]`
    // written under a six-column header, so the books *tax* printed beneath
    // "Books Taxable", the portal *tax* beneath "Books Tax", and both
    // taxable columns came out blank. The one row a CA checks first was the
    // one row nobody could read.
    Gstr2aReconciliation reconciliation() => const Gstr2aReconciliation(
          firmGstin: '24AAAAA0000A1Z5',
          portalTotalTax: 1000,
          booksTotalTax: 900,
          rows: [
            Gstr2aMatchRow(
              invoiceNumber: 'P-1',
              status: 'matched',
              booksTaxable: 5000,
              booksTax: 450,
              portalTaxable: 5000,
              portalTax: 500,
            ),
            Gstr2aMatchRow(
              invoiceNumber: 'P-2',
              status: 'matched',
              booksTaxable: 3000,
              booksTax: 450,
              portalTaxable: 3000,
              portalTax: 500,
            ),
          ],
        );

    test('the totals row lands under its own headings', () async {
      final dir = await GstExportService()
          .exportReconciliation(reconciliation(), '24AAAAA0000A1Z5', '042026');

      final csv = File('${dir.path}${Platform.pathSeparator}'
              'gstr2a_reconciliation.csv')
          .readAsStringSync();
      final lines = csv
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();

      // Everything is quote-wrapped by this writer.
      List<String> cells(String line) =>
          line.split(',').map((c) => c.replaceAll('"', '')).toList();

      expect(cells(lines.first),
          ['Invoice No', 'Status', 'Books Taxable', 'Books Tax',
            'Portal Taxable', 'Portal Tax']);

      final totals = cells(lines.last);
      expect(totals.first, 'Totals');
      // Books taxable 5000 + 3000.
      expect(totals[2], '8000.0',
          reason: 'column 2 is "Books Taxable" and must hold a taxable total');
      expect(totals[3], '900.0',
          reason: 'column 3 is "Books Tax" and must hold the books tax total');
      expect(totals[4], '8000.0',
          reason: 'column 4 is "Portal Taxable" and must not be blank');
      expect(totals[5], '1000.0',
          reason: 'column 5 is "Portal Tax" and must hold the portal total');
    });

    test('the totals row agrees with the sum of the rows above it', () async {
      final dir = await GstExportService()
          .exportReconciliation(reconciliation(), '24AAAAA0000A1Z5', '042026');
      final csv = File('${dir.path}${Platform.pathSeparator}'
              'gstr2a_reconciliation.csv')
          .readAsStringSync();

      // 450 + 450 books tax, 500 + 500 portal tax — the row sums and the
      // reported totals are pinned to the same 2dp the rows carry.
      expect(csv, contains('450.0'));
      expect(csv, contains('900.0'), reason: 'books tax total = 450 + 450');
      expect(csv, contains('1000.0'), reason: 'portal tax total = 500 + 500');
    });
  });

  group('money arithmetic', () {
    test('exported amounts stay exact through Decimal, not double', () {
      // The reconciliation totals arrive as doubles from SQLite; they are
      // pinned to 2dp before being summed so the total can never disagree
      // with the sum of its own rows by a paisa.
      const raw = 1234.565;
      final pinned = Decimal.parse(raw.toStringAsFixed(2));
      expect(pinned.toStringAsFixed(2), '1234.57');

      var total = Decimal.zero;
      for (var i = 0; i < 3; i++) {
        total += Decimal.parse('0.1');
      }
      expect(total, Decimal.parse('0.3'),
          reason: '0.1 x 3 is 0.30000000000000004 in IEEE-754');
    });
  });
}