import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/features/ledger/journal_editor_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A journal voucher has to read an amount the way an accountant writes one.

/// Indian grouping is the convention here — a bookkeeper types "1,00,000", not
/// "100000". The line fields used to go through `double.tryParse`, which
/// returns null for the comma and fell back to 0, so a voucher saved with its
/// amount silently dropped: the ledger got a zero-value posting, the balance
/// sheet stopped agreeing, and nothing on screen said why.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Inter-Italic[opsz,wght].ttf'));
    await loader.load();
  }

  Future<(AppDatabase, ProviderContainer)> boot() async {
    await loadAppFont();
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Traders');
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(firm.id);
    // The chart has to exist before the editor's dropdowns can offer accounts.
    await container.read(ledgerRepositoryProvider)!.ensureChart();
    return (db, container);
  }

  Future<void> dispose(
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

  testWidgets('a journal line reads an Indian-grouped amount',
      timeout: timeout, (tester) async {
    final (db, container) = await boot();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const JournalEditorScreen(),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The editor shows a spinner until the chart resolves, and the line fields
    // are not there to type into before that.
    for (var i = 0; i < 20 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // The first line's debit field — found by its label, not its index, since
    // the number of TextFields above it changes with the editor's width.
    final debitField = find
        .byWidgetPredicate(
          (widget) => widget is TextField && widget.decoration?.labelText == 'Debit',
        )
        .first;
    expect(find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.labelText == 'Debit'),
        findsNWidgets(2));
    await tester.showKeyboard(debitField);
    await tester.enterText(debitField, '1,00,000');
    await tester.pump();

    // The totals card sits below the fold of the editor's own ListView, so it
    // is not built until it is scrolled to.
    for (var i = 0; i < 10 && find.text('Total debit').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
      await tester.pump();
    }
    await tester.pump();

    // "Total debit" is what the editor itself derives from the parsed field, so
    // it is the honest check: with `double.tryParse` this read 0.00 and the
    // voucher could not be balanced at all. `_TotalRow` puts the figure in the
    // row's second slot; the label is the first, so `.last` is the value.
    final total = tester.widgetList<Text>(find.descendant(
      of: find.ancestor(
        of: find.text('Total debit'),
        matching: find.byType(Row),
      ),
      matching: find.byType(Text),
    )).last;
    expect(total.data, contains('1,00,000'),
        reason: 'a grouped amount parsed as 0 — the voucher would save with '
            'no amount');

    final error = tester.takeException();
    await dispose(tester, db, container);
    expect(error, isNull);
  });
}
