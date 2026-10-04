import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';

/// One entry in [AtriaCreateButton]'s menu.
///
/// QuickBooks puts every "new …" action behind a single green **Create**
/// button in the top-left of the chrome, and that is the only create
/// affordance on the page — there is no tile strip and no FAB. Keeping the
/// list in one place means the rail, the dashboard and any future header all
/// offer the identical vocabulary in the identical order.
class AtriaCreateAction {
  const AtriaCreateAction({
    required this.label,
    required this.route,
    required this.icon,
    this.group = '',
  });

  final String label;
  final String route;
  final IconData icon;

  /// Optional menu grouping heading (`'', 'Sales', 'Purchases'`). Empty groups
  /// render without a heading.
  final String group;
}

/// New-document order: sell first, then get paid, then spend — the order
/// QuickBooks lists them in.
const List<AtriaCreateAction> atriaCreateActions = [
  AtriaCreateAction(
    label: 'Invoice',
    route: '/sales/new?type=invoice',
    icon: PhosphorIconsRegular.receipt,
    group: 'Sales',
  ),
  AtriaCreateAction(
    label: 'Quotation',
    route: '/sales/new?type=quotation',
    icon: PhosphorIconsRegular.fileText,
    group: 'Sales',
  ),
  AtriaCreateAction(
    label: 'Sales order',
    route: '/sales/new?type=sales_order',
    icon: PhosphorIconsRegular.clipboardText,
    group: 'Sales',
  ),
  AtriaCreateAction(
    label: 'Delivery note',
    route: '/sales/new?type=delivery_note',
    icon: PhosphorIconsRegular.truck,
    group: 'Sales',
  ),
  AtriaCreateAction(
    label: 'Credit note',
    route: '/sales/new?type=credit_note',
    icon: PhosphorIconsRegular.arrowUUpLeft,
    group: 'Sales',
  ),
  AtriaCreateAction(
    label: 'Payment received',
    route: '/payments',
    icon: PhosphorIconsRegular.arrowsLeftRight,
    group: 'Money',
  ),
  AtriaCreateAction(
    label: 'Expense',
    route: '/expenses/new?type=expense',
    icon: PhosphorIconsRegular.moneyWavy,
    group: 'Money',
  ),
  AtriaCreateAction(
    label: 'Bill',
    route: '/purchase/new?type=bill',
    icon: PhosphorIconsRegular.shoppingCart,
    group: 'Purchases',
  ),
  AtriaCreateAction(
    label: 'Debit note',
    route: '/purchase/new?type=debit_note',
    icon: PhosphorIconsRegular.arrowUDownLeft,
    group: 'Purchases',
  ),
  AtriaCreateAction(
    label: 'Product or service',
    route: '/items/new',
    icon: PhosphorIconsRegular.cube,
    group: 'Lists',
  ),
  AtriaCreateAction(
    label: 'Customer',
    route: '/parties/new?type=customer',
    icon: PhosphorIconsRegular.users,
    group: 'Lists',
  ),
  AtriaCreateAction(
    label: 'Vendor',
    route: '/parties/new?type=supplier',
    icon: PhosphorIconsRegular.storefront,
    group: 'Lists',
  ),
];

/// The chrome's green **Create** button and its menu.
///
/// [expanded] renders the wide label (`＋ Create ▾`) for the extended rail and
/// the dashboard header; the collapsed form is a square `＋` for the icon rail.
class AtriaCreateButton extends StatelessWidget {
  const AtriaCreateButton({
    super.key,
    this.expanded = true,
    this.menuOffset = const Offset(0, 44),
    this.onAfterSelect,
  });

  final bool expanded;
  final Offset menuOffset;

  /// Runs after a route is selected, before the push. The More sheet passes
  /// a close here so the pushed screen does not land on top of a still-open
  /// sheet.
  final VoidCallback? onAfterSelect;

  /// Tap target for the collapsed form. The icon rail is only 64dp wide and
  /// this is the app's PRIMARY create affordance on every 600–839dp window, so
  /// it gets Material's own comfortable size rather than hugging an 18px glyph.
  static const double _collapsedSize = 48;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<AtriaCreateAction>(
      // The tooltip is what names the collapsed glyph for a pointer and for a
      // screen reader; the expanded form spells the label out in its own row.
      tooltip: expanded ? 'Create' : 'Create a new invoice, bill or customer',
      offset: menuOffset,
      position: PopupMenuPosition.under,
      // Navigating from the menu's own onTap raced the popup's dismissal;
      // onSelected runs after it, so the push always lands.
      onSelected: (action) {
        onAfterSelect?.call();
        // Almost every action is a deep link INTO a branch (`/sales/new`,
        // `/items/new`, …), where `push` is right: it lands on that branch's own
        // navigator and back returns to the list behind it.
        //
        // `/payments` is the exception — it is the ROOT of a branch, and
        // go_router resolves an imperative push of a branch root by appending
        // an ImperativeRouteMatch beside the shell match, which hosts the page
        // on the ROOT navigator: no rail, no bottom bar, and Back unwinds to
        // wherever you were. `go` replaces the match list, so the shell stays a
        // single instance and the branch actually switches.
        if (action.route == '/payments') {
          context.go(action.route);
        } else {
          context.push(action.route);
        }
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<AtriaCreateAction>>[];
        String? lastGroup;
        for (final action in atriaCreateActions) {
          if (action.group != lastGroup) {
            lastGroup = action.group;
            if (action.group.isNotEmpty) {
              items.add(
                PopupMenuItem<AtriaCreateAction>(
                  enabled: false,
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    action.group.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          letterSpacing: 1.1,
                        ),
                  ),
                ),
              );
            }
          }
          items.add(
            PopupMenuItem<AtriaCreateAction>(
              value: action,
              height: 38,
              child: Row(
                children: [
                  Icon(action.icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    action.label,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          );
        }
        return items;
      },
      // `PopupMenuButton` names the control for a pointer through its tooltip.
      // The collapsed form carries no visible label at all, so this is the only
      // thing a screen reader has to go on — an unlabelled glyph in the rail
      // is how "make an invoice" becomes "press the mystery button".
      child: Semantics(
        button: true,
        label: expanded ? null : 'Create',
        child: Container(
          // The collapsed form was 38 tall and 18 wide — `padding: 0` around a
          // lone 18px glyph, and visibly smaller than the 26px logo the top bar
          // puts at the same x. It is a square now.
          height: expanded ? 38 : _collapsedSize,
          width: expanded ? null : _collapsedSize,
          padding: EdgeInsets.symmetric(horizontal: expanded ? 14 : 0),
          decoration: BoxDecoration(
            // Same fill as the page primary action (and QBO's own hover green):
            // white on #2CA01C is 3.41:1, under WCAG AA. The brand green is
            // unchanged everywhere it marks rather than carries a label.
            color: Theme.of(context).brightness == Brightness.light
                ? AppColors.primaryDark
                : AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add_rounded, size: 18, color: Colors.white),
              if (expanded) ...[
                const SizedBox(width: 6),
                Text(
                  'Create',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(width: 4),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: Colors.white,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
