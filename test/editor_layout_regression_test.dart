import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/shared/widgets/atria_form_section.dart';
import 'package:atria/shared/widgets/atria_line_grid.dart';
import 'package:atria/shared/widgets/editor_totals.dart';
import 'package:atria/features/expenses/expense_editor_screen.dart';
import 'package:atria/features/items/item_editor_screen.dart';
import 'package:atria/features/parties/party_editor_screen.dart';
import 'package:atria/features/purchase/purchase_editor_screen.dart';
import 'package:atria/features/sales/sale_editor_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every form in the app is mounted for real, at a desktop width and at a
/// phone width.
///
/// The revamp moved all five editors onto one shared anatomy — a two-up
/// header band, an Excel-style line grid, the totals under the last line,
/// collapsible sections — so a layout overflow in any one of them has to fail
/// here rather than only show up when a user opens the form.
void main() {
  const timeout = Timeout(Duration(minutes: 3));

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

  Future<void> mount(
    WidgetTester tester,
    ProviderContainer container,
    Widget editor, {
    required Size size,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: AppTheme.light(), home: editor),
      ),
    );
    // Bounded pumps: the editors settle fast, but stay bounded so a hanging
    // animation cannot wedge the run.
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The forms, paired with what proves their body actually rendered.
  final editors = <String, (Widget Function(), Finder)>{
    'invoice': (
      () => const SaleEditorScreen(docType: 'invoice'),
      find.text('Add lines'),
    ),
    'quotation': (
      () => const SaleEditorScreen(docType: 'quotation'),
      find.text('Add lines'),
    ),
    'sales order': (
      () => const SaleEditorScreen(docType: 'sales_order'),
      find.text('Add lines'),
    ),
    'purchase bill': (
      () => const PurchaseEditorScreen(),
      find.text('Add lines'),
    ),
    'debit note': (
      () => const PurchaseEditorScreen(docType: 'debit_note'),
      find.text('Add lines'),
    ),
    'expense': (
      () => const ExpenseEditorScreen(),
      find.text('Expense details'),
    ),
    'income': (
      () => const ExpenseEditorScreen(type: 'income'),
      find.text('Income details'),
    ),
    'item': (() => const ItemEditorScreen(), find.text('Item details')),
    'party': (() => const PartyEditorScreen(), find.text('Basic details')),
  };

  for (final entry in editors.entries) {
    testWidgets('${entry.key} form lays out on desktop and on a phone', (
      tester,
    ) async {
      final (db, container) = await boot();

      // Collect every render error instead of the first one: a form that
      // overflows in two places should name both. The details carry the
      // offending widget and its constraint chain, which the bare FlutterError
      // does not.
      final failures = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = failures.add;

      for (final size in const [
        Size(1680, 950), // maximised desktop
        Size(1200, 900), // laptop
        Size(400, 900), // phone
      ]) {
        await mount(tester, container, entry.value.$1(), size: size);
        expect(
          entry.value.$2,
          findsWidgets,
          reason: '${entry.key} rendered no body at ${size.width}px',
        );
        // Every editor answers to the one action bar.
        expect(
          find.widgetWithText(FilledButton, 'Save and close'),
          findsOneWidget,
        );
      }

      // Restored inside the test body: the binding asserts at the end of the
      // test that nothing still owns its error handler.
      FlutterError.onError = previous;
      for (final failure in failures) {
        // ignore: avoid_print
        print('=== ${entry.key} ===\n$failure');
      }
      expect(
        failures,
        isEmpty,
        reason: '${entry.key} laid out badly at one of the two widths',
      );

      await teardown(tester, db, container);
    }, timeout: timeout);
  }

  // The revamp's second promise: a form spends the window it is given. A
  // centred column leaves a few hundred pixels of empty page on either side
  // of a maximised window, which reads as unfinished rather than as focus —
  // so the width is pinned here, not left to the eye.
  group('forms fill the page width', () {
    testWidgets('the invoice sheet starts at the page gutter', (tester) async {
      final (db, container) = await boot();
      const width = 1680.0;
      await mount(
        tester,
        container,
        const SaleEditorScreen(docType: 'invoice'),
        size: const Size(width, 900),
      );

      final sheet = tester.getRect(find.byType(AtriaLineGrid));
      // 32 is the widest page gutter; a 1680px window gets exactly that.
      expect(
        sheet.left,
        lessThanOrEqualTo(32),
        reason: 'the line sheet must start at the gutter, not 200px in',
      );
      expect(
        width - sheet.right,
        lessThanOrEqualTo(32),
        reason: 'and it must reach the opposite gutter',
      );
      expect(sheet.width, greaterThan(width * 0.9));

      // The totals keep the Tally convention: a right-aligned block under the
      // last line, not a strip stretched across the page.
      final totals = tester.getRect(find.byType(AtriaTotalsBlock));
      expect(totals.width, lessThanOrEqualTo(470));

      await teardown(tester, db, container);
    }, timeout: timeout);

    testWidgets('section cards pair up wide and stack on a phone', (
      tester,
    ) async {
      final (db, container) = await boot();

      await mount(
        tester,
        container,
        const PartyEditorScreen(),
        size: const Size(1680, 900),
      );
      // Tree order is column-major (both left-column sections, then both
      // right-column ones), so the second column has to be found by geometry.
      List<Rect> sectionRects() => [
        for (var i = 0; i < 4; i++)
          tester.getRect(find.byType(AtriaFormSection).at(i)),
      ];

      final wide = sectionRects();
      final first = wide.first;
      final beside = wide.where((r) => r.left > first.right - 1).toList();
      expect(beside, isNotEmpty, reason: 'two section columns, side by side');
      expect(
        beside.first.top,
        first.top,
        reason: 'the second column starts level with the first',
      );
      expect(
        wide.where((r) => r.left == first.left).length,
        2,
        reason: 'two sections per column',
      );

      await mount(
        tester,
        container,
        const PartyEditorScreen(),
        size: const Size(400, 900),
      );
      final narrow = sectionRects();
      expect(
        narrow.map((r) => r.left).toSet(),
        hasLength(1),
        reason: 'on a phone the sections are one column',
      );
      expect(
        narrow[1].top,
        greaterThan(narrow[0].bottom - 1),
        reason: 'and they stack',
      );
      expect(
        narrow.first.left,
        16,
        reason: 'a phone gutter is 16, not the desktop 24',
      );

      await teardown(tester, db, container);
    }, timeout: timeout);

    testWidgets('grid cells are bare in the sheet and boxed on a phone', (
      tester,
    ) async {
      final (db, container) = await boot();

      OutlineInputBorder cellBorder() {
        final field = tester.widget<TextField>(
          find
              .descendant(
                of: find.byType(AtriaGridInput),
                matching: find.byType(TextField),
              )
              .first,
        );
        return field.decoration!.enabledBorder! as OutlineInputBorder;
      }

      await mount(
        tester,
        container,
        const SaleEditorScreen(docType: 'invoice'),
        size: const Size(1680, 900),
      );
      expect(
        cellBorder().borderSide.color.a,
        0,
        reason: 'in the sheet a cell is borderless until focus',
      );

      await mount(
        tester,
        container,
        const SaleEditorScreen(docType: 'invoice'),
        size: const Size(400, 900),
      );
      expect(
        cellBorder().borderSide.color.a,
        greaterThan(0),
        reason: 'in the stacked card a cell must look like a field',
      );

      await teardown(tester, db, container);
    }, timeout: timeout);
  });
}
