import 'core/sync/live_sync.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'core/responsive/platform_ui.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/navigation/mobile_back_navigation.dart';
import 'core/state/providers.dart';
import 'features/settings/pin_gate.dart';
import 'core/theme/app_theme.dart';
import 'shared/widgets/interface_scale.dart';

/// How often an open app syncs on its own.
const Duration _autoSyncInterval = Duration(seconds: 5);

class AtriaApp extends ConsumerStatefulWidget {
  const AtriaApp({super.key});

  @override
  ConsumerState<AtriaApp> createState() => _AtriaAppState();
}

class _AtriaAppState extends ConsumerState<AtriaApp>
    with WidgetsBindingObserver {
  LiveSync? _liveSync;
  int _remoteGeneration = 0;

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
      _startAutoSync();
    });
  }

  // Saves are debounced; remote devices are checked every five seconds.
  // Resume catches up immediately and backgrounding stops new network work.
  void _startAutoSync() {
    if (!_foreground || !mounted) return;
    if (_liveSync == null && ref.read(authControllerProvider).signedIn) {
      unawaited(_watchRemote(++_remoteGeneration));
    }
    _liveSync ??= LiveSync(
      interval: _autoSyncInterval,
      pending: ref.read(syncEngineProvider).watchPendingCount(),
      sync: () async {
        if (!ref.read(authControllerProvider).signedIn) return;
        final report = await ref.read(syncEngineProvider).sync();
        if (!mounted || !report.ok || report.skipped) return;
        if (ref.read(activeFirmIdProvider) == null) {
          final firm = await ref.read(firmRepositoryProvider).defaultFirm;
          if (!mounted || firm == null) return;
          await ref.read(activeFirmIdProvider.notifier).select(firm.id);
          await ref.read(onboardingDoneProvider.notifier).complete();
        }
      },
    );
    _liveSync!.resume();
  }

  void _stopAutoSync() {
    _remoteGeneration++;
    _liveSync?.dispose();
    _liveSync = null;
  }

  Future<void> _watchRemote(int generation) async {
    while (mounted && _foreground && generation == _remoteGeneration) {
      final started = DateTime.now();
      try {
        final firmId = ref.read(activeFirmIdProvider);
        if (firmId != null &&
            ref.read(authControllerProvider).signedIn &&
            await ref.read(syncEngineProvider).waitForChanges(firmId)) {
          if (mounted && generation == _remoteGeneration) {
            _liveSync?.request(immediate: true);
          }
        }
      } catch (_) {
        // Offline keeps both the session and outbox intact; retry below.
      }
      // Also bounds requests against older servers without long-poll support.
      final elapsed = DateTime.now().difference(started);
      if (elapsed < _autoSyncInterval) {
        await Future<void>.delayed(_autoSyncInterval - elapsed);
      }
    }
  }

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

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final router = ref.watch(appRouterProvider);
    final mobileBack = defaultTargetPlatform.isMobileUi
        ? ref.watch(mobileBackNavigationProvider)
        : null;
    ref.listen(authControllerProvider, (previous, next) {
      if (next.signedIn && previous?.signedIn != true) {
        _liveSync?.request(immediate: true);
        unawaited(_watchRemote(++_remoteGeneration));
      }
    });

    return MaterialApp.router(
      title: 'Apex Books — Accounting & GST Billing',
      debugShowCheckedModeBanner: false,
      theme: defaultTargetPlatform.isMobileUi
          ? AppTheme.mobile(dark: false)
          : AppTheme.light(),
      darkTheme: defaultTargetPlatform.isMobileUi
          ? AppTheme.mobile(dark: true)
          : AppTheme.dark(),
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
      routeInformationProvider: router.routeInformationProvider,
      routeInformationParser: router.routeInformationParser,
      routerDelegate: router.routerDelegate,
      backButtonDispatcher:
          mobileBack?.dispatcher ?? router.backButtonDispatcher,
      onNavigationNotification: mobileBack == null
          ? null
          : (notification) =>
                mobileBack.updatePlatformBackState(notification.canHandlePop),
      // Zoom the router and PIN gate together; OS text scaling stays independent.
      builder: (context, child) => InterfaceScale(
        scale: ref.watch(interfaceScaleProvider),
        child: MemberGateOverlay(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
