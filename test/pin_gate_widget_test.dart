import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/domain/member_role.dart';
import 'package:atria/core/state/member_session_controller.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/settings/pin_gate.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The gate overlay: when it appears, and — much more importantly — when it
/// does not.
///
/// The property that carries the whole feature is negative. With local users
/// off, `MemberGateOverlay` must return its child untouched: same widget, no
/// dialog, no focus steal, no blocked back gesture. A gate that appeared for a
/// firm that never asked for one would break every existing install, and it is
/// the kind of break that only shows up on someone else's shop counter.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    firmId = firm.id;
    await container.read(activeFirmIdProvider.notifier).select(firmId);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpGate(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: Center(child: Text('BOOKS'))),
          builder: (context, child) =>
              MemberGateOverlay(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Adds a member, and returns it.
  ///
  /// Every database write in these tests goes through [WidgetTester.runAsync].
  /// A `testWidgets` body runs inside a fake-async zone, and drift's real
  /// futures never complete there — awaiting one directly hangs the test until
  /// the harness kills it, which is exactly what happened on the first run.
  /// `runAsync` steps out of the zone for the duration of the write.
  Future<FirmMemberEntity?> addMember(
    WidgetTester tester, {
    String name = 'Priya',
    String? pin = '4821',
  }) async {
    return tester.runAsync(
      () => db
          .membersRepositoryFor(firmId)
          .create(name: name, role: MemberRole.staff, pin: pin),
    );
  }

  Future<void> turnOn(WidgetTester tester) async {
    await tester.runAsync(() => db.setLocalUsersEnabled(firmId, true));
    container.invalidate(localUsersEnabledProvider);
  }

  Future<void> deactivate(WidgetTester tester, String memberId) async {
    await tester.runAsync(
      () => db.membersRepositoryFor(firmId).update(memberId, isActive: false),
    );
  }

  testWidgets('with the feature off the app is completely untouched', (
    tester,
  ) async {
    // A member exists, so the only thing keeping the gate away is the off
    // switch. If this test passes for the wrong reason it would not be
    // asserting the property that matters, hence the member.
    await addMember(tester);
    await pumpGate(tester);

    expect(find.text('BOOKS'), findsOneWidget);
    expect(find.text('Who is at the counter?'), findsNothing);
    // The gate's own scaffold is not in the tree at all — not hidden, absent.
    expect(find.byType(PinGate), findsNothing);
    expect(container.read(pinGateVisibleProvider), isFalse);
  });

  testWidgets('on, with an active member and nobody signed in, it gates', (
    tester,
  ) async {
    await addMember(tester);
    await turnOn(tester);
    await pumpGate(tester);

    expect(find.text('Who is at the counter?'), findsOneWidget);
    // The app is still mounted underneath — the gate covers it, it does not
    // replace it, so the nav stack survives a sign-in.
    expect(find.text('BOOKS'), findsOneWidget);
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('on but with nobody on the roster, it does not gate', (
    tester,
  ) async {
    // The lockout case. Enabling the feature before adding anybody must not
    // leave an operator unable to reach their own books.
    await turnOn(tester);
    await pumpGate(tester);

    expect(find.text('BOOKS'), findsOneWidget);
    expect(find.byType(PinGate), findsNothing);
    expect(container.read(pinGateVisibleProvider), isFalse);
  });

  testWidgets('on but with only deactivated members, it does not gate', (
    tester,
  ) async {
    final member = await addMember(tester);
    await deactivate(tester, member!.id);
    await turnOn(tester);
    await pumpGate(tester);

    expect(find.text('BOOKS'), findsOneWidget);
    expect(find.byType(PinGate), findsNothing);
  });

  testWidgets('a member with no PIN does not count as a signable member', (
    tester,
  ) async {
    // They are listed in Settings and shown in the picker, but a member who
    // chose no PIN cannot get past a keypad, so the gate would offer a dead
    // end. The gate stays down until someone can actually use it.
    await addMember(tester, name: 'Ravi', pin: null);
    await turnOn(tester);
    await pumpGate(tester);

    expect(find.text('BOOKS'), findsOneWidget);
    expect(find.byType(PinGate), findsNothing);
  });

  testWidgets('the right PIN dismisses the gate and sets the session', (
    tester,
  ) async {
    await addMember(tester);
    await turnOn(tester);
    await pumpGate(tester);

    await tester.tap(find.text('Priya'));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);

    for (final digit in ['4', '8', '2', '1']) {
      await tester.tap(find.widgetWithText(OutlinedButton, digit));
    }
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    // The hash is iterated, so the verification is real work outside the fake
    // clock; runAsync lets it finish and then hand the result back.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PinGate), findsNothing);
    // And the session is the one the repositories will read.
    final session = db.session;
    expect(session.enabled, isTrue);
    expect(session.name, 'Priya');
    expect(session.role, MemberRole.staff);
    expect(container.read(memberSessionProvider).isSignedIn, isTrue);
  });

  testWidgets('a wrong PIN keeps the gate up and says so', (tester) async {
    await addMember(tester);
    await turnOn(tester);
    await pumpGate(tester);

    await tester.tap(find.text('Priya'));
    await tester.pumpAndSettle();
    for (final digit in ['1', '1', '1', '1']) {
      await tester.tap(find.widgetWithText(OutlinedButton, digit));
    }
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PinGate), findsOneWidget);
    expect(find.textContaining('not right'), findsOneWidget);
    // No session was written — a wrong guess must not leave one behind.
    expect(db.session.enabled, isFalse);
  });

  testWidgets('signing out puts the gate back', (tester) async {
    await addMember(tester);
    await turnOn(tester);
    await pumpGate(tester);

    container
        .read(memberSessionProvider.notifier)
        .signIn(
          const MemberSession(
            enabled: true,
            memberId: 'mem_1',
            name: 'Priya',
            role: MemberRole.staff,
          ),
        );
    await tester.pumpAndSettle();
    expect(find.byType(PinGate), findsNothing);

    container.read(memberSessionProvider.notifier).signOut();
    await tester.pumpAndSettle();
    expect(find.byType(PinGate), findsOneWidget);

    // And the session the repositories read is genuinely cleared, not just the
    // overlay hidden — otherwise a hidden gate would still be filtering writes.
    expect(db.session.enabled, isFalse);
  });

  testWidgets('turning the feature off clears the session as well as the gate', (
    tester,
  ) async {
    // A firm that says "no PINs" must not still be filtering writes by the role
    // of whoever happened to be signed in a moment ago.
    await addMember(tester);
    await turnOn(tester);
    container
        .read(memberSessionProvider.notifier)
        .signIn(
          const MemberSession(
            enabled: true,
            memberId: 'mem_1',
            name: 'Priya',
            role: MemberRole.accountant,
          ),
        );
    await pumpGate(tester);
    expect(find.byType(PinGate), findsNothing);

    // What the switch in Settings actually does, in the order it does it:
    // write the flag off, then drop the session.
    await tester.runAsync(() => db.setLocalUsersEnabled(firmId, false));
    container.invalidate(localUsersEnabledProvider);
    container.read(memberSessionProvider.notifier).disable();
    await tester.pumpAndSettle();

    expect(find.byType(PinGate), findsNothing);
    expect(db.session.enabled, isFalse);
    // Back to granting everything, which is what off means.
    expect(db.session.allows(Permission.purge), isTrue);
  });

  testWidgets('signing out while the feature is still on brings the gate back', (
    tester,
  ) async {
    // The distinction the previous test is built on: sign-out is not turn-off.
    // A firm that keeps the feature on and has nobody signed in must see the
    // gate again — that is the whole point of a gate.
    await addMember(tester);
    await turnOn(tester);
    container
        .read(memberSessionProvider.notifier)
        .signIn(
          const MemberSession(
            enabled: true,
            memberId: 'mem_1',
            name: 'Priya',
            role: MemberRole.admin,
          ),
        );
    await pumpGate(tester);
    expect(find.byType(PinGate), findsNothing);

    container.read(memberSessionProvider.notifier).signOut();
    await tester.pumpAndSettle();

    expect(find.byType(PinGate), findsOneWidget);
    expect(db.session.enabled, isFalse);
  });
}
