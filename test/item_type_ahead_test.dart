import 'package:atria/shared/widgets/item_type_ahead.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the Vyapar-style type-ahead item picker on invoice lines:
/// typing filters the catalogue, and committing an unknown name fires
/// [ItemTypeAheadField.onCreateItem] exactly once — the silent
/// "new names are saved automatically" contract (no dialog, no second step).
void main() {
  const items = [
    ItemSuggestion(name: 'Annual Maintenance Contract', salePrice: 1129),
    ItemSuggestion(name: 'Steel Rod 12mm', salePrice: 250, unit: 'kg'),
  ];

  Widget host({
    required TextEditingController controller,
    required ValueChanged<ItemSuggestion> onPick,
    required ValueChanged<String> onCreate,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ItemTypeAheadField(
          controller: controller,
          items: items,
          onPickItem: onPick,
          onCreateItem: onCreate,
        ),
      ),
    );
  }

  testWidgets('typing filters the catalogue', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(host(
      controller: controller,
      onPick: (_) {},
      onCreate: (_) {},
    ));

    await tester.enterText(find.byType(TextField), 'steel');
    await tester.pump();

    expect(find.text('Steel Rod 12mm'), findsOneWidget);
    expect(find.text('Annual Maintenance Contract'), findsNothing);
  });

  testWidgets('picking a suggestion reports it via onPickItem', (tester) async {
    final controller = TextEditingController();
    ItemSuggestion? picked;
    await tester.pumpWidget(host(
      controller: controller,
      onPick: (s) => picked = s,
      onCreate: (_) {},
    ));

    await tester.enterText(find.byType(TextField), 'annual');
    await tester.pump();
    await tester.tap(find.text('Annual Maintenance Contract'));
    await tester.pump();

    expect(picked?.name, 'Annual Maintenance Contract');
  });

  testWidgets('committing an unknown name fires onCreateItem exactly once',
      (tester) async {
    final controller = TextEditingController();
    final created = <String>[];
    await tester.pumpWidget(host(
      controller: controller,
      onPick: (_) {},
      onCreate: created.add,
    ));

    await tester.enterText(find.byType(TextField), 'kkskks');
    await tester.pump();
    // The leading "Save item" row is the create affordance.
    await tester.tap(find.text('Save item'));
    await tester.pump();

    expect(created, ['kkskks']);
  });

  testWidgets('Enter on an unknown name also creates the item', (tester) async {
    final controller = TextEditingController();
    final created = <String>[];
    await tester.pumpWidget(host(
      controller: controller,
      onPick: (_) {},
      onCreate: created.add,
    ));

    await tester.enterText(find.byType(TextField), 'Brand New Widget');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(created, ['Brand New Widget']);
  });

  testWidgets('a name that already exists does NOT fire onCreateItem',
      (tester) async {
    final controller = TextEditingController();
    final created = <String>[];
    await tester.pumpWidget(host(
      controller: controller,
      onPick: (_) {},
      onCreate: created.add,
    ));

    await tester.enterText(find.byType(TextField), 'Steel Rod 12mm');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(created, isEmpty);
  });
}
