import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/responsive/platform_ui.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import 'atria_create_menu.dart';

/// The mobile **Create** tile grid — the reference's first row of the dashboard.
///
/// A four-across grid of icon tiles, each a rounded square glyph over its label.
/// Desktop has no equivalent and does not want one: there the create actions
/// live in the chrome and in the rail menu, and a tile grid on a 1920px window
/// is a strip of icons with nothing under them.
///
/// **The order and the set are spelled out, not taken from the head of
/// [atriaCreateActions].** The desktop order is QuickBooks' — every sales
/// document, then money, then purchases — and slicing the first eight off it
/// would give a phone a grid with no Bill in it. The reference's phone grid is
/// invoice, purchase, quotation, expenses / delivery challan, credit note, sales
/// order, and then the masters. A grid a shopkeeper cannot file a purchase from
/// is not the reference's grid, so the list is written down rather than derived.
///
/// **No "Upload with SwipeAI" tile, no plan badge.** The reference carries a
/// magenta OCR upload affordance beside its `Create` heading; that advertises a
/// product Apex does not have and is not being built, so the grid carries only
/// documents the app can actually create.
class MobileCreateGrid extends StatelessWidget {
  const MobileCreateGrid({super.key, this.heading = 'Create'});

  /// `Create` in the reference. [MobileQuickAccessGrid] supplies its own.
  final String heading;

  /// The tiles, in the reference's order.
  ///
  /// Built from route and icon rather than looked up in [atriaCreateActions],
  /// because the labels are **the phone's words**: the reference says "Purchase"
  /// where the desktop menu says "Bill", and a tile reading "Bill" on a shop
  /// floor is a word the person using it has to translate.
  static const List<({String label, String route, IconData icon, String group})>
      tiles = [
    (
      label: 'Invoice',
      route: '/sales/new?type=invoice',
      icon: PhosphorIconsRegular.receipt,
      group: 'Sales'
    ),
    (
      label: 'Purchase',
      route: '/purchase/new?type=bill',
      icon: PhosphorIconsRegular.shoppingCart,
      group: 'Purchases'
    ),
    (
      label: 'Quotation',
      route: '/sales/new?type=quotation',
      icon: PhosphorIconsRegular.fileText,
      group: 'Sales'
    ),
    (
      label: 'Expenses',
      route: '/expenses/new?type=expense',
      icon: PhosphorIconsRegular.money,
      group: 'Money'
    ),
    (
      label: 'Delivery\nChellan',
      route: '/sales/new?type=delivery_note',
      icon: PhosphorIconsRegular.truck,
      group: 'Sales'
    ),
    (
      label: 'Credit Note',
      route: '/sales/new?type=credit_note',
      icon: PhosphorIconsRegular.arrowUUpLeft,
      group: 'Sales'
    ),
    (
      label: 'Sales Order',
      route: '/sales/new?type=sales_order',
      icon: PhosphorIconsRegular.clipboardText,
      group: 'Sales'
    ),
    (
      label: 'Payment\nReceived',
      route: '/payments',
      icon: PhosphorIconsRegular.arrowsLeftRight,
      group: 'Money'
    ),
    (
      label: 'Products',
      route: '/items/new',
      icon: PhosphorIconsRegular.cube,
      group: 'Masters'
    ),
    (
      label: 'Customers',
      route: '/parties/new?type=customer',
      icon: PhosphorIconsRegular.userSquare,
      group: 'Masters'
    ),
    (
      label: 'Vendors',
      route: '/parties/new?type=supplier',
      icon: PhosphorIconsRegular.userSquare,
      group: 'Masters'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // Nothing at all off-mobile, heading included: a bare "Create" over an
    // empty grid is a label on the wrong platform, which is worse than
    // rendering nothing.
    if (!Theme.of(context).platform.isMobileUi) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            heading,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        _TileGrid(
          entries: [
            for (final tile in tiles)
              AtriaCreateAction(
                label: tile.label,
                route: tile.route,
                icon: tile.icon,
                group: tile.group,
              ),
          ],
        ),
      ],
    );
  }
}

/// The tile grid itself, shared by `Create` and `Quick Access`.
class _TileGrid extends StatelessWidget {
  const _TileGrid({required this.entries});

  final List<AtriaCreateAction> entries;

  /// Four across, as in the reference.
  ///
  /// Four is what fits a 360dp phone with each tile still ~80dp wide, which is
  /// the smallest a label like "Delivery challan" can wrap under without
  /// becoming three lines.
  static const int columns = 4;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: AppRadius.lgAll,
      ),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: entries.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: 14,
          crossAxisSpacing: 2,
          // Tall enough for the glyph plus a two-line label. The reference's
          // labels wrap ("Delivery Challan") and a fixed square crops them.
          childAspectRatio: 0.92,
        ),
        itemBuilder: (context, index) {
          final entry = entries[index];
          return _CreateTile(action: entry);
        },
      ),
    );
  }
}

/// One icon-over-label tile.
class _CreateTile extends StatelessWidget {
  const _CreateTile({required this.action});

  final AtriaCreateAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      // `go`, not `push`: the shell's branches own navigation, and an
      // imperative push from inside one hosts the editor on the root navigator,
      // which is the bug `nav_shell_regression_test.dart` guards.
      onTap: () => context.go(action.route),
      borderRadius: AppRadius.mdAll,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: AppRadius.mdAll,
            ),
            child: Icon(
              action.icon,
              // [AppIconSize.xl], the largest on the scale. A bare 24 — the
              // Material default for a tile like this — would be the one
              // off-scale number in the file, and the scale exists so a widget
              // cannot silently invent its own.
              size: AppIconSize.xl,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            action.label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}

/// The mobile **Quick Access** grid.
///
/// A second four-across grid, under its own heading, for the destinations a shop
/// visits constantly. Deliberately built from the same tile as `Create` — the
/// reference draws the two identically, and one tile widget that both use cannot
/// drift apart the way two copies do.
class MobileQuickAccessGrid extends StatelessWidget {
  const MobileQuickAccessGrid({super.key, required this.entries});

  /// Each entry is a route plus its glyph and label.
  final List<({String route, String label, IconData icon})> entries;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
          child: Text(
            'Quick Access',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        _TileGrid(
          entries: [
            for (final entry in entries)
              AtriaCreateAction(
                label: entry.label,
                route: entry.route,
                icon: entry.icon,
              ),
          ],
        ),
      ],
    );
  }
}