import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the bug where "Get Started" and "Skip" on the
/// onboarding screen appeared to do nothing.
///
/// The router redirect reads [onboardingDoneProvider] on every navigation. It
/// used to be a `FutureProvider`, which resolves once and never re-runs, so
/// after the flag was persisted the redirect still saw `false` and bounced
/// every `context.go('/dashboard')` straight back to `/onboarding`. The flag
/// must therefore live in synchronous state and flip before we navigate.
void main() {
  late ProviderContainer container;
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    // Both controllers load persisted values in the background; let them
    // settle before asserting on the redirect.
    await container.read(appInitializationProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Builds the redirect's inputs straight from provider state, exactly the
  /// way [appRouterProvider] does — so the test covers both the controller and
  /// the decision logic in one shot.
  String? redirectFor(String path) {
    return resolveOnboardingRedirect(
      onboardingDone: container.read(onboardingDoneProvider),
      activeFirmId: container.read(activeFirmIdProvider),
      path: path,
    );
  }

  test('onboarding flag is synchronous and flips before persistence lands',
      () async {
    expect(container.read(onboardingDoneProvider), isFalse,
        reason: 'A fresh database has never completed onboarding.');

    // The fix: state flips first, so a redirect reading this provider right
    // after the call sees `true` even before the write is awaited.
    final done = container.read(onboardingDoneProvider.notifier).complete();
    expect(container.read(onboardingDoneProvider), isTrue);
    expect(redirectFor('/dashboard'), '/onboarding/firm-setup');

    await done;
    final persisted = await container
        .read(settingsRepositoryProvider)
        .getBool(SettingsRepository.kOnboardingDone);
    expect(persisted, isTrue);
  });

  group('resolveOnboardingRedirect', () {
    test('a brand-new user is kept on onboarding', () {
      expect(redirectFor('/dashboard'), '/onboarding');
      expect(redirectFor('/sales'), '/onboarding');
      // ...but may stay on the welcome pages.
      expect(redirectFor('/onboarding'), isNull);
      expect(redirectFor('/onboarding/firm-setup'), isNull);
    });

    test('onboarding done with no firm is sent to firm setup', () async {
      container.read(onboardingDoneProvider.notifier);
      // Simulate the completion that _finish() performs. The write has to be
      // awaited: leaving it in flight means tearDown's db.close() lands mid
      // transaction and drift reports the rollback as a post-test failure.
      await container.read(onboardingDoneProvider.notifier).complete();
      expect(container.read(activeFirmIdProvider), isNull);
      expect(redirectFor('/dashboard'), '/onboarding/firm-setup');
    });

    test('a firm plus the flag reaches the dashboard', () async {
      final firm = await db.firmRepository.create(name: 'Test Trading Co.');
      await container.read(activeFirmIdProvider.notifier).select(firm.id);
      await container.read(onboardingDoneProvider.notifier).complete();

      // Onboarding is now a dead end — it would strand a configured user.
      expect(redirectFor('/onboarding'), '/dashboard');
      expect(redirectFor('/dashboard'), isNull);
      expect(redirectFor('/sales/new'), isNull);
    });

    test('a returning user is not bounced back to onboarding', () async {
      // This is the half of the bug that hit every launch after the first:
      // the persisted flag said true, but a stale provider still read false.
      await container
          .read(settingsRepositoryProvider)
          .setBool(SettingsRepository.kOnboardingDone, true);
      final firm = await db.firmRepository.create(name: 'Test Trading Co.');
      await container.read(activeFirmIdProvider.notifier).select(firm.id);

      // Rebuild the container the way a fresh launch would.
      container.dispose();
      container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      await container.read(appInitializationProvider.future);

      expect(container.read(onboardingDoneProvider), isTrue);
      expect(redirectFor('/dashboard'), isNull,
          reason: 'A returning user should land on the dashboard.');
    });
  });
}
