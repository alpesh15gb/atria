import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/payment_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/pos/pos_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The till must bill the goods exactly once, whatever goes wrong after the
/// invoice is written.

/// The counter screen settles the sale in the same motion as it bills it, so a
/// fault in the payment path is the common case — the card machine is down, the
/// ledger is locked, the drawer jams. The old handler caught everything in one
/// net, reported "Could not complete the sale", and left the cart full. The
/// operator sees a failed sale and a full cart, presses Complete, and bills the
/// same goods a second time.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Apex Traders')).id;
  });

  tearDown(() => db.close());

  Future<void> pumpPos(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: const PosScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Scans a code the way a wedge scanner does: it types and presses enter.
  Future<void> scan(WidgetTester tester, String code) async {
    await tester.enterText(find.byType(TextField).first, code);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Tears the container down the way a screen holding a drift watch needs: the
  /// existence watch [ActiveFirmController.select] installs keeps stream
  /// teardown timers pending, and they only fire when the fake clock is
  /// pumped. See [stock_screen_regression_test] for the same workaround.
  Future<void> disposeWithMountedDrift(
    WidgetTester tester,
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
  }

  testWidgets(
    'a settlement failure after the save bills the cart once',
    timeout: timeout,
    (tester) async {
      await db
          .itemRepositoryFor(firmId)
          .create(
            name: 'Steel Rod 12mm',
            sku: 'ROD-12',
            salePrice: 250,
            gstRate: 18,
            openingStock: 20,
          );

      // The payment path fails after the invoice is committed: the card machine
      // is offline, or the period is locked, or the cheque register is full.
      // This is the state the old handler turned into a second bill.
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          paymentRepositoryProvider.overrideWithValue(
            _FailingPayments(db, firmId),
          ),
        ],
      );
      await container.read(activeFirmIdProvider.notifier).select(firmId);

      tester.view.physicalSize = const Size(1300, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpPos(tester, container);
      await scan(tester, 'ROD-12');

      expect(find.text('Steel Rod 12mm'), findsWidgets);
      expect(find.text('Complete sale'), findsOneWidget);

      await tester.tap(find.text('Complete sale'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      // The invoice exists — the sale was made, and it cannot be unmade.
      final sales = db.salesRepositoryFor(firmId);
      final invoices = await sales.list();
      expect(invoices, hasLength(1));
      expect(invoices.single.docType, 'invoice');
      expect(invoices.single.grandTotal, closeTo(295, 0.01));

      // The payment was refused, and the operator is told the bill *was* saved
      // rather than that it failed.
      expect(
        find.textContaining('the payment was not recorded'),
        findsOneWidget,
        reason:
            'a post-save fault must be reported as a saved bill with a '
            'follow-up problem, not as a sale that never happened',
      );

      // The cart is empty: the goods are no longer the operator's to sell again
      // from here. This is the fix — under the old handler the lines survived,
      // so Complete was a second, working bill for the same items.
      expect(find.text('Steel Rod 12mm'), findsNothing);
      final complete = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(
        complete.onPressed,
        isNull,
        reason: 'an empty cart cannot be completed again',
      );

      // Proving it the hard way: pressing Complete on the cleared cart writes
      // nothing further.
      await tester.tap(find.text('Complete sale'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        await sales.list(),
        hasLength(1),
        reason: 'the same cart cannot be billed twice',
      );

      await disposeWithMountedDrift(tester, container);
    },
  );

  testWidgets('a save failure keeps the cart for a retry', timeout: timeout, (
    tester,
  ) async {
    await db
        .itemRepositoryFor(firmId)
        .create(
          name: 'Steel Rod 12mm',
          sku: 'ROD-12',
          salePrice: 250,
          gstRate: 18,
          openingStock: 20,
        );

    // The failure is now *before* the commit, which is the one case where the
    // cart should survive: nothing was written, so there is nothing to undo.
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        salesRepositoryProvider.overrideWithValue(_FailingSales(db, firmId)),
      ],
    );
    await container.read(activeFirmIdProvider.notifier).select(firmId);

    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPos(tester, container);
    await scan(tester, 'ROD-12');

    await tester.tap(find.text('Complete sale'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Nothing was billed, and the operator is told the sale failed.
    expect(await db.salesRepositoryFor(firmId).list(), isEmpty);
    expect(find.textContaining('Could not complete the sale'), findsOneWidget);

    // But the cart is intact, so the retry is the same cart, not a retyped one.
    expect(find.text('Steel Rod 12mm'), findsWidgets);
    final complete = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(
      complete.onPressed,
      isNotNull,
      reason: 'a failed save leaves the sale retryable',
    );

    await disposeWithMountedDrift(tester, container);
  });
}

/// A till whose payment path is broken, to stand in for a card machine that
/// never answers.
class _FailingPayments extends PaymentRepository {
  _FailingPayments(super.db, super.firmId);

  @override
  Future<PaymentEntity> create({
    required String type,
    required String number,
    String? partyId,
    String? partyName,
    required double amount,
    required DateTime date,
    String mode = 'cash',
    String? reference,
    DateTime? clearanceDate,
    String? linkedInvoiceId,
    String? linkedInvoiceNumber,
    String? bankAccount,
    String? notes,
    int sequence = 0,
    Future<void> Function(String linkedId, double amount)? onLinked,
  }) async {
    throw StateError('the card machine is offline');
  }
}

/// A till whose ledger is read-only, to stand in for a save that never lands.
class _FailingSales extends SalesRepository {
  _FailingSales(super.db, super.firmId);

  @override
  Future<SalesInvoiceEntity> save(
    SalesDraft draft, {
    bool affectStock = true,
    String? createdBy,
  }) async {
    throw StateError('the books are locked');
  }
}
