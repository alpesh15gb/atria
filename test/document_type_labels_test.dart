import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/purchase/purchase_list_screen.dart';
import 'package:atria/features/sales/sales_list_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every document type has its OWN name, everywhere the user is offered to
/// create one.
///
/// This had no coverage at all, which is how it stays broken: a hardcoded
/// "New Invoice" on the Quotations screen is exactly the sort of thing that
/// survives a refactor, because a list screen still *works* â€” it just lies
/// about what it is about to create. The rail sends you to
/// `/sales?type=quotation`, the screen reads that query, and every label on
/// the page has to follow it.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
  });

  tearDown(() async {
    // Container first, then the database, both outside `FakeAsync`. Doing either
    // inside the test body trips the other: disposing the container while
    // `ActiveFirmController` still has futures in flight throws "Tried to use
    // ActiveFirmController after `dispose` was called", and closing the database
    // first leaves that same controller reaching for a closed connection ("Can't
    // re-open a database after closing it").
    container.dispose();
    await db.close();
  });

  Future<void> pumpSales(WidgetTester tester, String? docType) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(body: SalesListScreen(initialType: docType)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> pumpPurchase(WidgetTester tester, String docType) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light().copyWith(platform: TargetPlatform.windows),
          home: Scaffold(body: PurchaseListScreen(initialType: docType)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Unmount, dispose the container, then advance fake time — the order
  /// `list_ux_regression_test.dart` established.
  ///
  /// This has to run inside the test body, not in `tearDown`: once the body
  /// returns `FakeAsync` is gone, and drift's zero-duration `markAsClosed`
  /// timers — created as the watches unsubscribe — can never fire. Every case
  /// then ends on "A Timer is still pending even after the widget tree was
  /// disposed", a teardown artefact with nothing to do with the labels that
  /// still fails the test. Which is how this file sat red and therefore
  /// protected nothing. `doc_type_route_sync_test.dart` covers the half that
  /// actually catches the bug: the route, not just the first build.
  /// Unmount the tree, then let drift's zero-duration `markAsClosed` timers
  /// fire.
  ///
  /// It has to happen inside the test body: once the body returns, `FakeAsync`
  /// is gone and those timers can never run, so every case ends on "A Timer is
  /// still pending even after the widget tree was disposed" — a teardown
  /// artefact with nothing to do with the labels that still fails the test.
  /// Which is how this file sat red and therefore protected nothing.
  /// `doc_type_route_sync_test.dart` covers the half that actually catches the
  /// bug: the route, not just the first build.
  Future<void> unmount(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  // The point of the bug: on the wrong type the screen said "New invoice" for
  // every one of these.
  const salesCases = <String, String>{
    'invoice': 'New invoice',
    'quotation': 'New quotation',
    'sales_order': 'New sales order',
    'delivery_note': 'New delivery note',
    'credit_note': 'New credit note',
  };

  const salesTitles = <String, String>{
    'invoice': 'Invoices',
    'quotation': 'Quotations',
    'sales_order': 'Sales orders',
    'delivery_note': 'Delivery notes',
    'credit_note': 'Credit notes',
  };

  salesCases.forEach((docType, label) {
    testWidgets('the $docType screen offers "$label"', (tester) async {
      await pumpSales(tester, docType);
      // `findsWidgets`, not `findsOneWidget`: an empty list offers the same
      // action twice (page header and empty state), and both must name the
      // type. What matters is that they never name a DIFFERENT type.
      expect(
        find.text(label),
        findsWidgets,
        reason: 'the $docType screen must offer "$label", not a generic one',
      );
      // And it must not be showing another type's name.
      for (final other in salesCases.entries) {
        if (other.key == docType) continue;
        expect(
          find.text(other.value),
          findsNothing,
          reason: 'the $docType screen must not offer "${other.value}"',
        );
      }
      await unmount(tester);
    });

    testWidgets('the $docType screen is titled "${salesTitles[docType]}"',
        (tester) async {
      await pumpSales(tester, docType);
      expect(find.text(salesTitles[docType]!), findsWidgets);
      await unmount(tester);
    });
  });

  testWidgets('an unknown or missing type falls back to invoice, not a blank',
      (tester) async {
    await pumpSales(tester, null);
    // `findsWidgets`, not `findsOneWidget`, for the reason given above: an
    // empty list offers the same action twice. Both copies have to name the
    // invoice, and nothing on the page may name another type.
    expect(find.text('New invoice'), findsWidgets);
    expect(find.text('New quotation'), findsNothing);
    expect(find.text('New credit note'), findsNothing);
    await unmount(tester);
  });

  const purchaseCases = <String, String>{
    'bill': 'Add bill',
    'purchase_order': 'New purchase order',
    'debit_note': 'New debit note',
  };

  purchaseCases.forEach((docType, label) {
    testWidgets('the $docType screen offers "$label"', (tester) async {
      await pumpPurchase(tester, docType);
      expect(
        find.text(label),
        findsWidgets,
        reason: 'the $docType screen must offer "$label"',
      );
      for (final other in purchaseCases.entries) {
        if (other.key == docType) continue;
        expect(
          find.text(other.value),
          findsNothing,
          reason: 'the $docType screen must not offer "${other.value}"',
        );
      }
      await unmount(tester);
    });
  });

  testWidgets('scan-bill only appears on bills', (tester) async {
    await pumpPurchase(tester, 'bill');
    expect(find.text('Scan bill'), findsOneWidget);

    await pumpPurchase(tester, 'debit_note');
    // A return is not photographed, so the button is hidden on it.
    expect(find.text('Scan bill'), findsNothing);
    await unmount(tester);
  });
}
