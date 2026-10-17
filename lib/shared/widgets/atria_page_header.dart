import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/platform_ui.dart';
import 'unsaved_guard.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';

/// The way off a screen that lives **outside** the nav shell.
///
/// `/pos` and `/payment-reminders` are root-level routes on purpose — the
/// counter screen takes the whole window, and there is no rail to be
/// "interrupted" by. But that decision costs them the two things a shell screen
/// gets for free: the rail, and `Navigator.canPop()`.
///
/// The rail reaches them with `go`, which *replaces* the match list instead of
/// pushing onto it, so the root navigator holds exactly one page, `canPop()` is
/// false, and `AppBar`'s `automaticallyImplyLeading` back button never appears.
/// Both screens were left with no way out at all but the window's close button
/// — on the POS, mid-customer, with a cart on screen.
///
/// So a shell-less screen has to own its exit. This is that exit, in one place
/// so the next one cannot forget: pop when there is genuinely something to pop
/// to, otherwise `go` the fallback. `AppBar.leading` slot.
class AtriaExitButton extends StatelessWidget {
  const AtriaExitButton({
    super.key,
    this.fallback = '/dashboard',
    this.tooltip = 'Back',
  });

  /// Where to land when there is no history to pop — the Dashboard, which every
  /// signed-in user can reach from anywhere.
  final String fallback;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back_rounded),
      tooltip: tooltip,
      // Same 44dp floor as [AtriaPageHeader]'s own back button, and for the
      // same reason: a bare glyph is below the platform minimum at 36.
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: () async {
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).maybePop();
        } else {
          if (await UnsavedChanges.confirmLeave(context) && context.mounted) context.go(fallback);
        }
      },
    );
  }
}

/// The in-page title block, and the placement QuickBooks gives it.
///
/// In QBO the page owns its own heading: the title sits at the top-left of the
/// content area and the page's primary action sits at the top-**right** of the
/// same line. There is no floating action button anywhere in the product, and
/// no second title bar — the chrome's band already carries the things that
/// belong to the whole app.
///
/// Screens that are branch roots (Sales, Purchase, Items, Parties, Payments,
/// Expenses, Stock, Reports) use this instead of a `Scaffold.appBar`.
class AtriaPageHeader extends StatelessWidget {
  const AtriaPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.compact = false,
  });

  final String title;

  /// One quiet line under the title — the period a report covers, or how many
  /// rows are in view. Omitted when the page has nothing worth saying.
  final String? subtitle;

  /// Page actions, in QBO's order: primary first, then secondary, then quiet
  /// icon buttons. Right-aligned.
  final List<Widget> actions;

  /// Phone widths: the title may wrap and the actions go below it rather than
  /// squeezing the title away.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final canPop = Navigator.of(context).canPop();

    final titleColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    final heading = canPop
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                tooltip: 'Back',
                padding: EdgeInsets.zero,
                // 44, not 36: this is a bare glyph on a pushed screen, and a
                // 36dp target is below the platform minimum on both platforms
                // (Material's own guidance is 48 for a primary action). The
                // row has no height of its own, so the extra 8dp costs nothing
                // — the title beside it was already taller.
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 8),
              Expanded(child: titleColumn),
            ],
          )
        : titleColumn;

    return Padding(
      // The page gutter token, so the heading is on the same left edge as the
      // search field, the filters and the rows below it. This was a literal 20,
      // which on a phone sat 4px right of everything it was heading.
      padding: EdgeInsets.fromLTRB(
        compact ? AppPage.gutterCompact : AppPage.gutter,
        compact ? 12 : 16,
        compact ? AppPage.gutterCompact : AppPage.gutter,
        compact ? 8 : 12,
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: _spaced(actions)),
                  ),
                ],
              ],
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: heading),
                if (actions.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  // Flexible, not a bare `Row`: a page's actions are buttons,
                  // and at a 2.0× system font (see `app.dart`, which no longer
                  // caps text scaling) a row of labels does not fit beside the
                  // title at 600dp. Flexed, the group takes only what it needs
                  // and the title keeps the rest; the labels ellipsise.
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: _spaced(actions),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  List<Widget> _spaced(List<Widget> widgets) {
    final out = <Widget>[];
    for (var i = 0; i < widgets.length; i++) {
      if (i > 0) out.add(const SizedBox(width: 8));
      out.add(widgets[i]);
    }
    return out;
  }
}

/// The page's green primary action — QBO's filled action button, the same
/// shape as the Create button in the chrome.
class AtriaPrimaryAction extends StatelessWidget {
  const AtriaPrimaryAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    // The label is capped rather than allowed to push the title off the page:
    // under a large system font "Create my business" is wider than the header
    // has left, and a button that grows past its own box paints the overflow
    // stripe across the page.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon ?? Icons.add_rounded, size: AppIconSize.md),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
        style: FilledButton.styleFrom(
          // `primaryDark`, not `primary`: white on #2CA01C measures 3.41:1,
          // under WCAG AA, and this is the app's most-clicked label. #248615 is
          // 4.67:1 and is QBO's own hover tone, so the brand still reads as the
          // brand.
          backgroundColor: isLight && !Theme.of(context).platform.isMobileUi
              ? AppColors.primaryDark
              : Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          minimumSize: Size(0, Theme.of(context).platform.isMobileUi ? 48 : 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: Theme.of(context).platform.isMobileUi
                ? BorderRadius.circular(16)
                : AppRadius.smAll,
          ),
          textStyle: Theme.of(context).textTheme.labelLarge
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// A quiet icon action for the page header's right edge (print, export,
/// settings) — QBO renders these as borderless glyph buttons, not buttons with
/// labels.
class AtriaHeaderIconAction extends StatelessWidget {
  const AtriaHeaderIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: AppIconSize.md, color: scheme.onSurfaceVariant),
      style: IconButton.styleFrom(
        // 44, not 34. A hairline borderless glyph button is right; one you have
        // to aim at is not, and this is the only affordance a print/export
        // action has. Zero padding keeps the glyph where it was — the target
        // grew around it.
        minimumSize: const Size(44, 44),
        padding: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.smAll),
      ),
    );
  }
}
