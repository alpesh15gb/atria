import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../navigation/nav_destinations.dart';
import '../state/providers.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/expenses/expense_editor_screen.dart';
import '../../features/expenses/expenses_screen.dart';
import '../../features/items/item_editor_screen.dart';
import '../../features/items/items_screen.dart';
import '../../features/onboarding/firm_setup_screen.dart';
import '../../features/onboarding/onboarding_screen.dart';
import '../../features/payments/payments_screen.dart';
import '../../features/parties/party_editor_screen.dart';
import '../../features/parties/party_statement_screen.dart';
import '../../features/parties/parties_screen.dart';
import '../../features/purchase/purchase_editor_screen.dart';
import '../../features/purchase/purchase_list_screen.dart';
import '../../features/recycle_bin/recycle_bin_screen.dart';
import '../../features/reports/gst_reports_screen.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/sales/payment_reminders_screen.dart';
import '../../features/sales/sale_detail_screen.dart';
import '../../features/sales/sale_editor_screen.dart';
import '../../features/sales/sales_list_screen.dart';
import '../../features/settings/backup_restore_screen.dart';
import '../../features/settings/firm_settings_screen.dart';
import '../../features/settings/period_lock_and_audit_screens.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/stock/stock_screen.dart';
import '../../shared/widgets/adaptive_nav_shell.dart';

/// Parked here while the persisted onboarding flag and active firm are still
/// loading. It lives INSIDE the app's one and only router (rather than a
/// second, splash-only router swapped in by [AtriaApp]) because on Android the
/// engine can re-deliver the last route — e.g. `/onboarding/firm-setup` after
/// a process death — as the platform's default route at launch. A splash-only
/// router could not match that location and had no errorBuilder, so go_router
/// rendered its default "The route /onboarding/firm-setup does not exist"
/// page. With a single router, any relaunch location is matched by [BootRoute]
/// first and handed a splash, then the redirect forwards it once the flags
/// have loaded.
final bootRoute = '/boot';

final appRouterProvider = Provider<GoRouter>((ref) {
  // The redirect must re-run when the boot gate opens, but the router itself
  // must NEVER be rebuilt (a fresh GoRouter mid-flight would drop navigation
  // state — the bug this router was rebuilt to fix). So instead of watching
  // the gate here, listen to it and pulse a listenable go_router understands:
  // refreshListenable makes it re-evaluate the redirect in place.
  final refresh = ValueNotifier<int>(0);
  ref.onDispose(refresh.dispose);
  ref.listen<void>(appInitializationProvider, (_, _) => refresh.value++);

  // Where the platform asked to launch before we parked it on the splash.
  // Remembering it lets the redirect RESUME that route once the books have
  // opened — discarding it sent a relaunch into firm setup back to the start
  // of onboarding instead.
  String? launchLocation;

  return GoRouter(
    initialLocation: bootRoute,
    debugLogDiagnostics: false,
    refreshListenable: refresh,
    redirect: (context, state) {
      final path = state.matchedLocation;

      // Keep everything parked on the splash until the persisted onboarding
      // flag and active firm have loaded; the redirect must never decide on
      // cold-start defaults. `hasValue` is false both while loading and after
      // a failure — a failed load keeps the user here, where [BootRoute]
      // renders the recovery screen instead of a spinner.
      if (!ref.read(appInitializationProvider).hasValue) {
        launchLocation ??= path == bootRoute ? null : path;
        return path == bootRoute ? null : bootRoute;
      }

      // The gate has opened while parked on the splash. If the platform had
      // asked for a specific route, resume it (passing it through the
      // onboarding rules); otherwise treat the launch as a plain start and
      // aim for the dashboard — a ready user resolves to `null` there,
      // meaning "stay", which would strand them on the splash.
      if (path == bootRoute) {
        final resume = launchLocation;
        launchLocation = null;
        if (resume != null) {
          return resolveOnboardingRedirect(
                onboardingDone: ref.read(onboardingDoneProvider),
                activeFirmId: ref.read(activeFirmIdProvider),
                path: resume,
              ) ??
              resume;
        }
        return resolveOnboardingRedirect(
              onboardingDone: ref.read(onboardingDoneProvider),
              activeFirmId: ref.read(activeFirmIdProvider),
              path: '/dashboard',
            ) ??
            '/dashboard';
      }

      return resolveOnboardingRedirect(
        onboardingDone: ref.read(onboardingDoneProvider),
        activeFirmId: ref.read(activeFirmIdProvider),
        path: path,
      );
    },
    routes: [
      GoRoute(
        path: bootRoute,
        name: 'boot',
        builder: (context, state) => const BootRoute(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/onboarding/firm-setup',
        builder: (context, state) => const FirmSetupScreen(),
      ),
      GoRoute(
        path: '/payment-reminders',
        builder: (context, state) => const PaymentRemindersScreen(),
      ),
      StatefulShellRoute.indexedStack(
        // The shell must mount `navigationShell` — that widget hosts the
        // per-branch navigators, i.e. every list screen AND the editor/detail
        // routes pushed on top of them. Handing AdaptiveNavShell a hand-built
        // list of const screens instead rendered only the list tabs and made
        // every "New invoice / Add item / Add party" push invisible.
        builder: (context, state, navigationShell) {
          return AdaptiveNavShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/dashboard',
              builder: (context, state) => const DashboardScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/sales',
              builder: (context, state) => const SalesListScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => SaleEditorScreen(
                    docType: state.uri.queryParameters['type'] ?? 'invoice',
                    // ?from=<id> seeds a new invoice from a quotation or
                    // sales order — the convert flow.
                    convertFromId: state.uri.queryParameters['from'],
                    // ?party=<id> preselects the customer (Parties pane's
                    // "New invoice" affordance).
                    presetPartyId: state.uri.queryParameters['party'],
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => SaleEditorScreen(
                    docType: state.uri.queryParameters['type'] ?? 'invoice',
                    editId: state.pathParameters['id'],
                  ),
                ),
                GoRoute(
                  path: 'detail/:id',
                  builder: (context, state) =>
                      SaleDetailScreen(id: state.pathParameters['id']!),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/items',
              builder: (context, state) => const ItemsScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => ItemEditorScreen(
                    // ?from=<id> pre-fills the form from an existing item —
                    // the duplicate flow.
                    duplicateOfId: state.uri.queryParameters['from'],
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => ItemEditorScreen(
                    editId: state.pathParameters['id']!,
                  ),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/parties',
              builder: (context, state) => const PartiesScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  // `type` preselects the party type — the purchase editor's
                  // "Add new supplier" used to land on a customer form.
                  builder: (context, state) => PartyEditorScreen(
                    initialType: state.uri.queryParameters['type'],
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => PartyEditorScreen(
                    editId: state.pathParameters['id']!,
                  ),
                ),
                GoRoute(
                  path: 'statement/:id',
                  builder: (context, state) => PartyStatementScreen(
                    partyId: state.pathParameters['id']!,
                  ),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/reports',
              builder: (context, state) => const ReportsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/purchase',
              builder: (context, state) => const PurchaseListScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  builder: (context, state) => PurchaseEditorScreen(
                    // ?type=debit_note creates a purchase return.
                    docType: state.uri.queryParameters['type'] ?? 'bill',
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => PurchaseEditorScreen(
                    editId: state.pathParameters['id']!,
                    docType: state.uri.queryParameters['type'] ?? 'bill',
                  ),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/payments',
              builder: (context, state) => const PaymentsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/expenses',
              builder: (context, state) => const ExpensesScreen(),
              routes: [
                GoRoute(
                  path: 'new',
                  // The Expenses tab and the Other Income tab share this one
                  // editor; the type decides which categories and labels it
                  // shows. Without it, "Add Income" silently created an
                  // expense in the default category.
                  builder: (context, state) => ExpenseEditorScreen(
                    type: state.uri.queryParameters['type'] ?? 'expense',
                  ),
                ),
                GoRoute(
                  path: 'edit/:id',
                  builder: (context, state) => ExpenseEditorScreen(
                    type: state.uri.queryParameters['type'] ?? 'expense',
                    editId: state.pathParameters['id'],
                  ),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/stock',
              builder: (context, state) => const StockScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/gst-reports',
              builder: (context, state) => const GstReportsScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
              routes: [
                GoRoute(
                  path: 'firm',
                  builder: (context, state) => const FirmSettingsScreen(),
                ),
                GoRoute(
                  path: 'backup',
                  builder: (context, state) => const BackupRestoreScreen(),
                ),
                GoRoute(
                  path: 'recycle-bin',
                  builder: (context, state) => const RecycleBinScreen(),
                ),
                GoRoute(
                  path: 'period-lock',
                  builder: (context, state) => const PeriodLockScreen(),
                ),
                GoRoute(
                  path: 'audit-log',
                  builder: (context, state) => const AuditLogScreen(),
                ),
              ],
            ),
          ]),
        ],
      ),
    ],
    errorBuilder: (context, state) => _RouteNotFound(location: state.error),
  );
});

/// Decides where a navigation should really land, given the two flags that
/// gate first-run.
///
/// Extracted from the router so it can be unit-tested directly — building the
/// real screens in a widget test to observe a redirect is far too slow to be
/// a useful regression guard. Both flags are synchronous state (see
/// [OnboardingController] and [ActiveFirmController]); a [FutureProvider] here
/// would resolve once, stay cached, and keep showing a stale value after the
/// flag was written — which is why "Get Started" and "Skip" used to do
/// nothing.
String? resolveOnboardingRedirect({
  required bool onboardingDone,
  required String? activeFirmId,
  required String path,
}) {
  final isOnboarding =
      path == '/onboarding' || path == '/onboarding/firm-setup';

  if (!onboardingDone) {
    return isOnboarding ? null : '/onboarding';
  }
  if (activeFirmId == null && !isOnboarding) {
    return '/onboarding/firm-setup';
  }
  // The welcome pages are a dead end once onboarding is complete, but
  // firm-setup is NOT: it doubles as the "Add another business" screen in
  // Settings, which a user with a firm opens deliberately. Redirecting it
  // away made that button bounce straight back to the dashboard — forever
  // appearing to do nothing.
  if (path == '/onboarding') {
    return '/dashboard';
  }
  return null;
}

/// Convenience: the number of shell branches, kept in sync with the
/// destination list so the "More" sheet can map to the right branch.
final navBranchCountProvider = Provider<int>((ref) {
  return NavDestinations.all.length;
});

/// Shown while the app's books are still opening — or, when opening them
/// failed, the recovery screen instead of a spinner.
class BootRoute extends ConsumerWidget {
  const BootRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initialization = ref.watch(appInitializationProvider);
    // A failed load has no route to show; report it here rather than leaving
    // the user on a spinner that can never resolve.
    if (initialization.hasError) {
      return _BootFailure(error: initialization.error!);
    }
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

/// The app's only route-not-found screen. Every location is matched against
/// real routes, so reaching this page means a genuinely bad link or push —
/// it offers a way back to the dashboard instead of a dead end.
class _RouteNotFound extends ConsumerWidget {
  const _RouteNotFound({required this.location});

  final Exception? location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.location_off_rounded,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'That page does not exist',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                '$location',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.go('/dashboard'),
                icon: const Icon(Icons.dashboard_rounded),
                label: const Text('Go to dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown when the books cannot be opened at all — a corrupt or locked
/// database. Offers a retry, which rebuilds the controllers from scratch: the
/// failure may be transient (another instance holding the file), and even when
/// it is not, the user deserves to know the app is not hanging.
class _BootFailure extends ConsumerWidget {
  const _BootFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off_rounded,
                  size: 48,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Could not open your books',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Atria stores everything on this device and the book file '
                  'would not open. Another copy of Atria may be running, or '
                  'the file may be damaged.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () {
                    // Rebuild the controllers so their init runs again against
                    // a possibly-recovered database; re-awaits in the provider
                    // would otherwise replay an already-failed future.
                    ref.invalidate(onboardingDoneProvider);
                    ref.invalidate(activeFirmIdProvider);
                    ref.invalidate(appInitializationProvider);
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
