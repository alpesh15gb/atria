import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';

/// The home screen's quick-create strip.
///
/// Every reference app puts this directly under the greeting and above the
/// numbers: Vyapar's tile row, myBillBook's "quick access to common actions"
/// and Swipe's page of action tiles all start billing in one tap from home.
/// A horizontally scrolling strip keeps the row from squeezing labels on a
/// narrow phone while still fitting on desktop.
class AtriaQuickActionStrip extends StatelessWidget {
  const AtriaQuickActionStrip({
    super.key,
    required this.actions,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.tileWidth = 76,
  });

  final List<AtriaQuickAction> actions;
  final EdgeInsetsGeometry padding;
  final double tileWidth;

  @override
  Widget build(BuildContext context) {
    // Tall enough for a two-line label under a 38px glyph. A 92px strip
    // overflowed the tile by 6px as soon as a label wrapped ("New Invoice"),
    // which the golden capture caught.
    return SizedBox(
      height: 106,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: actions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: tileWidth,
          child: _QuickActionTile(action: actions[index]),
        ),
      ),
    );
  }
}

/// One entry in an [AtriaQuickActionStrip].
class AtriaQuickAction {
  const AtriaQuickAction({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.tint,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  /// Icon colour; the tile tints its own background from it.
  final Color tint;
}

class _QuickActionTile extends StatelessWidget {
  const _QuickActionTile({required this.action});

  final AtriaQuickAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.lg);

    return Material(
      color: scheme.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: action.onTap,
        borderRadius: radius,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: Theme.of(context).brightness == Brightness.dark
                ? AppShadows.darkCard
                : AppShadows.card,
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: action.tint.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                alignment: Alignment.center,
                child: Icon(action.icon, size: 18, color: action.tint),
              ),
              const SizedBox(height: 6),
              // Flexible so a large text scale shrinks the label instead of
              // overflowing the fixed-height strip.
              Flexible(
                child: Text(
                  action.label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall
                      ?.copyWith(fontWeight: FontWeight.w600, height: 1.15),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
