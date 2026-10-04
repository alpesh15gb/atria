import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../domain/member_role.dart';

/// A single top-level destination in the app shell — one per router branch.
class NavDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String routePath;

  /// Sub-entries shown in the rail's expandable dropdown, e.g. the document
  /// types under Sales. Each is a deep link (`/sales?type=quotation`) — the
  /// tabs moved off the screens themselves so list area isn't wasted.
  final List<NavChild> children;

  const NavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.routePath,
    this.children = const [],
  });

  bool get hasChildren => children.isNotEmpty;
}

/// One entry in a destination's expandable dropdown.
class NavChild {
  final String label;
  final String route;

  const NavChild({required this.label, required this.route});
}

/// One row of the left navigation, as QuickBooks Online lays it out: a
/// labelled section (`SALES`, `EXPENSES`, `REPORTS`, `TAXES`, `SETTINGS`)
/// whose body lists every page in that area.
///
/// A row is either a **branch root** — [branchIndex] is set, and tapping it
/// switches shell branch so per-branch navigation state is preserved — or a
/// **deep link** ([route] with a query such as `/sales?type=quotation`), which
/// is pushed onto the current branch because a branch switch cannot carry a
/// query string.
class NavSectionEntry {
  final String label;
  final IconData icon;
  final String route;

  /// Index into [NavDestinations.all] when this row is a branch root.
  final int? branchIndex;

  /// The permission a member must hold to see this destination.
  ///
  /// Null means everyone, which is every destination the app shipped before
  /// local users existed. **Null must stay null on those**, because with the
  /// feature off every session grants everything anyway — the filter only does
  /// anything when a firm has opted in.
  final Permission? requiresPermission;

  const NavSectionEntry({
    required this.label,
    required this.icon,
    required this.route,
    this.branchIndex,
    this.requiresPermission,
  });
}

/// A titled group of [NavSectionEntry] rows.
class NavSection {
  final String title;
  final List<NavSectionEntry> entries;

  /// The rows this member may see.
  ///
  /// One filter, applied by every consumer of [entries] — the rail, the
  /// compact list and global search — because a destination hidden in two
  /// places and visible in the third is not a hidden destination. Each row's
  /// route is *also* redirected in `app_router`, since hiding a row is only a
  /// courtesy and the deep link is the real door.
  List<NavSectionEntry> visibleTo(MemberSession session) => entries
      .where(
        (e) =>
            e.requiresPermission == null ||
            session.allows(e.requiresPermission!),
      )
      .toList(growable: false);

  const NavSection({required this.title, required this.entries});
}

/// The primary destinations. The same list drives the mobile bottom bar and
/// the desktop side rail, so navigation never diverges between platforms.
///
/// **Order is load-bearing.** [all] indexes are the
/// `StatefulShellRoute.indexedStack` branch indexes declared in
/// `app_router.dart`, and the mobile bottom bar treats the first
/// [bottomBarItemCount] entries as its slots — so entries may be *relabelled*
/// freely, but never reordered without reordering the router branches too.
class NavDestinations {
  NavDestinations._();

  static const NavDestination dashboard = NavDestination(
    label: 'Dashboard',
    icon: PhosphorIconsRegular.house,
    selectedIcon: PhosphorIconsFill.house,
    routePath: '/dashboard',
  );

  static const NavDestination sales = NavDestination(
    label: 'Sales',
    icon: PhosphorIconsRegular.receipt,
    selectedIcon: PhosphorIconsFill.receipt,
    routePath: '/sales',
    children: [
      NavChild(label: 'Invoices', route: '/sales?type=invoice'),
      NavChild(label: 'Quotations', route: '/sales?type=quotation'),
      NavChild(label: 'Sales orders', route: '/sales?type=sales_order'),
      NavChild(label: 'Delivery notes', route: '/sales?type=delivery_note'),
      NavChild(label: 'Credit notes', route: '/sales?type=credit_note'),
    ],
  );

  static const NavDestination items = NavDestination(
    label: 'Items',
    icon: PhosphorIconsRegular.cube,
    selectedIcon: PhosphorIconsFill.cube,
    routePath: '/items',
  );

  static const NavDestination parties = NavDestination(
    label: 'Parties',
    icon: PhosphorIconsRegular.users,
    selectedIcon: PhosphorIconsFill.users,
    routePath: '/parties',
  );

  static const NavDestination reports = NavDestination(
    label: 'Reports',
    icon: PhosphorIconsRegular.chartBar,
    selectedIcon: PhosphorIconsFill.chartBar,
    routePath: '/reports',
  );

  static const NavDestination purchase = NavDestination(
    label: 'Purchase',
    icon: PhosphorIconsRegular.shoppingCart,
    selectedIcon: PhosphorIconsFill.shoppingCart,
    routePath: '/purchase',
    children: [
      NavChild(label: 'Bills', route: '/purchase?type=bill'),
      NavChild(
        label: 'Purchase orders',
        route: '/purchase?type=purchase_order',
      ),
      NavChild(label: 'Debit notes', route: '/purchase?type=debit_note'),
    ],
  );

  static const NavDestination statements = NavDestination(
    label: 'Statements',
    icon: PhosphorIconsRegular.bookOpen,
    selectedIcon: PhosphorIconsFill.bookOpen,
    routePath: '/statements',
  );

  static const NavDestination payments = NavDestination(
    label: 'Payments',
    icon: PhosphorIconsRegular.arrowsLeftRight,
    selectedIcon: PhosphorIconsFill.arrowsLeftRight,
    routePath: '/payments',
  );

  static const NavDestination expenses = NavDestination(
    label: 'Expenses',
    icon: PhosphorIconsRegular.moneyWavy,
    selectedIcon: PhosphorIconsFill.moneyWavy,
    routePath: '/expenses',
  );

  static const NavDestination stock = NavDestination(
    label: 'Stock',
    icon: PhosphorIconsRegular.warehouse,
    selectedIcon: PhosphorIconsFill.warehouse,
    routePath: '/stock',
  );

  static const NavDestination gstReturns = NavDestination(
    label: 'GST returns',
    icon: PhosphorIconsRegular.clipboardText,
    selectedIcon: PhosphorIconsFill.clipboardText,
    routePath: '/gst-reports',
  );

  static const NavDestination settings = NavDestination(
    label: 'Settings',
    icon: PhosphorIconsRegular.gear,
    selectedIcon: PhosphorIconsFill.gear,
    routePath: '/settings',
  );

  /// The double-entry side: the chart of accounts, journal vouchers and the
  /// reports that prove the books agree. Appended last so every existing
  /// branch index — and the mobile bottom bar's five slots — keeps its meaning.
  static const NavDestination ledger = NavDestination(
    label: 'Ledger',
    icon: PhosphorIconsRegular.books,
    selectedIcon: PhosphorIconsFill.books,
    routePath: '/ledger',
    children: [
      NavChild(label: 'Journal entries', route: '/ledger/journals'),
      NavChild(label: 'Trial balance', route: '/ledger/trial-balance'),
      NavChild(label: 'Balance sheet', route: '/ledger/balance-sheet'),
    ],
  );

  /// Every branch, in router order.
  static const List<NavDestination> branches = [
    dashboard,
    sales,
    items,
    parties,
    reports,
    purchase,
    statements,
    payments,
    expenses,
    stock,
    gstReturns,
    settings,
    ledger,
  ];

  /// Kept for the shell and tests: the full branch list in branch order.
  static const List<NavDestination> all = branches;

  /// Branch index of a destination (router branch order).
  static int indexOf(NavDestination destination) =>
      branches.indexOf(destination);

  /// Destinations on the mobile bottom bar (the rest fold into "More").
  static List<NavDestination> get primary =>
      branches.sublist(0, bottomBarItemCount);

  /// Everything the mobile bottom bar pushes into its "More" sheet.
  static List<NavDestination> get secondary =>
      branches.sublist(bottomBarItemCount);

  /// Index used by the bottom bar (mobile) — "More" is the last slot.
  static int get bottomBarItemCount => 5;

  /// The desktop rail, grouped exactly the way QuickBooks Online groups its
  /// left navigation: the summary page first, then the two money flows
  /// (get paid / pay), then the read-only areas, then setup.
  static const List<NavSection> sections = [
    NavSection(
      title: 'MAIN',
      entries: [
        NavSectionEntry(
          label: 'Dashboard',
          icon: PhosphorIconsRegular.house,
          route: '/dashboard',
          branchIndex: 0,
        ),
      ],
    ),
    NavSection(
      title: 'SALES',
      entries: [
        NavSectionEntry(
          label: 'Counter sale (POS)',
          icon: PhosphorIconsRegular.barcode,
          route: '/pos',
        ),
        NavSectionEntry(
          label: 'Invoices',
          icon: PhosphorIconsRegular.receipt,
          route: '/sales?type=invoice',
        ),
        NavSectionEntry(
          label: 'Quotations',
          icon: PhosphorIconsRegular.fileText,
          route: '/sales?type=quotation',
        ),
        NavSectionEntry(
          label: 'Sales orders',
          icon: PhosphorIconsRegular.clipboardText,
          route: '/sales?type=sales_order',
        ),
        NavSectionEntry(
          label: 'Delivery notes',
          icon: PhosphorIconsRegular.truck,
          route: '/sales?type=delivery_note',
        ),
        NavSectionEntry(
          label: 'Credit notes',
          icon: PhosphorIconsRegular.arrowUUpLeft,
          route: '/sales?type=credit_note',
        ),
        NavSectionEntry(
          label: 'Payments received',
          icon: PhosphorIconsRegular.arrowsLeftRight,
          route: '/payments',
          branchIndex: 7,
        ),
        // No `branchIndex`, deliberately: `/payment-reminders` is a root-level
        // route OUTSIDE the nav shell (`app_router.dart` puts it beside `/pos`),
        // so there is no branch to switch to. Listing it here also puts it in
        // the global search panel's "Go to" list, which is built from these
        // sections — until now the only way in was a chip on the dashboard, so
        // the screen was unreachable from the rail and from search.
        NavSectionEntry(
          label: 'Payment reminders',
          icon: PhosphorIconsRegular.bellRinging,
          route: '/payment-reminders',
        ),
        NavSectionEntry(
          label: 'Products and services',
          icon: PhosphorIconsRegular.cube,
          route: '/items',
          branchIndex: 2,
        ),
        NavSectionEntry(
          label: 'Customers',
          icon: PhosphorIconsRegular.users,
          route: '/parties?type=customer',
        ),
      ],
    ),
    NavSection(
      title: 'EXPENSES',
      entries: [
        NavSectionEntry(
          label: 'Bills',
          icon: PhosphorIconsRegular.shoppingCart,
          route: '/purchase?type=bill',
        ),
        NavSectionEntry(
          label: 'Purchase orders',
          icon: PhosphorIconsRegular.clipboardText,
          route: '/purchase?type=purchase_order',
        ),
        NavSectionEntry(
          label: 'Debit notes',
          icon: PhosphorIconsRegular.arrowUDownLeft,
          route: '/purchase?type=debit_note',
        ),
        NavSectionEntry(
          label: 'Expenses',
          icon: PhosphorIconsRegular.moneyWavy,
          route: '/expenses',
          branchIndex: 8,
        ),
        NavSectionEntry(
          label: 'Vendors',
          icon: PhosphorIconsRegular.storefront,
          route: '/parties?type=supplier',
        ),
      ],
    ),
    NavSection(
      title: 'REPORTS',
      entries: [
        NavSectionEntry(
          label: 'Reports',
          icon: PhosphorIconsRegular.chartBar,
          route: '/reports',
          branchIndex: 4,
        ),
        NavSectionEntry(
          label: 'Statements of account',
          icon: PhosphorIconsRegular.bookOpen,
          route: '/statements',
          branchIndex: 6,
        ),
        NavSectionEntry(
          label: 'Stock summary',
          icon: PhosphorIconsRegular.warehouse,
          route: '/stock',
          branchIndex: 9,
        ),
        // Trial balance and Balance sheet deliberately do NOT appear here.
        // They used to be listed in both REPORTS and ACCOUNTING, which put two
        // identical, indistinguishable icon pairs in the icon rail and lit both
        // copies at once. They belong with the rest of the ledger in
        // ACCOUNTING.
      ],
    ),
    NavSection(
      title: 'ACCOUNTING',
      entries: [
        NavSectionEntry(
          label: 'Chart of accounts',
          icon: PhosphorIconsRegular.treeStructure,
          route: '/ledger',
          branchIndex: 12,
        ),
        NavSectionEntry(
          label: 'Journal entries',
          icon: PhosphorIconsRegular.notebook,
          route: '/ledger/journals',
          branchIndex: 12,
        ),
        NavSectionEntry(
          label: 'Trial balance',
          icon: PhosphorIconsRegular.scales,
          route: '/ledger/trial-balance',
          branchIndex: 12,
        ),
        NavSectionEntry(
          label: 'Balance sheet',
          icon: PhosphorIconsRegular.books,
          route: '/ledger/balance-sheet',
          branchIndex: 12,
        ),
      ],
    ),
    NavSection(
      title: 'TAXES',
      entries: [
        NavSectionEntry(
          label: 'GST returns',
          icon: PhosphorIconsRegular.clipboardText,
          route: '/gst-reports',
          branchIndex: 10,
        ),
      ],
    ),
    NavSection(
      title: 'SETTINGS',
      entries: [
        NavSectionEntry(
          label: 'Settings',
          icon: PhosphorIconsRegular.gear,
          route: '/settings',
          branchIndex: 11,
        ),
        NavSectionEntry(
          label: 'Label printers',
          icon: PhosphorIconsRegular.printer,
          route: '/settings/printers',
        ),
        NavSectionEntry(
          label: 'Company profile',
          icon: PhosphorIconsRegular.building,
          route: '/settings/firm',
        ),
        NavSectionEntry(
          label: 'Data and backup',
          icon: PhosphorIconsRegular.database,
          route: '/settings/backup',
        ),
        NavSectionEntry(
          label: 'Recycle bin',
          icon: PhosphorIconsRegular.trash,
          route: '/settings/recycle-bin',
          // Hidden for a role that cannot use it. Hiding is a courtesy, not the
          // control — `app_router` redirects these three routes, so the deep
          // link is closed too. The two have to agree: showing a destination
          // that redirects away looks broken, and hiding one that can be
          // reached leaves the restriction one tap of a URL away.
          requiresPermission: Permission.purge,
        ),
        NavSectionEntry(
          label: 'Period lock',
          icon: PhosphorIconsRegular.lockSimple,
          route: '/settings/period-lock',
          requiresPermission: Permission.managePeriodLock,
        ),
        NavSectionEntry(
          label: 'Members',
          icon: PhosphorIconsRegular.users,
          route: '/settings/members',
          requiresPermission: Permission.manageMasters,
        ),
        NavSectionEntry(
          label: 'Audit log',
          icon: PhosphorIconsRegular.clockCounterClockwise,
          route: '/settings/audit-log',
        ),
      ],
    ),
  ];

  /// No '/more' route exists — the More slot opens the bottom sheet in
  /// AdaptiveNavShell. Never navigate to this constant.
  static const String moreRoutePath = '/more';
}
