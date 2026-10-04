import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_config.dart';
import '../api/auth_client.dart';
import '../api/scan_client.dart';
import '../api/server_client.dart';
import '../api/server_session.dart';
import '../api/sync_client.dart';
import '../sync/sync_engine.dart';
import 'auth_controller.dart';
import '../database/app_database.dart';
import '../database/repositories/audit_repository.dart';
import '../database/repositories/firm_repository.dart';
import '../database/repositories/ledger_repository.dart';
import '../database/repositories/repository_extensions.dart';
import '../database/repositories/settings_repository.dart';
import '../printer/printer_service.dart';

// ---- Core singletons ----

final Provider<AppDatabase> appDatabaseProvider = Provider((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final Provider<SettingsRepository> settingsRepositoryProvider =
    Provider((ref) => SettingsRepository(ref.read(appDatabaseProvider)));

/// Where the app talks to the Apex Books server, and this install's identity.
final Provider<ApiConfig> apiConfigProvider =
    Provider((ref) => ApiConfig(ref.read(settingsRepositoryProvider)));

/// This install's Apex Books session. Not signed in is the normal state today —
/// sign-in is not built yet — so callers must handle a null [SignedIn] rather
/// than assume one. See [ServerSession].
final Provider<ServerSession> serverSessionProvider =
    Provider((ref) => ServerSession(ref.read(settingsRepositoryProvider)));

/// The API client for everything that is not sign-in.
final Provider<ServerClient> serverClientProvider =
    Provider((ref) => ServerClient(ref.read(apiConfigProvider)));

/// Sign-up, sign-in, refresh and sign-out.
final Provider<AuthClient> authClientProvider =
    Provider((ref) => AuthClient(ref.read(apiConfigProvider)));

/// This device's session, kept alive across launches. Everything that needs a
/// token reads it through this rather than through the settings rows, so token
/// renewal happens in one place instead of at every call site.
final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(
    ref.read(serverSessionProvider),
    ref.read(authClientProvider),
  );
});

/// The change-journal endpoint (sync push).
final Provider<SyncClient> syncClientProvider =
    Provider((ref) => SyncClient(ref.read(apiConfigProvider)));

/// The server's bill-scan endpoint (purchase OCR via the VPS).
final Provider<ScanClient> scanClientProvider =
    Provider((ref) => ScanClient(ref.read(apiConfigProvider)));

/// Drains the outbox. Holds no state of its own — a run is a call, and what it
/// did is reported back to whoever asked.
final Provider<SyncEngine> syncEngineProvider = Provider((ref) {
  return SyncEngine(
    ref.read(appDatabaseProvider),
    ref.read(settingsRepositoryProvider),
    ref.read(authControllerProvider.notifier),
    ref.read(syncClientProvider),
  );
});

/// Fires whenever any stock movement is written in the active firm.
///
/// Screens that show cached balances (`currentStock`) stay mounted under the
/// nav shell's IndexedStack and so never rebuild when a sale or a purchase
/// elsewhere changes them. Watching this re-runs them. Kept in [providers.dart]
/// because two screens need the same signal and it must be one instance for the
/// caching to be shared.
final itemMovementSignalProvider = StreamProvider<void>((ref) async* {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.watch(appDatabaseProvider);
  if (firmId == null) return;
  final repo = db.itemRepositoryFor(firmId);
  // The rows are discarded: only the emission matters.
  yield* repo.watchAllMovements().map((_) {});
});

/// How many changes are waiting, and when the outbox last drained.
///
/// The outbox grows on every save, so this is a stream over the outbox itself
/// rather than a one-off read. Settings is a nav-shell branch and stays mounted
/// offstage, so a cached read would keep showing "nothing is waiting" while the
/// shop bills on another tab — a number that is wrong in exactly the way that
/// matters, since it is the one that tells you whether the books are safe.
///
/// The raw outbox stream emits once per write, which would rebuild the settings
/// screen once per document; the burst is collapsed in [_coalesceOutboxChanges]
/// instead.
final syncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final engine = ref.read(syncEngineProvider);
  final settings = ref.read(settingsRepositoryProvider);
  yield* _coalesceOutboxChanges(engine.watchPendingCount())
      .asyncMap((_) async {
    // Both stamps are kept: a push can succeed while the pull failed (the
    // directions are independent), and "last synced" should only claim a full
    // round trip when both directions completed.
    final rawPushed = await settings.get(SettingsRepository.kSyncLastPushedAt);
    final rawSynced = await settings.get(SettingsRepository.kSyncLastSyncedAt);
    return SyncStatus(
      pending: await engine.pendingCount(),
      lastPushedAt:
          rawPushed == null ? null : DateTime.tryParse(rawPushed)?.toLocal(),
      lastSyncedAt:
          rawSynced == null ? null : DateTime.tryParse(rawSynced)?.toLocal(),
    );
  });
});

/// Passes the first outbox event through at once, then only after [quiet] has
/// passed without another, so a shop billing fifty invoices in a row produces
/// one re-read at the end of the burst rather than fifty.
Stream<void> _coalesceOutboxChanges(Stream<int> pending,
    {Duration quiet = const Duration(seconds: 1)}) {
  final controller = StreamController<void>.broadcast();
  Timer? timer;
  var first = true;
  StreamSubscription<int>? subscription;
  controller.onListen = () {
    subscription = pending.listen((_) {
      if (first) {
        // The current count matters immediately; later ones can wait for quiet.
        first = false;
        controller.add(null);
        return;
      }
      timer?.cancel();
      timer = Timer(quiet, () => controller.add(null));
    });
  };
  controller.onCancel = () {
    timer?.cancel();
    subscription?.cancel();
  };
  return controller.stream;
}

/// What the settings screen shows about sync.
class SyncStatus {
  const SyncStatus({required this.pending, this.lastPushedAt, this.lastSyncedAt});

  /// Changes waiting to be sent.
  final int pending;

  /// When the outbox last drained fully, or null if there has never been one.
  final DateTime? lastPushedAt;

  /// When the last full sync (push + pull) finished, or null if there has
  /// never been one. Shown in preference to [lastPushedAt].
  final DateTime? lastSyncedAt;
}

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
          _watchFirmExistence(stored);
          return;
        }
      }
      final def = await _firmRepo.defaultFirm;
      state = def?.id;
      if (def != null) _watchFirmExistence(def.id);
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

  StreamSubscription<FirmEntity?>? _existenceWatch;

  /// Repoints the active firm when its row disappears from underneath it.
  ///
  /// The local deletion path does this itself (`_repointActiveFirm` in the firm
  /// settings screen). The sync pull does not: a firm erased on another device
  /// arrives as a tombstone, [PullApplier] hard-deletes the row, and nothing
  /// clears the id — so this device keeps showing a phantom, zeroed business
  /// (every firm-scoped repository is non-null while the id is set) and the
  /// switcher stops listing it, with no way back but a relaunch. Rather than
  /// push Riverpod into the applier, the controller heals itself: it watches the
  /// row it selected and, when it goes, applies the same policy as the local
  /// path.
  void _watchFirmExistence(String firmId) {
    _existenceWatch?.cancel();
    _existenceWatch = _firmRepo.watchById(firmId).listen((firm) async {
      if (firm != null) return;
      final remaining = await _firmRepo.all();
      if (remaining.isEmpty) {
        await clear();
        return;
      }
      // Keep the existing default if there is one, so "which business opens on
      // launch" does not silently change just because this one was deleted.
      final next = remaining.firstWhere(
        (firm) => firm.isDefault,
        orElse: () => remaining.first,
      );
      await select(next.id);
      if (!next.isDefault) {
        await _firmRepo.setDefault(next.id);
      }
    });
  }

  @override
  void dispose() {
    _existenceWatch?.cancel();
    super.dispose();
  }

  Future<void> select(String? firmId) async {
    state = firmId;
    if (firmId != null) {
      await _settings.set(SettingsRepository.kActiveFirmId, firmId);
      _watchFirmExistence(firmId);
    }
  }

  /// Drops the active firm outright, including the stored one.
  ///
  /// Needed for the case [select] deliberately cannot express: the business
  /// that was open has just been deleted. `select(null)` only clears the
  /// in-memory state, so the deleted firm's id would survive in settings and
  /// the next launch would come up pointing at books that no longer exist.
  Future<void> clear() async {
    state = null;
    await _settings.remove(SettingsRepository.kActiveFirmId);
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

/// Chart of accounts, journal vouchers and the ledger reports.
final ledgerRepositoryProvider = Provider((ref) {
  final firmId = ref.watch(activeFirmIdProvider);
  final db = ref.read(appDatabaseProvider);
  if (firmId == null) return null;
  return db.ledgerRepositoryFor(firmId);
});

/// Seeds the firm's standard chart of accounts, once.
///
/// A provider rather than work the migration does, because a firm created
/// *after* the upgrade needs a chart too. Idempotent, so watching it from a
/// screen costs nothing after the first time.
final ensureChartProvider = FutureProvider<int>((ref) async {
  final repo = ref.watch(ledgerRepositoryProvider);
  if (repo == null) return 0;
  return repo.ensureChart();
});

/// The whole chart, archived accounts included — the screen decides which to
/// show, so filtering happens in the UI without a second query.
final chartOfAccountsProvider = StreamProvider<List<AccountEntity>>((ref) {
  final repo = ref.watch(ledgerRepositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.watchAccounts(includeInactive: true);
});

final journalsProvider = StreamProvider<List<JournalEntryEntity>>((ref) {
  final repo = ref.watch(ledgerRepositoryProvider);
  if (repo == null) return const Stream.empty();
  return repo.watchJournals(includeDeleted: true);
});

/// Cash in hand, bank balances and cheques in hand — the Payments screen's
/// three cards, read from the ledger rather than re-derived from payments.
class CashBankBalances {
  const CashBankBalances({
    this.cash = 0,
    this.bank = 0,
    this.cheques = 0,
  });

  final double cash;
  final double bank;
  final double cheques;
}

/// Cash in hand, bank balances and uncleared cheques, read from the books.
///
/// The Payments screen's cards and the ledger's Cash/Bank accounts are the
/// same figures under the same names, so they have to come from the same
/// place. Summing the payment rows alone disagrees with the books by every
/// amount that left the till another way — a cash expense, an income receipt,
/// a hand-keyed voucher — and the two would drift apart forever after.
final cashBankBalancesProvider =
    StreamProvider.autoDispose<CashBankBalances>((ref) async* {
  final repo = ref.watch(ledgerRepositoryProvider);
  if (repo == null) {
    yield const CashBankBalances();
    return;
  }
  // Re-derive whenever any table the books are built from moves — a payment,
  // but also a cash expense or a journal voucher, all of which post to cash.
  await for (final _ in repo.watchBookMovement()) {
    final tb = await repo.trialBalance(asOf: DateTime.now());
    double closingOf(String code) {
      for (final row in tb.rows) {
        if (row.account.code == code) return row.closing;
      }
      return 0;
    }

    yield CashBankBalances(
      cash: closingOf(LedgerCodes.cash),
      bank: closingOf(LedgerCodes.bank),
      cheques: closingOf(LedgerCodes.chequesInHand),
    );
  }
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
      final persisted = await _settings.getBool(SettingsRepository.kOnboardingDone);
      // A complete() that raced this load wins: it flips the flag for a user
      // action that has already happened, while this load only reports what a
      // previous run persisted. Letting the stale read overwrite the flip
      // silently discarded the completion (and would bounce that user back to
      // the welcome pages on the next redirect).
      if (!_completed) state = persisted;
    } catch (error, stack) {
      initError = error;
      _ready.completeError(error, stack);
      return;
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  bool _completed = false;

  Future<void> complete() async {
    _completed = true;
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

// ---- Label printers ----

final printerRegistryProvider = Provider<PrinterRegistry>(
    (ref) => PrinterRegistry(ref.read(appDatabaseProvider)));

/// The configured printers. Invalidated after every change rather than mutated
/// in place, so the list and the default can never disagree about what exists.
final printersProvider = FutureProvider<List<PrinterProfile>>(
    (ref) => ref.read(printerRegistryProvider).all());

/// The printer the print buttons use. Watches [printersProvider] so removing
/// the current default immediately promotes the replacement here too.
final defaultPrinterProvider = FutureProvider<PrinterProfile?>((ref) async {
  await ref.watch(printersProvider.future);
  return ref.read(printerRegistryProvider).defaultPrinter();
});
