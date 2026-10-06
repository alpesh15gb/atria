import 'package:flutter/material.dart';

import '../../core/responsive/platform_ui.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_sizes.dart';

/// Turns whatever a stream or future threw into a sentence a shopkeeper can act
/// on, and logs the raw text for a developer.
///
/// Every report, ledger and party screen used to interpolate the exception
/// straight into an [EmptyState], so a `SqliteException` or a
/// `FileSystemException` — table names, file paths, `errno 13` — appeared as
/// the status line of what looked like a working screen. It also read as a
/// permanent state, because nothing in those messages said the load could be
/// attempted again.
///
/// The exception is deliberately NOT shown: it is not localised, it is not
/// stable across platforms, and it names internals the person cannot change.
/// The common causes get a specific, actionable sentence; everything else gets
/// one honest line. The detail still reaches the log, so nothing is lost to a
/// developer.
String atriaErrorMessage(Object? error, {String? retry}) {
  final raw = error?.toString() ?? '';
  final text = raw.toLowerCase();

  String message;
  if (text.contains('database is locked') ||
      text.contains('database table is locked') ||
      text.contains('sqlite_busy')) {
    message =
        'Apex Books is busy writing — another window or a sync is using the books. '
        'Close the other window, or try again in a moment.';
  } else if (text.contains('disk i/o') ||
      text.contains('no space left') ||
      text.contains('read-only') ||
      text.contains('permission denied') ||
      text.contains('errno 13')) {
    message =
        'Apex Books could not write to its books folder. Check that the drive still '
        'has free space and is not write-protected.';
  } else if (text.contains('unable to open database') ||
      text.contains('malformed') ||
      text.contains('not a database') ||
      text.contains('file is encrypted')) {
    message =
        'Apex Books\'s books file could not be opened. Nothing has been changed — '
        'restore a backup, or put the newer version of Apex Books back if you have '
        'just downgraded.';
  } else if (text.contains('no such table') ||
      text.contains('no such column')) {
    message =
        'These books were written by a different version of Apex Books. Update '
        'Apex Books and try again.';
  } else if (text.contains('socket') ||
      text.contains('connection refused') ||
      text.contains('failed host lookup') ||
      text.contains('network')) {
    message = 'Apex Books could not reach the server. Check your connection.';
  } else {
    message = 'Something went wrong loading this. $retry';
  }

  debugPrint('atria: surface error -> $raw');
  return message;
}

/// A friendly placeholder for empty lists and zero states.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Every number here is a token. Before that this widget alone carried four
    // off-scale values — a 28px glyph, 10px and 14px radii, a 36px inset and an
    // 18px gap — which is why the same empty state looked slightly different on
    // Purchases, Expenses and Parties.
    final tile = compact ? 44.0 : 72.0;

    return Padding(
      padding: EdgeInsets.all(compact ? AppSpace.xl : AppSpace.xxxl),
      // Scrollable, not fixed: this lands inside flex containers (a list's
      // body, a squeezed cart), and its intrinsic height can exceed what is
      // left. A bare Column overflows with the striped banner when it does;
      // scrolling keeps the action reachable instead.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: tile,
              height: tile,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.all(
                  Radius.circular(compact ? AppRadius.md : AppRadius.lg),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: compact ? AppIconSize.xl : AppIconSize.empty,
                color: scheme.primary,
              ),
            ),
            SizedBox(height: compact ? AppSpace.md : AppSpace.lg),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpace.sm),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  message!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              SizedBox(height: compact ? AppSpace.lg : AppSpace.xl),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.add_rounded, size: AppIconSize.md),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A section title with an optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(4, 0, 4, 10),
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Surface card with the app's standard treatment.
class AtriaCard extends StatelessWidget {
  const AtriaCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.showBorder = false,
    this.background,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double? borderRadius;
  final bool showBorder;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: background ?? scheme.surface,
      borderRadius: BorderRadius.all(
        Radius.circular(borderRadius ?? AppRadius.lg),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.all(
          Radius.circular(borderRadius ?? AppRadius.lg),
        ),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.all(
              Radius.circular(borderRadius ?? AppRadius.lg),
            ),
            // QBO separates surfaces with a hairline FIRST and only then a
            // whisper of shadow — a shadow alone disappears on bright walls
            // and low-contrast monitors, which is why the cards on the
            // dashboard read as borderless grey patches. The hairline is the
            // card's boundary on every theme; [showBorder] upgrades the edge
            // to the stronger token for callers that want emphasis.
            border: Border.all(
              color: Theme.of(context).platform.isMobileUi && !showBorder
                  ? Colors.transparent
                  : showBorder
                  ? AppColors.outlineStrong
                  : scheme.outline,
              width: 1,
            ),
            boxShadow: Theme.of(context).platform.isMobileUi
                ? const []
                : isDark
                ? AppShadows.darkCard
                : AppShadows.card,
          ),
          child: child,
        ),
      ),
    );
  }
}
