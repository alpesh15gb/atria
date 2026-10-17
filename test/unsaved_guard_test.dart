import 'dart:async';

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

  // ---------------------------------------------------------------------
  // The chrome bypass.
  //
  // `PopScope` is consulted by `Navigator.pop`/`maybePop` and nothing else.
  // Every piece of app chrome — the left rail, the mobile bottom bar, the More
  // sheet, the top-bar business switcher, global search — navigates with
  // `context.go`, which REPLACES the match list. The editor route is then
  // *disposed* rather than popped, so `onPopInvokedWithResult` never runs and a
  // typed invoice is destroyed with no prompt. The editors are child routes of
  // the very shell whose chrome is navigating, which is why the chrome can reach
  // them at all.
  //
  // These cover the registry that closes that hole.
  // ---------------------------------------------------------------------

  testWidgets('an armed guard registers itself with the chrome', (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    expect(UnsavedChanges.isArmed, isFalse);

    await _openGuarded(tester);
    expect(UnsavedChanges.isArmed, isTrue,
        reason: 'a rail click during this must ask, not silently discard');
  });

  testWidgets('closing the guard releases the registration', (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    await _openGuarded(tester);
    expect(UnsavedChanges.isArmed, isTrue);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(UnsavedChanges.isArmed, isFalse,
        reason: 'a guard for a closed editor must not block navigation elsewhere');
  });

  testWidgets('a clean editor never arms the chrome guard', (tester) async {
    await tester.pumpWidget(_app(dirty: false));
    await _openGuarded(tester);
    expect(UnsavedChanges.isArmed, isFalse);
  });

  testWidgets('confirmLeave lets a clean editor through without asking',
      (tester) async {
    await tester.pumpWidget(_app(dirty: false));
    await _openGuarded(tester);

    // What `goFromChrome` calls before every navigation. With nothing armed it
    // must not put a dialog in front of the user.
    final ctx = tester.element(find.text('guarded'));
    final ok = await UnsavedChanges.confirmLeave(ctx);
    expect(ok, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('confirmLeave puts the discard question in front of a dirty one',
      (tester) async {
    await tester.pumpWidget(_app(dirty: true));
    await _openGuarded(tester);

    final ctx = tester.element(find.text('guarded'));
    // Fire and forget: the dialog is what is under test, and it needs the tester
    // to keep pumping — awaiting the future here would deadlock in the
    // fake-async zone until the timeout.
    unawaited(UnsavedChanges.confirmLeave(ctx));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Leave without saving?'), findsOneWidget);

    // Declining leaves the document exactly where it was.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('guarded'), findsOneWidget);
    expect(UnsavedChanges.isArmed, isTrue);
  });
}