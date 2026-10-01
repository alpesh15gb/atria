import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/state/providers.dart';
import 'core/theme/app_theme.dart';

/// How often an open app syncs on its own.
const Duration _autoSyncInterval = Duration(seconds: 60);

class AtriaApp extends ConsumerStatefulWidget {
  const AtriaApp({super.key});

  @override
  ConsumerState<AtriaApp> createState() => _AtriaAppState();
}

class _AtriaAppState extends ConsumerState<AtriaApp> {
  Timer? _autoSyncTimer;
  bool _autoSyncRunning = false;

  @override
  void initState() {
    super.initState();
    // Deferred to after the first frame so the drain can never sit between the
    // user and their first screen, however slow the network is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seedChart();
      _drainOutbox();
      _startAutoSync();
    });
  }

  /// Keeps every signed-in device's books converging while the app is open.
  ///
  /// Sixty seconds is the balance the sync feature asks for: fast enough that
  /// a second device at the counter sees the day's invoices within a minute,
  /// slow enough that a shop's always-on tablet is not chatting to the server
  /// every few seconds. Every run honours the sync switch, so a device with
  /// sync off simply costs one settings read a minute and nothing else.
  /// Runs never overlap: a sync still in flight when the next tick fires is
  /// skipped, not queued.
  void _startAutoSync() {
    _autoSyncTimer = Timer.periodic(_autoSyncInterval, (_) async {
      if (_autoSyncRunning) return;
      _autoSyncRunning = true;
      try {
        await ref.read(syncEngineProvider).sync();
      } on Object {
        // Reported by the engine on the settings screen; a background tick
        // must never surface a dialog by itself.
      } finally {
        _autoSyncRunning = false;
      }
    });
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    super.dispose();
  }

  /// Seeds the active firm's chart of accounts, once, at launch.
  ///
  /// Done here rather than from the ledger screens because seeding is a write,
  /// and a screen that writes just by being opened is a screen that leaves a
  /// transaction in flight whenever it is disposed mid-write (which is what
  /// hangs a widget test's teardown, and what a torn-down frame does in
  /// production too). A firm created after this feature shipped therefore gets
  /// its chart on the next launch, and the ledger reports call `ensureChart`
  /// themselves as a second net.
  Future<void> _seedChart() async {
    try {
      await ref.read(ensureChartProvider.future);
    } on Object {
      // A chart that failed to seed must not stop the app from opening: the
      // ledger screens report it, and every report retries the seed.
    }
  }

  /// The once-per-launch push of whatever the outbox accumulated.
  ///
  /// Best-effort and deliberately silent: the sync switch may be off (in which
  /// case this returns without touching the network), the device may be offline,
  /// or nobody may be signed in. None of those is a boot error the person can
  /// act on, and Settings is where the outbox reports what it did — so a failure
  /// here is left for that screen rather than turned into a dialog nobody asked
  /// for.
  Future<void> _drainOutbox() async {
    try {
      await ref.read(syncEngineProvider).push();
    } on Object {
      // See above: reported where it can be acted on.
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'Atria — Accounting & GST Billing',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      locale: const Locale('en', 'IN'),
      supportedLocales: const [
        Locale('en', 'IN'),
        Locale('en'),
      ],
      // One router for the app's whole lifetime. The boot splash is now the
      // `/boot` route inside it (see [appRouterProvider]); swapping the
      // routerConfig between a splash router and the real one used to strand
      // Android relaunches — the engine re-delivers the last route after
      // process death, and the splash-only boot router had no such route, so
      // go_router's default "The route /onboarding/firm-setup does not exist"
      // page appeared before the real router ever mounted.
      routerConfig: ref.watch(appRouterProvider),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            // Cap text scaling so accounting tables stay legible and aligned.
            textScaler: MediaQuery.textScalerOf(context).clamp(
              maxScaleFactor: 1.15,
            ),
          ),
          child: child!,
        );
      },
    );
  }
}
