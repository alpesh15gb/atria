import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:atria/shared/widgets/period_selector.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The list screens' Date filter gained a **Custom** window: the user picks a
/// From and a To day instead of settling for This Month / This FY / All Time.
///
/// Two things have to stay true for that to be honest rather than decorative:
/// the window must cover whole days (an invoice dated *on* the To day counts),
/// and it must be closed at the top — otherwise "1 Apr – 30 Apr" quietly lists
/// May as well, which is the sort of thing nobody notices until a GST figure
/// is wrong.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  group('PeriodRange', () {
    test('named windows stay open-ended so later-dated records survive', () {
      final now = DateTime.now();
      final month = PeriodRange(period: Period.thisMonth);
      expect(month.from, DateTime(now.year, now.month, 1));
      expect(month.to, isNull,
          reason: 'This Month must not cut off a document dated later today');
      expect(month.label, 'This Month');

      final fy = PeriodRange(period: Period.thisFY);
      expect(
        fy.from,
        now.month >= 4
            ? DateTime(now.year, 4, 1)
            : DateTime(now.year - 1, 4, 1),
      );
      expect(fy.to, isNull);

      final all = PeriodRange(period: Period.allTime);
      expect(all.from, isNull);
      expect(all.to, isNull);
      expect(all.isAllTime, isTrue);
    });

    test('a custom window covers whole days, in the order they were picked',
        () {
      final range = PeriodRange(
        period: Period.custom,
        customFrom: DateTime(2026, 4, 15),
        customTo: DateTime(2026, 4, 2),
      );

      expect(range.from, DateTime(2026, 4, 2));
      expect(range.to, DateTime(2026, 4, 15, 23, 59, 59),
          reason: 'the To day itself has to be inside the window');
      expect(range.label, contains('2026'));
      expect(range.emptyWindowMessage('invoices'), contains('between'));
    });

    test('picking one day keeps the other and stays on Custom', () {
      final range = PeriodRange(
        period: Period.custom,
        customFrom: DateTime(2026, 4, 1),
        customTo: DateTime(2026, 4, 30),
      );

      final next = range.withCustomDay(to: DateTime(2026, 5, 5));
      expect(next.period, Period.custom);
      expect(next.customFrom, DateTime(2026, 4, 1));
      expect(next.customTo, DateTime(2026, 5, 5));
      expect(next, isNot(range));
    });

    test('switching period keeps the picked days and the query key moves', () {
      final range = PeriodRange(
        period: Period.custom,
        customFrom: DateTime(2026, 4, 1),
        customTo: DateTime(2026, 4, 30),
      );

      expect(range.withPeriod(Period.allTime).customFrom, range.customFrom);
      expect(range.withPeriod(Period.allTime).to, isNull);
      expect(range.withPeriod(Period.thisMonth).cacheKey,
          isNot(range.cacheKey));
    });

    test('the Date filter offers the Custom option', () {
      expect(
        periodSegments().map((segment) => segment.value),
        contains(Period.custom),
      );
    });
  });

  group('custom range on the Sales list', () {
    Future<(AppDatabase, ProviderContainer, String)> boot() async {
      final db = AppDatabase.test(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      final firm = await db.firmRepository.create(name: 'Apex Integrations');
      await container.read(activeFirmIdProvider.notifier).select(firm.id);
      return (db, container, firm.id);
    }

    Future<void> teardown(
      WidgetTester tester,
      AppDatabase db,
      ProviderContainer container,
    ) async {
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

    Future<void> seed(
      SalesRepository repo,
      String number,
      DateTime date, {
      String party = 'Keystone Infra',
    }) {
      return repo.save(
        SalesDraft(
          id: 'sale-$number',
          number: number,
          docType: 'invoice',
          invoiceDate: date,
          partyName: party,
          lines: [
            SalesLineDraft(
              id: 'line-$number',
              name: 'Consulting',
              quantity: Decimal.fromInt(1),
              unit: 'svc',
              rate: Decimal.fromInt(1000),
              gstRate: 18,
            ),
          ],
        ),
      );
    }

    Future<void> pumpSales(WidgetTester tester, ProviderContainer container) {
      return tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SalesListScreen()),
          ),
        ),
      );
    }

    testWidgets('a custom window is closed at the top of the range',
        (tester) async {
      final (db, container, firmId) = await boot();
      final now = DateTime.now();
      final repo = db.salesRepositoryFor(firmId);

      await seed(repo, 'INV-TODAY', now);
      // A document dated after today: the only thing that keeps it out of the
      // list is the window's upper bound.
      await seed(repo, 'INV-LATER', now.add(const Duration(days: 45)));

      // The lower bound alone would return both rows — so the screen is the
      // only thing that can be hiding INV-LATER.
      final fromOnly = await repo.list(
        from: DateTime(now.year, now.month, 1),
      );
      expect(fromOnly.map((e) => e.number), containsAll(['INV-TODAY', 'INV-LATER']));

      await pumpSales(tester, container);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('INV-TODAY'), findsWidgets);

      // Pick the Custom window from the Date filter.
      await tester.tap(find.text('This Month'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.text('From'), findsOneWidget,
          reason: 'a custom window has to offer the two days it spans');
      expect(find.text('To'), findsOneWidget);
      expect(find.text('INV-TODAY'), findsWidgets);
      expect(find.text('INV-LATER'), findsNothing,
          reason: 'the custom window must end at its To day, not stay open');

      await teardown(tester, db, container);
    }, timeout: timeout);

    testWidgets('the phone layout offers Custom beside the pills it replaces',
        (tester) async {
      final (db, container, firmId) = await boot();
      await seed(db.salesRepositoryFor(firmId), 'INV-001', DateTime.now());

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpSales(tester, container);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Mobile uses one compact Date select rather than all period pills.
      await tester.tap(find.byTooltip('Date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.takeException(), isNull);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('To'), findsOneWidget);

      await teardown(tester, db, container);
    }, timeout: timeout);
  });
}
