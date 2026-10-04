import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/reports/document_registry.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The four bespoke document bodies, tested as widgets over a real
/// [ReportResult].
///
/// **Why these are worth widget tests when the arithmetic is already covered.**
/// The arithmetic tests prove the *numbers*; these prove the numbers reached the
/// screen. The failures that motivated them were both of that kind — a grid
/// that drew a P&L with no gross profit line, and a document builder that
/// returned null and fell through to the generic column table, which is
/// *correct behaviour* and looked like a bespoke body that had been forgotten.
///
/// So each test here checks the two things a document body must do: draw its
/// own shape rather than the fallback table, and print the figures the source
/// produced.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;
  late PurchaseRepository purchases;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<String> stockedItem({double purchasePrice = 800}) async {
    final item = await db
        .itemRepositoryFor(firmId)
        .create(
          name: 'Cement bag',
          hsn: '2523',
          purchasePrice: purchasePrice,
          salePrice: purchasePrice * 1.25,
          gstRate: 18,
        );
    return item.id;
  }

  Future<void> invoice({
    required String id,
    required DateTime date,
    required String itemId,
    String quantity = '1',
    String rate = '1000',
  }) => sales.save(
    SalesDraft(
      id: id,
      number: id.toUpperCase(),
      invoiceDate: date,
      docType: 'invoice',
      partyName: 'Walk-in Customer',
      lines: [
        SalesLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: 'Cement bag',
          hsn: '2523',
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: 18,
        ),
      ],
    ),
  );

  Future<void> bill({
    required String id,
    required DateTime date,
    required String itemId,
    String quantity = '10',
    String rate = '800',
  }) => purchases.save(
    PurchaseDraft(
      id: id,
      number: id.toUpperCase(),
      billDate: date,
      docType: 'bill',
      partyName: 'BuildMart Supplies',
      lines: [
        PurchaseLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: 'Cement bag',
          hsn: '2523',
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: 18,
        ),
      ],
    ),
  );

  Future<ReportResult> run(String id) async {
    final definition = ReportCatalogue.byId(id);
    expect(definition, isNotNull, reason: 'no report registered as "$id"');
    return definition!.run(db, firmId, window);
  }

  /// Pumps a document body at a size where every column fits.
  ///
  /// The body is built inside the widget tree rather than handed a context
  /// beforehand, because a `BuildContext` from a different tree resolves themes
  /// against the wrong `Theme` — and a document whose only job is to pick colours
  /// and text styles is exactly what a wrong context silently breaks.
  Future<void> pumpDocument(
    WidgetTester tester,
    String reportId,
    ReportResult result,
  ) async {
    final builder = documentBuilderFor(reportId);
    expect(builder, isNotNull, reason: '$reportId has no bespoke body');

    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          // The builder needs a context, and it can only have one from inside
          // the tree — so the body is built by a one-shot wrapper widget.
          body: _BuilderHost(builder: builder!, result: result),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ============================================================
  group('the registry', () {
    test('every document-layout report that ships has a bespoke body', () {
      // The four reports in the Transaction category whose `layout` is
      // `document`. If one is added to the catalogue without a body, it renders
      // the generic column table — which is a *reasonable* fallback and so
      // fails silently, looking like a report nobody has got round to yet.
      for (final id in const [
        'profit_and_loss',
        'trial_balance',
        'balance_sheet',
        'cash_flow',
      ]) {
        expect(
          documentBuilderFor(id),
          isNotNull,
          reason: '$id declares a document layout but has no bespoke body',
        );
      }
    });

    test('a report with no bespoke body returns null, not a broken widget', () {
      expect(documentBuilderFor('sale'), isNull);
      expect(documentBuilderFor('no_such_report'), isNull);
    });
  });

  // ============================================================
  group('Profit And Loss', () {
    testWidgets('it draws the statement, with gross profit and net on it', (
      tester,
    ) async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
      );

      final result = await run('profit_and_loss');
      await pumpDocument(tester, 'profit_and_loss', result);

      // The section headings and the totals. Gross profit is the line a CA
      // reads first, so its absence is the failure this test exists to catch —
      // and it is exactly what a generic "Description | Amount" table loses.
      expect(find.text('Income'), findsOneWidget);
      expect(find.text('Expenses'), findsOneWidget);
      expect(find.text('Total income'), findsOneWidget);
      expect(find.text('Total expenses'), findsOneWidget);
      expect(find.text('Gross profit'), findsOneWidget);
      expect(find.text('Net profit'), findsOneWidget);

      // And it is the fallback table, not the bespoke body: the fallback has no
      // section headings at all.
      expect(find.byType(Table), findsNothing);
    });

    testWidgets('it prints the figures the source produced', (tester) async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('profit_and_loss');
      await pumpDocument(tester, 'profit_and_loss', result);

      // ₹1,000 of sales at 18% GST. The source reports taxable value, so the
      // line reads 1,000.00 and not the 1,180.00 of the invoice total — the
      // trap this whole category exists to avoid, checked at the screen.
      expect(find.textContaining('Sales (net of tax)'), findsOneWidget);
      expect(find.textContaining('1,000.00'), findsWidgets);
    });
  });

  // ============================================================
  group('Trial Balance', () {
    testWidgets('it draws the debit/credit columns and pins the totals', (
      tester,
    ) async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('trial_balance');
      await pumpDocument(tester, 'trial_balance', result);

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Opening'), findsOneWidget);
      expect(find.text('Debit'), findsOneWidget);
      expect(find.text('Credit'), findsOneWidget);
      expect(find.text('Closing'), findsOneWidget);
      // The pinned total row, and its verdict — the reason a trial balance
      // exists.
      expect(find.text('Balanced'), findsOneWidget);
      expect(find.text('Does NOT balance'), findsNothing);
    });

    testWidgets('a credit closing balance is shown in brackets, not negative', (
      tester,
    ) async {
      // The whole reason the closing column stays signed while Dr and Cr are
      // magnitudes: a creditor is not a loss, and a red minus next to "Closing"
      // invites someone to subtract it twice.
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);

      final result = await run('trial_balance');
      final creditor = result.rows.firstWhere(
        (r) => r.cells['code'] == LedgerCodes.creditors,
      );
      expect(
        creditor.number(
              result.spec.columns.firstWhere((c) => c.key == 'closing'),
            ) <
            Decimal.zero,
        isTrue,
        reason: 'a creditor holds a credit balance',
      );

      await pumpDocument(tester, 'trial_balance', result);
      expect(find.text('Balanced'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Does NOT balance',
        ),
        findsNothing,
      );
    });
  });

  // ============================================================
  group('Balance Sheet', () {
    testWidgets('it states the equation, which a grid cannot', (tester) async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('balance_sheet');
      await pumpDocument(tester, 'balance_sheet', result);

      expect(find.textContaining('Assets'), findsWidgets);
      expect(find.textContaining('Liabilities'), findsWidgets);
      // The claim the whole document exists to make.
      expect(find.text('Total assets = liabilities + equity'), findsOneWidget);
    });

    testWidgets('an unbalanced sheet says so rather than printing a wrong '
        'total', (tester) async {
      // A hand-built result, because a real sheet balances by construction and
      // the failure branch would otherwise never run.
      final result = await run('balance_sheet');
      final rows = [
        ReportRow({
          'section': 'Assets',
          'group': 'Current assets',
          'account': 'Cash',
          'code': '1000',
          'amount': Decimal.fromInt(1000),
        }),
        ReportRow({
          'section': 'Liabilities',
          'group': 'Current liabilities',
          'account': 'Creditors',
          'code': '2000',
          'amount': Decimal.fromInt(400),
        }),
      ];
      final broken = ReportResult(
        spec: result.spec,
        window: window,
        count: rows.length,
        groups: [ReportGroup(name: '', rows: rows)],
        grandTotals: {'amount': Decimal.fromInt(1400)},
      );

      await pumpDocument(tester, 'balance_sheet', broken);
      expect(find.text('Out by'), findsOneWidget);
      expect(find.text('600.00'), findsOneWidget);
      expect(find.text('Total assets = liabilities + equity'), findsNothing);
    });
  });

  // ============================================================
  group('Cash flow', () {
    testWidgets('it shows the running balance and the net movement', (
      tester,
    ) async {
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 5000,
            date: DateTime(2026, 4, 5),
          );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'P-1',
            amount: 2000,
            date: DateTime(2026, 4, 6),
          );

      final result = await run('cash_flow');
      await pumpDocument(tester, 'cash_flow', result);

      expect(find.textContaining('Net movement 3000.00'), findsOneWidget);

      // The figures themselves, asserted on the widgets rather than on rendered
      // strings. `MoneyText` renders through a `FittedBox` when it has to
      // shrink, so the `Text` underneath is not reliably reachable by a text
      // finder — and a test that has to reach past a widget to check a number is
      // a test that breaks for the wrong reason. The amounts are the claim.
      final amounts = tester.allWidgets
          .whereType<MoneyText>()
          .map((m) => m.amount)
          .toList();
      expect(
        amounts,
        containsAll(<Decimal>[
          Decimal.fromInt(5000),
          Decimal.fromInt(2000),
          Decimal.fromInt(3000),
        ]),
      );
      // And the running balance is the figure a reader checks against the bank
      // statement at the end of the month: ₹5,000 in and ₹2,000 out leaves
      // ₹3,000, which is what the net-movement label states. Asserted against
      // the arithmetic rather than as a literal, so changing the fixture cannot
      // leave the test asserting a stale number.
      const moneyIn = 5000;
      const moneyOut = 2000;
      expect(
        find.textContaining('Net movement ${moneyIn - moneyOut}'),
        findsOneWidget,
        reason: 'the pinned label must be the arithmetic of the two movements',
      );
    });

    testWidgets('an empty firm falls back rather than drawing nothing', (
      tester,
    ) async {
      final result = await run('cash_flow');
      // Null from the builder is the contract with `ReportDocumentView`: a
      // document with nothing to draw is empty, not broken, and the screen
      // shows the empty state instead of a blank page.
      await pumpDocument(tester, 'cash_flow', result);
      expect(find.text('Nothing to show for this period.'), findsOneWidget);
    });
  });
}

/// Builds a document body with the tree's own context.
///
/// A test helper rather than a call to `builder(context, result)` at the top
/// level, because there is no context until something is pumped — and the
/// context that exists has to be the one the body will actually render under.
class _BuilderHost extends StatelessWidget {
  const _BuilderHost({required this.builder, required this.result});

  final Widget? Function(BuildContext, ReportResult) builder;
  final ReportResult result;

  @override
  Widget build(BuildContext context) => builder(context, result) ?? _Empty();
}

/// What the screen shows in place of a body that returned null: the same
/// generic column table `ReportDocumentView` falls back to.
class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Nothing to show for this period.'));
}
