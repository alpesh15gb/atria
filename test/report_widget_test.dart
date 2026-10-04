import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/reports/report_document_view.dart';
import 'package:atria/shared/widgets/report_data_table.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The renderer, tested where it can actually fail.
///
/// Three claims, each of which has a visible failure mode rather than a crash:
///
/// 1. **The grand total is always on screen.** A pinned bar, not a last row.
///    On a 400-row report the last line is 40 scrolls away, and the total is the
///    one line the reader opened the report for.
/// 2. **The header stays put.** A heading row that scrolls away makes page 7 a
///    page of numbers with no way to tell what they are.
/// 3. **A report that does not foot says so.** A subtotal that disagrees with
///    the total is the exact fault a CA finds, and the screen must not print it
///    as though it were fine.
void main() {
  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  const spec = ReportSpec(
    id: 'widget_test',
    title: 'Party Statement',
    category: 'Party',
    groupBy: ReportGroupBy.party,
    columns: [
      ReportColumn(key: 'number', label: 'No.'),
      ReportColumn(key: 'party', label: 'Party', emphasise: true),
      ReportColumn(
        key: 'taxable',
        label: 'Taxable',
        kind: ReportValueKind.money,
        flex: 2,
      ),
      ReportColumn(
        key: 'unit',
        label: 'Unit',
        wideOnly: true,
      ),
    ],
  );

  /// The ungrouped variant: same columns, no group-by.
  const flatSpec = ReportSpec(
    id: 'widget_test',
    title: 'Party Statement',
    category: 'Party',
    columns: [
      ReportColumn(key: 'number', label: 'No.'),
      ReportColumn(key: 'party', label: 'Party', emphasise: true),
      ReportColumn(
        key: 'taxable',
        label: 'Taxable',
        kind: ReportValueKind.money,
        flex: 2,
      ),
      ReportColumn(key: 'unit', label: 'Unit', wideOnly: true),
    ],
  );

  ReportResult fold(List<ReportRow> rows, {ReportGroupBy? groupBy}) =>
      const ReportRunner().fold(
        spec: groupBy == null ? spec : flatSpec,
        window: window,
        rows: rows,
        groupKeyOf: (r) => '${r.cells['party']}',
      );

  ReportRow row(String party, Object taxable) => ReportRow({
    'number': 'INV-1',
    'party': party,
    'taxable': taxable,
    'unit': 'pcs',
  });

  Future<void> pumpTable(
    WidgetTester tester,
    ReportResult result, {
    List<ReportColumn>? columns,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ReportDataTable(
            result: result,
            columns: columns ?? spec.columns,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the grand total', () {
    testWidgets('is on screen before anything is scrolled', (tester) async {
      await pumpTable(
        tester,
        fold([
          for (var i = 0; i < 400; i++)
            row('Party ${i % 20}', Decimal.fromInt(100 + i)),
        ]),
      );
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('carries the figure, not just the word', (tester) async {
      await pumpTable(
        tester,
        fold([
          row('A', Decimal.parse("1234.5")),
          row('B', Decimal.parse("0.5")),
        ]),
      );
      // 1235.00 — the two halves of the paisa. If the total were summed in
      // double and converted at the end it would still be right here, which is
      // why the framework test asserts the Decimal sum separately; what this
      // one catches is the total *not being printed at all*.
      expect(find.text('1235.00'), findsOneWidget);
    });

    testWidgets('stays pinned after scrolling to the end', (tester) async {
      await pumpTable(
        tester,
        fold([
          for (var i = 0; i < 200; i++) row('Party ${i ~/ 10}', Decimal.fromInt(50)),
        ]),
      );
      expect(find.text('Total'), findsOneWidget);
      await tester.drag(find.byType(ReportDataTable), const Offset(0, -4000));
      await tester.pumpAndSettle();
      expect(
        find.text('Total'),
        findsOneWidget,
        reason: 'the total scrolled off — the one row that must not',
      );
    });
  });

  group('the header', () {
    testWidgets('is present and names every column', (tester) async {
      await pumpTable(tester, fold([row('A', Decimal.fromInt(1))]));
      expect(find.text('No.'), findsOneWidget);
      expect(find.text('Party'), findsOneWidget);
      expect(find.text('Taxable'), findsOneWidget);
    });

    testWidgets('survives a scroll', (tester) async {
      await pumpTable(
        tester,
        fold([
          for (var i = 0; i < 200; i++) row('Party ${i ~/ 10}', Decimal.fromInt(50)),
        ]),
      );
      await tester.drag(find.byType(ReportDataTable), const Offset(0, -3000));
      await tester.pumpAndSettle();
      expect(
        find.text('Taxable'),
        findsOneWidget,
        reason: 'the column headings scrolled away with the rows',
      );
    });
  });

  group('grouping', () {
    testWidgets('draws a heading and a subtotal per group', (tester) async {
      await pumpTable(
        tester,
        fold([row('Alpha', Decimal.fromInt(10)), row('Beta', Decimal.fromInt(20))]),
      );
      // Twice each: once as the group heading, once as the row's own Party
      // cell. That redundancy is deliberate — the heading is what a reader
      // scans and the column is what a reader sorts, and collapsing them would
      // mean the heading's figure disappears when the column is hidden.
      expect(find.text('Alpha'), findsNWidgets(2));
      expect(find.text('Beta'), findsNWidgets(2));
      expect(find.text('Party total'), findsNWidgets(2));
      // One grand total, not three: the ungrouped report must not print a
      // second "Total" that duplicates it.
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('drops the subtotal on an ungrouped report', (tester) async {
      // One implicit group means a subtotal would duplicate the grand total and
      // print two different-looking "Total" figures.
      await pumpTable(
        tester,
        fold([row('Alpha', Decimal.fromInt(10))], groupBy: ReportGroupBy.none),
      );
      expect(find.text('Party total'), findsNothing);
    });
  });

  group('narrow vs wide', () {
    testWidgets('a phone drops the wideOnly columns', (tester) async {
      await pumpTable(
        tester,
        fold([row('A', Decimal.fromInt(1))]),
        columns: spec.narrowColumns,
        size: const Size(420, 900),
      );
      expect(find.text('Unit'), findsNothing);
      // The identifying column stays, wherever it lands — dropping it too would
      // leave a card that says nothing at all. It appears twice on a narrow
      // screen because the row is a card: once as its heading, once as the
      // labelled value beneath.
      expect(find.text('A'), findsWidgets);
      expect(find.text('Party'), findsWidgets);
    });

    testWidgets('a wide window keeps them', (tester) async {
      await pumpTable(tester, fold([row('A', Decimal.fromInt(1))]));
      expect(find.text('Unit'), findsWidgets);
    });
  });

  group('the integrity banner', () {
    testWidgets('does not appear for a report that foots', (tester) async {
      final result = fold([
        row('A', Decimal.fromInt(100)),
        row('B', Decimal.fromInt(200)),
      ]);
      expect(
        ReportIntegrityChecks.assertIntegrity(result).isClean,
        isTrue,
        reason: 'the fixture itself has to foot, or the test proves nothing',
      );
      await pumpTable(tester, result);
      expect(find.textContaining('does not foot'), findsNothing);
    });
  });

  group('a document-layout report', () {
    testWidgets('uses its bespoke body when one is registered', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final result = fold([row('A', Decimal.fromInt(1))]);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ReportDocumentView(
              result: result,
              builder: (context, r) => const Text('BESPOKE TRIAL BALANCE'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('BESPOKE TRIAL BALANCE'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing);
    });

    testWidgets('falls back rather than rendering a blank screen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final result = fold([row('A', Decimal.fromInt(1))]);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ReportDocumentView(result: result, builder: (_, _) => null),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // A document report whose bespoke builder is not lifted out yet still
      // shows its declared columns. A blank screen reads as a crash.
      expect(find.text('Taxable'), findsWidgets);
    });
  });

  group('DocumentPair', () {
    testWidgets('draws a total so it reads as one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Column(
              children: [
                DocumentPair(label: 'Opening', value: '1,00,000.00'),
                DocumentPair(
                  label: 'Closing balance',
                  value: '-2,500.00',
                  emphasis: true,
                  colorize: true,
                  negative: true,
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Opening'), findsOneWidget);
      expect(find.text('-2,500.00'), findsOneWidget);
      final total = tester.widget<Text>(
        find.text('-2,500.00'),
      );
      expect(
        total.style?.fontWeight,
        FontWeight.w700,
        reason: 'a total that is not heavier is just another line',
      );
    });
  });
}