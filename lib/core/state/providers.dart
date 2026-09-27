import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/app_database.dart';
import '../database/repositories/audit_repository.dart';
import '../database/repositories/firm_repository.dart';
import '../database/repositories/repository_extensions.dart';
import '../database/repositories/settings_repository.dart';

// ---- Core singletons ----

final Provider<AppDatabase> appDatabaseProvider = Provider((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider((ref) => SettingsRepository(ref.read(appDatabaseProvider)));

final backupRepositoryProvider = Provider(
    (ref) => BackupRepository(ref.read(appDatabaseProvider)));

final auditRepositoryProvider = Provider(
    (ref) => AuditRepository(ref.read(appDatabaseProvider)));

/// Period lock for the ACTIVE firm. Watched so UI can react to lock/unlock.
final periodLockProvider = Provider((ref) {
  return PeriodLock(ref.read(settingsRepositoryProvider));
});

/// The active firm's lock boundary (null = books open), reactive.
final booksLockedUptoProvider = FutureProvider<DateTime?>((ref) async {
  final firmId = ref.watch(activeFirmIdProvider);
  return ref.read(periodLockProvider).lockedUpto(firmId: firmId);
});

final firmRepositoryProvider = Provider(
    (ref) => ref.read(appDatabaseProvider).firmRepository);

// ---- Active firm ----

/// The firm whose books are currently open. Persisted across launches.
class ActiveFirmController extends StateNotifier<String?> {
  ActiveFirmController(this._settings, this._firmRepo) : super(null) {
    _init();
  }

  final SettingsRepository _settings;
  final FirmRepository _firmRepo;
  final _ready = Completer<void>();

  /// The error that killed [_init], if any. See [OnboardingController.initError].
  Object? initError;

  /// Resolves once the persisted firm id has been loaded on startup. Rejects
  /// when the load failed.
  Future<void> get ready => _ready.future;

  Future<void> _init() async {
    try {
      initError = null;
      final stored = await _settings.get(SettingsRepository.kActiveFirmId);
      if (stored != null) {
        final exists = await _firmRepo.getById(stored);
        if (exists != null) {
          state = stored;
          return;
        }
      }
      final def = await _firmRepo.defaultFirm;
      state = def?.id;
    } catch (error, stack) {
      initError = error;
      _ready.completeError(error, stack);
      return;
    } finally {
      // The early return above must still resolve the gate; completeError has
      // already done so on the failure path.
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> select(String? firmId) async {
    state = firmId;
    if (firmId != null) {
      await _settings.set(SettingsRepository.kActiveFirmId, firmId);
    }
  }
}

final activeFirmIdProvider =
    StateNotifierProvider<ActiveFirmController, String?>((ref) {
  return ActiveFirmController(
    ref.read(settingsRepositoryProvider),
    ref.read(firmRepositoryProvider),
  );
});

/// The currently active firm entity (reactive).
final activeFirmProvider = StreamProvider<FirmEntity?>((ref) async* {
  final id = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (id == null) {
    yield null;
    return;
  }
  yield* db.firmRepository.watchById(id);
});

final allFirmsProvider = StreamProvider<List<FirmEntity>>((ref) {
  return ref.read(appDatabaseProvider).firmRepository.watchAll();
});

// ---- Firm-scoped repositories ----

final partyRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.partyRepositoryFor(firmId);
});

final itemRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.itemRepositoryFor(firmId);
});

final salesRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.salesRepositoryFor(firmId);
});

final purchaseRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.purchaseRepositoryFor(firmId);
});

final paymentRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.paymentRepositoryFor(firmId);
});

final expenseRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.expenseRepositoryFor(firmId);
});

final reportRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.reportRepositoryFor(firmId);
});

// ---- Appearance ----

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._settings) : super(ThemeMode.system) {
    _init();
  }

  final SettingsRepository _settings;

  Future<void> _init() async {
    final stored = await _settings.get(SettingsRepository.kThemeMode);
    switch (stored) {
      case 'light':
        state = ThemeMode.light;
        break;
      case 'dark':
        state = ThemeMode.dark;
        break;
      default:
        state = ThemeMode.system;
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final value = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
            ? 'dark'
            : 'system';
    await _settings.set(SettingsRepository.kThemeMode, value);
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController(ref.read(settingsRepositoryProvider));
});

// ---- Onboarding flags ----

/// Whether first-run onboarding has been completed.
///
/// Held as *synchronous* state because [appRouterProvider]'s redirect reads it
/// on every navigation. As a FutureProvider it would resolve once and stay
/// cached: after the flag was written, the redirect would keep seeing `false`
/// and bounce every `/dashboard` navigation back to `/onboarding` — which is
/// why "Get Started" and "Skip" appeared to do nothing. [complete] flips state
/// first and persists second, so the router sees the new value immediately.
class OnboardingController extends StateNotifier<bool> {
  OnboardingController(this._settings) : super(false) {
    _init();
  }

  final SettingsRepository _settings;
  final _ready = Completer<void>();

  /// The error that killed [_init], if any. Surfaced through [ready] so the
  /// boot gate can show a recovery screen instead of hanging on a splash.
  Object? initError;

  /// Resolves once the persisted flag has been loaded on startup. Rejects when
  /// the load failed, so [appInitializationProvider] does not hand the router
  /// a state built on an unreadable database.
  Future<void> get ready => _ready.future;

  Future<void> _init() async {
    try {
      initError = null;
      state = await _settings.getBool(SettingsRepository.kOnboardingDone);
    } catch (error, stack) {
      initError = error;
      _ready.completeError(error, stack);
      return;
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  Future<void> complete() async {
    state = true;
    await _settings.setBool(SettingsRepository.kOnboardingDone, true);
  }
}

final onboardingDoneProvider =
    StateNotifierProvider<OnboardingController, bool>((ref) {
  return OnboardingController(ref.read(settingsRepositoryProvider));
});

/// Blocks the router from rendering until the persisted onboarding flag and
/// active firm have loaded, so the redirect never decides on cold-start data.
///
/// Both controllers' `finally` blocks used to complete their readiness futures
/// unconditionally, so a database that failed to open made this resolve anyway
/// and the app sailed into a crash on its first real query. Now the futures
/// reject, and [AtriaApp] renders a recovery screen.
final appInitializationProvider = FutureProvider<void>((ref) async {
  await ref.read(onboardingDoneProvider.notifier).ready;
  await ref.read(activeFirmIdProvider.notifier).ready;
});

final seededDemoProvider = FutureProvider<bool>((ref) async {
  return ref
      .read(settingsRepositoryProvider)
      .getBool(SettingsRepository.kSeededDemo);
});
