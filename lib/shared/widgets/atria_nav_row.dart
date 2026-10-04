import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';
import 'common_widgets.dart';

/// A grouped navigation entry in the idiom Vyapar / myBillBook / Swipe use for
/// their "report library" and section indexes: a tinted leading glyph, a
/// title, a one-line description, and a chevron.
///
/// Use it wherever a screen would otherwise hide a destination inside an
/// unlabelled app-bar icon — the glyph and the subtitle are what make the
/// entry findable, so a row is always preferred over an icon-only action when
/// there is space for one.
class AtriaNavRow extends StatelessWidget {
  const AtriaNavRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.tint,
    this.trailing,
  });

  final IconData icon;
  final String title;

  /// One short line of what the destination holds. Wraps to two lines.
  final String? subtitle;

  final VoidCallback? onTap;

  /// Glyph colour; defaults to the brand primary so a stack of rows reads as
  /// one family. Pass a semantic colour for warning/ledger destinations.
  final Color? tint;

  /// Replaces the trailing chevron — e.g. a count or an amount.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final accent = tint ?? scheme.primary;

    return AtriaCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.25,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing ??
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
        ],
      ),
    );
  }
}

/// A vertical stack of [AtriaNavRow]s with consistent gutters, so a group of
/// destinations is one widget in the tree instead of a Column of Paddings.
class AtriaNavRowList extends StatelessWidget {
  const AtriaNavRowList({super.key, required this.children, this.spacing = 10});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          children[i],
        ],
      ],
    );
  }
}
