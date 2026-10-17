import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/responsive/platform_ui.dart';
import 'atria_create_menu.dart';

/// Mobile creation shortcuts using the supplied Stitch action-card pattern.
/// The remaining supported workflows stay available in More actions.
class MobileCreateGrid extends StatelessWidget {
  const MobileCreateGrid({super.key, this.heading = 'Quick Actions'});

  /// Section heading for the supported document shortcuts.
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
      group: 'Sales',
    ),
    (
      label: 'Purchase',
      route: '/purchase/new?type=bill',
      icon: PhosphorIconsRegular.shoppingCart,
      group: 'Purchases',
    ),
    (
      label: 'Quotation',
      route: '/sales/new?type=quotation',
      icon: PhosphorIconsRegular.fileText,
      group: 'Sales',
    ),
    (
      label: 'Expenses',
      route: '/expenses/new?type=expense',
      icon: PhosphorIconsRegular.money,
      group: 'Money',
    ),
    (
      label: 'Delivery\nChallan',
      route: '/sales/new?type=delivery_note',
      icon: PhosphorIconsRegular.truck,
      group: 'Sales',
    ),
    (
      label: 'Credit Note',
      route: '/sales/new?type=credit_note',
      icon: PhosphorIconsRegular.arrowUUpLeft,
      group: 'Sales',
    ),
    (
      label: 'Sales Order',
      route: '/sales/new?type=sales_order',
      icon: PhosphorIconsRegular.clipboardText,
      group: 'Sales',
    ),
    (
      label: 'Payment\nReceived',
      route: '/payments',
      icon: PhosphorIconsRegular.arrowsLeftRight,
      group: 'Money',
    ),
    (
      label: 'Products',
      route: '/items/new',
      icon: PhosphorIconsRegular.cube,
      group: 'Masters',
    ),
    (
      label: 'Customers',
      route: '/parties/new?type=customer',
      icon: PhosphorIconsRegular.userSquare,
      group: 'Masters',
    ),
    (
      label: 'Vendors',
      route: '/parties/new?type=supplier',
      icon: PhosphorIconsRegular.userSquare,
      group: 'Masters',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    if (!Theme.of(context).platform.isMobileUi) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 300;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final tile in tiles.take(6))
                  SizedBox(
                    width: narrow
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 10) / 2,
                    child: _ActionCard(
                      action: AtriaCreateAction(
                        label: tile.label.replaceAll('\n', ' '),
                        route: tile.route,
                        icon: tile.icon,
                        group: tile.group,
                      ),
                      prominent: tile == tiles.first,
                    ),
                  ),
              ],
            );
          },
        ),
        Align(
          alignment: Alignment.centerRight,
          child: PopupMenuButton<String>(
            tooltip: 'More create actions',
            onSelected: (route) => route.contains('/new')
                ? context.push(route)
                : context.go(route),
            itemBuilder: (_) => [
              for (final tile in tiles.skip(6))
                PopupMenuItem(
                  value: tile.route,
                  child: Text(tile.label.replaceAll('\n', ' ')),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'More actions',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Shared operational action card. Every entry opens a working app route.
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.action,
    this.prominent = false,
    this.destination = false,
  });
  final AtriaCreateAction action;
  final bool prominent, destination;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: prominent ? scheme.primary : scheme.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => action.route.contains('/new')
            ? context.push(action.route)
            : context.go(action.route),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: prominent
                      ? scheme.onPrimary.withValues(alpha: .12)
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  action.icon,
                  size: 21,
                  color: prominent ? scheme.onPrimary : scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: prominent ? scheme.onPrimary : scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (destination)
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileQuickAccessGrid extends StatelessWidget {
  const MobileQuickAccessGrid({super.key, required this.entries});
  final List<({String route, String label, IconData icon})> entries;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Core Modules',
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 12),
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          children: [
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              _ActionCard(
                destination: true,
                action: AtriaCreateAction(
                  label: entries[i].label,
                  route: entries[i].route,
                  icon: entries[i].icon,
                ),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}
