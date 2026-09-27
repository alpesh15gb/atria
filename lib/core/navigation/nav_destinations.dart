import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// A single top-level destination in the app shell.
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

/// The primary destinations. The same list drives the mobile bottom bar and
/// the desktop side rail, so navigation never diverges between platforms.
class NavDestinations {
  NavDestinations._();

  static const List<NavDestination> primary = [
    NavDestination(
      label: 'Dashboard',
      icon: PhosphorIconsRegular.house,
      selectedIcon: PhosphorIconsFill.house,
      routePath: '/dashboard',
    ),
    NavDestination(
      label: 'Sale',
      icon: PhosphorIconsRegular.receipt,
      selectedIcon: PhosphorIconsFill.receipt,
      routePath: '/sales',
      children: [
        NavChild(label: 'Invoices', route: '/sales?type=invoice'),
        NavChild(label: 'Quotations', route: '/sales?type=quotation'),
        NavChild(label: 'Sales Orders', route: '/sales?type=sales_order'),
        NavChild(label: 'Delivery Notes', route: '/sales?type=delivery_note'),
        NavChild(label: 'Credit Notes', route: '/sales?type=credit_note'),
      ],
    ),
    NavDestination(
      label: 'Items',
      icon: PhosphorIconsRegular.cube,
      selectedIcon: PhosphorIconsFill.cube,
      routePath: '/items',
    ),
    NavDestination(
      label: 'Parties',
      icon: PhosphorIconsRegular.users,
      selectedIcon: PhosphorIconsFill.users,
      routePath: '/parties',
    ),
    NavDestination(
      label: 'Reports',
      icon: PhosphorIconsRegular.chartBar,
      selectedIcon: PhosphorIconsFill.chartBar,
      routePath: '/reports',
    ),
  ];

  /// Shown in the extended desktop rail and in the mobile "more" sheet.
  static const List<NavDestination> secondary = [
    NavDestination(
      label: 'Purchase',
      icon: PhosphorIconsRegular.shoppingCart,
      selectedIcon: PhosphorIconsFill.shoppingCart,
      routePath: '/purchase',
      children: [
        NavChild(label: 'Bills', route: '/purchase?type=bill'),
        NavChild(label: 'Debit Notes', route: '/purchase?type=debit_note'),
      ],
    ),
    NavDestination(
      label: 'Statements',
      icon: PhosphorIconsRegular.bookOpen,
      selectedIcon: PhosphorIconsFill.bookOpen,
      routePath: '/statements',
    ),
    NavDestination(
      label: 'Payments',
      icon: PhosphorIconsRegular.arrowsLeftRight,
      selectedIcon: PhosphorIconsFill.arrowsLeftRight,
      routePath: '/payments',
    ),
    NavDestination(
      label: 'Expenses',
      icon: PhosphorIconsRegular.moneyWavy,
      selectedIcon: PhosphorIconsFill.moneyWavy,
      routePath: '/expenses',
    ),
    NavDestination(
      label: 'Stock',
      icon: PhosphorIconsRegular.warehouse,
      selectedIcon: PhosphorIconsFill.warehouse,
      routePath: '/stock',
    ),
    NavDestination(
      label: 'GST Returns',
      icon: PhosphorIconsRegular.clipboardText,
      selectedIcon: PhosphorIconsFill.clipboardText,
      routePath: '/gst-reports',
    ),
    NavDestination(
      label: 'Settings',
      icon: PhosphorIconsRegular.gear,
      selectedIcon: PhosphorIconsFill.gear,
      routePath: '/settings',
    ),
  ];

  static const List<NavDestination> all = [...primary, ...secondary];

  /// Index used by the bottom bar (mobile) — "More" is the last slot.
  static int get bottomBarItemCount => primary.length;

  /// No '/more' route exists — the More slot opens the bottom sheet in
  /// AdaptiveNavShell. Never navigate to this constant.
  static const String moreRoutePath = '/more';
}
