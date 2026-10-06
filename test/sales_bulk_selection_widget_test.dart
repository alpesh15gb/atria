import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:atria/shared/widgets/selection_bar.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sales list's bulk-selection wiring.
///
/// The selection rules themselves are unit-tested in `bulk_actions_test.dart`;
/// what cannot be checked there is the wiring — that a tick in the list reaches
/// the bar, that the bar only appears once something is ticked, that "select
/// all" clears rather than grows, and above all that a row which disappears
/// from the list takes its tick with it. That last one is the failure that
/// happens in use rather than in review: tick two invoices, delete one from
/// its own detail screen, come back, and the stale id silently joins the next
/// bulk delete.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late ProviderContainer container;
  late String firmId;

  /// A named row's tick target.
  ///
  /// Keyed by document id rather than by index into `find.byType(Checkbox)`:
  /// the selection bar carries a checkbox of its own that appears and
  /// disappears as the selection changes, so any index shifts underneath the
  /// test. An earlier version of this file indexed by position and silently
  /// ticked the *same* row twice — it passed against broken code, which is
  /// what prompted the key.
  Finder rowTick(String id) => find.byKey(ValueKey('select-$id'));

  /// The select-all control inside the bar.
  final selectAll = find.descendant(
    of: find.byType(SelectionBar),
    matching: find.byType(Checkbox),
  );

  /// The bar's count text.
  ///
  /// Scoped to the bar on purpose: `AtriaResultsBar` renders "2 invoices" for
  /// the same two rows, so an unscoped `find.text` matches the *row count* and
  /// proves nothing about the selection.
  final selectedCount = find.descendant(
    of: find.byType(SelectionBar),
    matching: find.textContaining('invoice'),
  );

  Future<void> seed(String id, String number, {int amount = 1000}) => db
      .salesRepositoryFor(firmId)
      .save(
        SalesDraft(
          id: id,
          number: number,
          docType: 'invoice',
          invoiceDate: DateTime.now(),
          lines: [
            SalesLineDraft(
              id: 'l-$id',
              name: 'Consulting',
              quantity: Decimal.fromInt(1),
              unit: 'svc',
              rate: Decimal.fromInt(amount),
              gstRate: 18,
            ),
          ],
          partyName: 'Keystone Infra Pvt Ltd',
        ),
      );

  /// Built inside each test body, never in `setUp`.
  ///
  /// `setUp` runs outside the testWidget's fake-async zone, so a drift
  /// database opened there never completes its writes under the fake clock
  /// and the first `save` hangs until the timeout. `bulk_sales_actions_test.dart`
  /// gets away with `setUp` because its tests are plain `test()`, which have
  /// no fake clock; `list_ux_regression_test.dart` boots in the body for the
  /// same reason. Symptom when this is wrong: the test hangs on its first
  /// repository write, with no exception.
  Future<void> boot() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    firmId = firm.id;
  }

  // Unmount → dispose → pump → close, in that order, and **inside the test
  // body**. `tearDown` is handed no `WidgetTester` and `addTearDown`'s callback
  // runs outside the test's fake-async zone, so neither can pump — and the
  // pumps are not cosmetic: `db.close()` awaits a future drift's watch stream
  // completes on that queue, and with nothing pumped it never drains, so
  // `close` blocks until the test times out.
  //
  // The pumps must come *after* `container.dispose()`: the stream's teardown
  // timer only starts when the subscription is cancelled.
  Future<void> closeDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }

  Future<void> selectRow(WidgetTester tester, String id) async {
    if (rowTick(id).evaluate().isNotEmpty) {
      await tester.tap(rowTick(id));
    } else {
      final doc = await tester.runAsync(() => db.salesRepositoryFor(firmId).getById(id));
      await tester.longPress(find.text(doc!.number));
    }
  }

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: SalesListScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
  }

  testWidgets('the bar is absent until something is ticked', (tester) async {
    await boot();
    await seed('inv-a', 'INV-001');
    await seed('inv-b', 'INV-002');
    await pumpList(tester);

    expect(
      find.byType(SelectionBar),
      findsNothing,
      reason:
          'an always-present bar advertising three greyed-out buttons is '
          'noise on a screen where nothing is selected',
    );
    await closeDown(tester);
  }, timeout: timeout);

  testWidgets('ticking a row shows the bar and its count', (tester) async {
    await boot();
    await seed('inv-a', 'INV-001');
    await seed('inv-b', 'INV-002');
    await pumpList(tester);

    expect(find.text('INV-001'), findsOneWidget);
    expect(find.text('INV-002'), findsOneWidget);
    expect(rowTick('inv-a'), findsNothing, reason: 'mobile reveals tick controls only after long press');

    await selectRow(tester, 'inv-a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SelectionBar), findsOneWidget);
    expect(selectedCount, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('1 invoice'),
      ),
      findsOneWidget,
    );

    await selectRow(tester, 'inv-b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('2 invoices'),
      ),
      findsOneWidget,
    );
    await closeDown(tester);
  }, timeout: timeout);

  testWidgets('select all ticks everything, then unticks', (tester) async {
    await boot();
    await seed('inv-a', 'INV-001');
    await seed('inv-b', 'INV-002');
    await seed('inv-c', 'INV-003');
    await pumpList(tester);

    // One tick first, so the bar exists and offers select-all at all — the bar
    // is hidden while the selection is empty, and that is deliberate.
    await selectRow(tester, 'inv-a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('1 invoice'),
      ),
      findsOneWidget,
    );

    await tester.tap(selectAll);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('3 invoices'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('all 3 loaded'),
      findsOneWidget,
      reason: 'the bar must say the claim is about a bounded set',
    );

    await tester.tap(selectAll);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byType(SelectionBar),
      findsNothing,
      reason:
          'selecting all and pressing it again is how a file manager '
          'behaves: the same control clears',
    );
    await closeDown(tester);
  }, timeout: timeout);

  testWidgets('a row deleted elsewhere loses its tick', (tester) async {
    await boot();
    await seed('inv-a', 'INV-001');
    await seed('inv-b', 'INV-002');
    await pumpList(tester);

    await selectRow(tester, 'inv-a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await selectRow(tester, 'inv-b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('2 invoices'),
      ),
      findsOneWidget,
    );

    // Deleted from outside the list — through the repository here, standing in
    // for the detail screen's own delete.
    await db.salesRepositoryFor(firmId).softDelete('inv-b');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('2 invoices'),
      ),
      findsNothing,
      reason:
          'the hidden id must be dropped, not carried into the next '
          'bulk action',
    );
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('1 invoice'),
      ),
      findsOneWidget,
    );
    await closeDown(tester);
  }, timeout: timeout);

  testWidgets('narrowing the search drops ticks the operator cannot see', (
    tester,
  ) async {
    await boot();
    await seed('inv-a', 'INV-001');
    await seed('inv-b', 'INV-002');
    await pumpList(tester);

    await selectRow(tester, 'inv-a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(SelectionBar),
        matching: find.text('1 invoice'),
      ),
      findsOneWidget,
    );

    // Search for something that matches nothing: the ticked row leaves the
    // list, and its tick has to leave with it.
    await tester.enterText(find.byType(TextField).first, 'zzzz');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(
      find.byType(SelectionBar),
      findsNothing,
      reason:
          'a tick the operator cannot see silently joining the next bulk '
          'action is how two invoices get deleted when one was ticked',
    );
    await closeDown(tester);
  }, timeout: timeout);
}
