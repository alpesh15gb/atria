import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/features/sales/sale_editor_screen.dart';
import 'package:atria/shared/widgets/editor_shell.dart';
import 'package:atria/shared/widgets/editor_totals.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Smoke cover for the shared editor chrome: the sale editor must mount the
/// [EditorShell] action bar (exit / Save & New / Save), the form column with
/// its dashed add-item strip, and the sticky totals panel with the
/// "Mark as fully paid" settlement toggle — the pieces the Vyapar-style
/// editor revamp introduced.
void main() {
  testWidgets('sale editor renders the shell, form and totals panel',
      (tester) async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SaleEditorScreen(docType: 'invoice')),
      ),
    );
    // Bounded pumps: the editor settles fast (no shimmer), but stay bounded.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }

    // Action bar: exit affordance, Save & New (new documents), Save.
    expect(find.byTooltip('Exit'), findsOneWidget);
    expect(find.text('Save & New'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);

    // Form: dashed add-item strip and the collapsed link sections.
    expect(find.text('Add item'), findsOneWidget);
    expect(find.text('Add Notes'), findsOneWidget);
    expect(find.text('Add Discount & Charges'), findsOneWidget);

    // Sticky summary: breakdown + total + one-tap settlement.
    expect(find.text('Total Amount'), findsOneWidget);
    expect(find.text('Mark as fully paid'), findsOneWidget);

    // Unmount before disposing so stream teardown fires inside the test.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
    container.dispose();
    await db.close();
  });

  testWidgets('EditorLinkSection expands to reveal its editor on tap',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorLinkSection(
            icon: Icons.note_add_rounded,
            title: 'Add Notes',
            builder: (_) => const TextField(
              decoration: InputDecoration(labelText: 'Notes field'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // AnimatedCrossFade keeps the hidden child mounted offstage, so assert
    // on the cross-fade state itself — the thing the section controls.
    CrossFadeState linkState() => tester
        .widget<AnimatedCrossFade>(find.byType(AnimatedCrossFade))
        .crossFadeState;

    expect(linkState(), CrossFadeState.showSecond);
    await tester.tap(find.text('Add Notes'));
    await tester.pumpAndSettle();
    expect(linkState(), CrossFadeState.showFirst);
    expect(find.text('Notes field'), findsOneWidget);

    await tester.tap(find.text('Add Notes'));
    await tester.pumpAndSettle();
    expect(linkState(), CrossFadeState.showSecond);
  });
}
