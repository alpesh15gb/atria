import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/state/providers.dart';
import 'features/settings/pin_gate.dart';
import 'core/theme/app_theme.dart';

/// How often an open app syncs on its own.
const Duration _autoSyncInterval = Duration(seconds: 60);

class AtriaApp extends ConsumerStatefulWidget {
  const AtriaApp({super.key});

  @override
  ConsumerState<AtriaApp> createState() => _AtriaAppState();
}

class _AtriaAppState extends ConsumerState<AtriaApp>
    with WidgetsBindingObserver {
  Timer? _autoSyncTimer;
  bool _autoSyncRunning = false;

  /// False between a backgrounding notification and the next `resumed`. Read by
  /// [_startAutoSync] so a first frame that lands while the app is already in
  /// the background does not quietly arm the timer again.
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    // The auto-sync timer has to stop when the app is not on screen, so this
    // state has to hear about lifecycle changes. Same mixin the dashboard uses
    // for its own refresh-on-resume.
    WidgetsBinding.instance.addObserver(this);
    // Deferred to after the first frame so the drain can never sit between the
    // user and their first screen, however slow the network is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _seedChart();
      _backfillCosting();
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
  ///
  /// Idempotent, because `resumed` and the first-frame callback above race:
  /// whichever arrives second must find a timer already running rather than
  /// start a second one.
  void _startAutoSync() {
    if (!_foreground || _autoSyncTimer != null) return;
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

  /// Stops the periodic sync entirely — see [didChangeAppLifecycleState].
  void _stopAutoSync() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
  }

  /// Pauses sync while the app is not in front of the user, and restarts it
  /// when they come back.
  ///
  /// Without this the 60-second timer ran for the life of the process. On
  /// Android a backgrounded app is throttled but not stopped, and on Windows
  /// nothing stops the process at all when the window is minimised — so a shop
  /// whose counter PC sits open all day made ~1440 pointless round trips a day
  /// against the sync server while nobody was looking at the books.
  ///
  /// Resuming deliberately does **not** sync immediately. `Timer.periodic`
  /// restarts its countdown when it is created, so the first tick after a
  /// return comes a full interval later; firing one on resume would stack a
  /// catch-up run on top of the one already in flight and, on a device that was
  /// away for hours, on top of whatever the app-switcher's own first frame
  /// kicks off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _startAutoSync();
        break;
      case AppLifecycleState.inactive:
      // `inactive` comes first on Android and also covers the desktop case of
      // another window being dragged over ours: still not visible, so stop.
      // `hidden` is the pre-`paused` Android state, `detached` is teardown.
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _stopAutoSync();
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAutoSync();
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

  /// Stamps the cost onto stock movements written before costing existed.
  ///
  /// At launch for the same reason as the chart: it is a write, and a screen
  /// that writes by being opened leaves a transaction in flight whenever it is
  /// disposed mid-write. Best-effort — a backfill that fails must not stop the
  /// app opening, and the next launch retries it.
  Future<void> _backfillCosting() async {
    try {
      await ref.read(backfillUnitCostsProvider.future);
    } on Object {
      // Un-costed history is wrong but not broken: the reports say so, and the
      // next launch tries again.
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
      title: 'Apex Books — Accounting & GST Billing',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      locale: const Locale('en', 'IN'),
      supportedLocales: const [Locale('en', 'IN'), Locale('en')],
      // One router for the app's whole lifetime. The boot splash is now the
      // `/boot` route inside it (see [appRouterProvider]); swapping the
      // routerConfig between a splash router and the real one used to strand
      // Android relaunches — the engine re-delivers the last route after
      // process death, and the splash-only boot router had no such route, so
      // go_router's default "The route /onboarding/firm-setup does not exist"
      // page appeared before the real router ever mounted.
      routerConfig: ref.watch(appRouterProvider),
      // The optional PIN gate, over the whole app.
      //
      // A `builder`, not a route, and the comment below explains why the app
      // has no `builder` at all — read that first, because the two are easy to
      // confuse. That note is about *scaling text*; this is about gating, and
      // the gate deliberately does not wrap the router in a way that could
      // interfere with it: `MemberGateOverlay` returns the child untouched
      // unless the firm has opted into local users, so with the feature off —
      // which is every existing install — this costs one provider read and
      // changes nothing about what is on screen.
      builder: (context, child) =>
          MemberGateOverlay(child: child ?? const SizedBox.shrink()),
      // NOTE: no `builder` is used to re-wrap every route.
      //
      // The app used to re-wrap every route in
      // `MediaQuery(textScaler: …clamp(maxScaleFactor: 1.15))`. That cap was
      // wrong and it was silent: Android's Settings ▸ Display ▸ Font size goes
      // to 2.0×, so a user who had asked for the largest text the platform
      // offers got 115 % of it and no indication that the rest was discarded
      // (a WCAG 1.4.4 failure), and Windows — which has no other text-scale
      // knob in the app at all — had nothing to give. Several layouts were
      // tuned against 1.15×, so the strip that genuinely cannot take 2.0× is
      // fixed to say so at the layout (see `atria_list_toolbar.dart`,
      // `atria_page_header.dart`, `tax_mode_toggle.dart` and the dashboard)
      // rather than by silently shrinking everyone's type.
      //
      // Any ceiling added here in future must be the platform maximum, never a
      // round number smaller than it.
    );
  }
}
