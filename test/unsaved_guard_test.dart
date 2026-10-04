import 'package:atria/shared/widgets/unsaved_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A route guarded by [UnsavedGuard], with a back button that goes through
/// `Navigator.maybePop` exactly as the Android system back does.
class _GuardedPage extends StatefulWidget {
  const _GuardedPage({required this.dirty});

  final bool dirty;

  @override
  State<_GuardedPage> createState() => _GuardedPageState();
}

class _GuardedPageState extends State<_GuardedPage> {
  @override
  Widget build(BuildContext context) {
    return UnsavedGuard(
      hasChanges: widget.dirty,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
        body: const Center(child: Text('guarded')),
      ),
    );
  }
}

Widget _app({required bool dirty}) {
  return MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _GuardedPage(dirty: dirty),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openGuarded(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.text('guarded'), findsOneWidget);
}

void main() {
  testWidgets('back with unsaved changes asks first', (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    await _openGuarded(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    // Still on the form, with the question in front of the person.
    expect(find.text('guarded'), findsOneWidget);
    expect(find.text('You have unsaved changes. Discard them?'), findsOneWidget);
  });

  testWidgets('Keep editing stays on the form', (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    await _openGuarded(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();

    expect(find.text('guarded'), findsOneWidget);
    expect(
      find.text('You have unsaved changes. Discard them?'),
      findsNothing,
    );
  });

  testWidgets(
    'Discard ACTUALLY leaves — it does not re-open the dialog for ever',
    (tester) async {
      await tester.pumpWidget(_app(dirty: true));
      await _openGuarded(tester);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      // The regression: `canPop` is false while the dialog is up, so the pop
      // the confirm performs is vetoed by the very guard that asked the
      // question and the callback fires again with didPop == false. Before the
      // fix the person was trapped on the editor, watching the same dialog
      // reappear on every tap.
      expect(find.text('guarded'), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(find.text('Discard'), findsNothing);
    },
  );

  testWidgets('back with no unsaved changes leaves immediately', (tester) async {
    await tester.pumpWidget(_app(dirty: false));
    await _openGuarded(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.text('guarded'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('the discard notice is shown once, after leaving', (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    await _openGuarded(tester);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(find.text('Changes discarded'), findsOneWidget);
  });
}