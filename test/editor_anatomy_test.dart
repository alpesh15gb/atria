import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/shared/widgets/atria_form_section.dart';
import 'package:atria/shared/widgets/atria_line_grid.dart';
import 'package:atria/shared/widgets/editor_totals.dart';
import 'package:atria/shared/widgets/tax_mode_toggle.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the shared "simple as Excel, precise as Tally" editor anatomy:
///
/// * [AtriaLineGrid] is a spreadsheet on a desktop window (a labelled header
///   row, one hairlined row per line, a gutter) and a labelled card per line on
///   a phone — the same widget, re-flowed.
/// * [AtriaTotalsBlock] renders the full GST breakdown with rate-labelled
///   CGST/SGST rows and the grand total, for every document type.
/// * [AtriaTaxModePill] cycles inclusive/exclusive in one tap, which is what
///   lets a per-line tax mode survive in a table cell.
void main() {
  const columns = [
    AtriaLineColumn('Item / Description', flex: 5),
    AtriaLineColumn('Qty', flex: 3, numeric: true),
    AtriaLineColumn('Amount', flex: 3, numeric: true),
  ];

  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget grid({VoidCallback? onAddRow, int rows = 1, VoidCallback? onRemove}) {
    return AtriaLineGrid(
      columns: columns,
      addLabel: 'Add lines',
      onAddRow: onAddRow ?? () {},
      rows: [
        for (var i = 0; i < rows; i++)
          AtriaLineGridRow(
            cells: [
              Text('Widget $i'),
              Text('${i + 1} qty'),
              Text('${i + 1}00 amount'),
            ],
            onRemove: onRemove,
          ),
      ],
    );
  }

  testWidgets('a desktop-width grid is a spreadsheet: header row + gutter',
      (tester) async {
    var added = 0;
    await pumpAt(tester, grid(onAddRow: () => added++),
        size: const Size(1200, 900));

    // Every column names itself once, in the sheet's own header row.
    for (final column in columns) {
      expect(find.text(column.label), findsOneWidget,
          reason: 'the header row labels each column');
    }
    // The row number lives in the gutter; the label is the column's, not the
    // cell's — cells are bare inputs, which is what makes it read as a sheet.
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Widget 0'), findsOneWidget);

    await tester.tap(find.text('Add lines'));
    expect(added, 1);

    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone-width grid becomes labelled cards', (tester) async {
    await pumpAt(tester, grid(rows: 2), size: const Size(400, 900));

    // The header row is gone, so each cell has to say what it is — uppercase,
    // in the column's own words.
    expect(find.text(columns[0].label), findsNothing);
    expect(find.text('QTY'), findsNWidgets(2));
    expect(find.text('AMOUNT'), findsNWidgets(2));
    expect(find.text('Widget 1'), findsOneWidget);
    // One card per line, each with its own add-row link underneath.
    expect(find.text('Add lines'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the grid removes a line through its gutter on hover',
      (tester) async {
    var removed = 0;
    await pumpAt(
      tester,
      grid(onRemove: () => removed++),
      size: const Size(1200, 900),
    );

    // The gutter shows the number until the pointer arrives, then a delete.
    final gutter = find.descendant(
      of: find.byType(AtriaLineGrid),
      matching: find.byType(MouseRegion),
    );
    expect(gutter, findsWidgets);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(find.text('Widget 0')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Remove line'));
    expect(removed, 1);
  });

  testWidgets('the tax-mode pill cycles inclusive/exclusive', (tester) async {
    var mode = TaxMode.exclusive;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: AtriaTaxModePill(
              value: mode,
              onChanged: (next) => setState(() => mode = next),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Excl'), findsOneWidget);
    await tester.tap(find.text('Excl'));
    await tester.pumpAndSettle();
    expect(find.text('Incl'), findsOneWidget);

    await tester.tap(find.text('Incl'));
    await tester.pumpAndSettle();
    expect(find.text('Excl'), findsOneWidget);
  });

  testWidgets('the totals block prints the rate-wise GST breakdown',
      (tester) async {
    final totals = GstEngine.computeDocument(
      lines: [
        TaxLine(
          id: 'l1',
          itemId: null,
          name: 'Consulting',
          hsn: '9983',
          quantity: Decimal.fromInt(10),
          unit: 'pcs',
          rate: Decimal.fromInt(100),
          discountPercent: Decimal.zero,
          gstRate: 18,
          cessRate: 0,
          taxMode: TaxMode.exclusive,
        ),
      ],
      split: GstSplit.intraState,
    );

    await pumpAt(
      tester,
      AtriaTotalsBlock(
        totals: totals,
        extraCharges: Decimal.fromInt(50),
        extraRows: [EditorTotalsRow('Shipping', Decimal.fromInt(50))],
      ),
      size: const Size(900, 900),
    );

    expect(find.text('Subtotal'), findsOneWidget);
    expect(find.text('Taxable value'), findsOneWidget);
    // Tally prints the rate on the tax line; a bare "CGST" does not tell a
    // reader which slab was applied.
    expect(find.text('CGST 9%'), findsOneWidget);
    expect(find.text('SGST 9%'), findsOneWidget);
    expect(find.text('Shipping'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> pumpPage(WidgetTester tester, Size size) => pumpAt(
        tester,
        const AtriaEditorForm(
          header: Text('Party'),
          headerTrailing: Text('Dates'),
          lines: Text('Lines'),
          totals: Text('Totals'),
        ),
        size: size,
      );

  testWidgets('the document page shares one header row on a desktop window',
      (tester) async {
    await pumpPage(tester, const Size(1200, 900));
    final header = tester.getTopLeft(find.text('Party'));
    final trailing = tester.getTopLeft(find.text('Dates'));
    expect(trailing.dy, header.dy);
    expect(trailing.dx, greaterThan(header.dx));
  });

  testWidgets('the document page stacks its header on a phone',
      (tester) async {
    await pumpPage(tester, const Size(600, 900));
    final header = tester.getTopLeft(find.text('Party'));
    final trailing = tester.getTopLeft(find.text('Dates'));
    expect(trailing.dy, greaterThan(header.dy));
  });
}
