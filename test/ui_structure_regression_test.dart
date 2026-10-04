import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/expenses/expenses_screen.dart';
import 'package:atria/features/reports/reports_screen.dart';
import 'package:atria/shared/widgets/atria_list_toolbar.dart';
import 'package:atria/shared/widgets/atria_nav_row.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Structure cover for the competitive revamp (see
/// `audit/04-competitive-ui-structure-revamp.md`):
///
/// * Reports leads with a **Report library** of labelled rows instead of two
///   icon-only app-bar actions that nothing pointed at.
/// * Expenses switched from the app bar's `TabBar` to the shared segmented
///   filter, so every list screen paints the same control in the same place.
///
/// Both screens are rendered for real here, so a layout overflow in either
/// one fails the test rather than only showing up in a golden's pixels.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<(AppDatabase, ProviderContainer)> boot() async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    return (db, container);
  }

  Future<void> teardown(
    WidgetTester tester,
    AppDatabase db,
    ProviderContainer container,
  ) async {
    // Unmount so drift's stream-teardown timers fire inside this test's fake
    // async; >=1s steps after dispose, or db.close() hangs (see STATE.md).
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }

  testWidgets('reports screen lists its destinations as labelled rows',
      (tester) async {
    final (db, container) = await boot();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ReportsScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Report library'), findsOneWidget);
    expect(find.byType(AtriaNavRow), findsNWidgets(3));
    expect(find.text('GST returns'), findsOneWidget);
    expect(find.text('Stock summary'), findsOneWidget);
    expect(find.text('Statement of account'), findsOneWidget);
    // The old icon-only entry points must be gone: a row carries its label.
    expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
    expect(find.byTooltip('GST returns (GSTR-1 / 3B / 2A)'), findsNothing);

    await teardown(tester, db, container);
  }, timeout: timeout);

  testWidgets('expenses screen drives its two modes from the shared filter',
      (tester) async {
    final (db, container) = await boot();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ExpensesScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // The mode switch is the shared adaptive filter: a labelled select on a
    // desktop-width surface, segmented pills on a phone — and either way it
    // sits in the page's filter row rather than in an app bar.
    expect(find.byType(AtriaAdaptiveFilter<int>), findsOneWidget);
    expect(find.byType(TabBar), findsNothing,
        reason: 'the app-bar tab strip was replaced by the shared filter');
    expect(find.text('Expenses'), findsWidgets);
    // The page's primary action is in its header now — there is no FAB.
    expect(
      find.widgetWithText(AtriaPrimaryAction, 'Add expense'),
      findsOneWidget,
    );

    // Switching modes still re-labels that action (and, through the editor
    // route, the document type it creates).
    await tester.tap(find.byType(AtriaFilterSelect<int>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Other income').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    expect(
      find.widgetWithText(AtriaPrimaryAction, 'Add income'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(AtriaPrimaryAction, 'Add expense'),
      findsNothing,
    );

    await teardown(tester, db, container);
  }, timeout: timeout);
}
