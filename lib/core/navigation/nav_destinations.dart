import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// A single top-level destination in the app shell.
class NavDestination {
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final String routePath;

  const NavDestination({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.routePath,
  });
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
