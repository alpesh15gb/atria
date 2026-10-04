import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';

/// The list-screen control strip the Indian billing apps share: a search
/// field, a single-select segmented filter row (document types on Sales and
/// Purchase, stock state on Items, party type on Parties, money in/out on
/// Payments), and a quiet results line carrying the count and the period
/// total — `12 invoices · ₹2,34,000`.
///
/// Everything here is presentation-only: the screen owns the filter state.

/// One option in an [AtriaSegmentedFilter].
class AtriaSegment<T> {
  const AtriaSegment({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// The pill's own chrome, as named constants.
///
/// The non-scrolling form has to know how wide a pill would be *before* it
/// renders one (see [AtriaSegmentedFilter._fits]), and a number spelled out
/// twice is a number that drifts. These are the single definition of the parts
/// of a pill that are not its label.
const double _pillHorizontalPadding = 8;
const double _pillVerticalPadding = 7;
const double _pillBorderWidth = 1;
const double _pillIconSize = 14;
const double _pillIconGap = 4;

/// Gap between pills in the scrolling form.
const double _pillScrollGap = 6;

/// A single-select pill row.
///
/// With [scrollable] the pills keep their natural width and scroll
/// horizontally. Without it the pills share the strip's width equally — but
/// only while that share can still hold their labels. A pill used to spend
/// about 58dp of chrome (24dp of padding, a 2dp border, a 16px glyph and a 6dp
/// gap) before its first letter, so a 360dp strip with three pills left ~51dp
/// each and *every* label rendered as "…" — "All items" needs about 58dp. Under
/// a 2.0× system font (see `app.dart`, which no longer caps text scaling) that
/// is true of every label on every strip. So the equal-width row is now only
/// used while the labels measurably fit; below that the row falls back to the
/// scrolling form, where a label is never truncated.
class AtriaSegmentedFilter<T> extends StatelessWidget {
  const AtriaSegmentedFilter({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.scrollable = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<AtriaSegment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Natural-width pills that scroll, instead of equal-width pills that fit.
  /// The non-scrolling form still scrolls by itself once it has to — see the
  /// class doc.
  final bool scrollable;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // QBO's filter row is a set of hairline-bordered pills sitting directly on
    // the page — there is no grey track behind them any more.
    return LayoutBuilder(
      builder: (context, constraints) {
        final inset =
            padding.resolve(Directionality.of(context)).horizontal;
        final viewport = constraints.maxWidth;

        // Unbounded means a caller parked the strip inside a horizontal
        // scroll view and never sized it; equal-width [Expanded] pills cannot
        // lay themselves out there, so the scrolling form is the only answer.
        final scrolls = scrollable ||
            !viewport.isFinite ||
            !_fits(context, viewport - inset);

        return Padding(
          padding: padding,
          child: scrolls
              // Tapping a pill focuses the scroll view and paints a focus
              // highlight around the whole strip; the pills carry their own
              // feedback.
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final segment in segments)
                        Padding(
                          padding: const EdgeInsets.only(
                            right: _pillScrollGap,
                          ),
                          child: _Pill<T>(
                            segment: segment,
                            selected: segment.value == value,
                            onTap: () => onChanged(segment.value),
                          ),
                        ),
                    ],
                  ),
                )
              : Row(
                  children: [
                    for (var i = 0; i < segments.length; i++)
                      Expanded(
                        child: Padding(
                          // The scrolling form carries its own trailing gap;
                          // between two Expanded pills it would otherwise
                          // become an inset on every pill but the last.
                          padding: EdgeInsets.only(
                            right: i == segments.length - 1
                                ? 0
                                : _pillScrollGap,
                          ),
                          child: _Pill<T>(
                            segment: segments[i],
                            selected: segments[i].value == value,
                            onTap: () => onChanged(segments[i].value),
                          ),
                        ),
                      ),
                  ],
                ),
        );
      },
    );
  }

  /// Whether pills laid out at their natural width still fit in [available].
  ///
  /// Measured rather than estimated: this strip lives on phones and in narrow
  /// panes at every system text scale, and a character-count guess is exactly
  /// what makes a filter row degrade into three ellipses on one device and look
  /// fine on another.
  ///
  /// The equal-width row hands every pill the *same* share, so what has to fit
  /// is the widest label into that share — not the total. A row of `['All',
  /// 'Delivery note']` fits by total on a 360dp strip while 'Delivery note'
  /// still needs more than half of it; checking the total alone would keep the
  /// equal-width form and quietly ellipsise the long label, which is the one
  /// thing this class exists to avoid.
  bool _fits(BuildContext context, double available) {
    if (segments.isEmpty) return true;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w700,
        );
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    // The share each pill gets: the strip, less the gaps between pills. The
    // scrolling form's gaps live in each pill's padding; here they are taken
    // off the width before it is divided.
    final share = (available - _pillScrollGap * (segments.length - 1)) /
        segments.length;
    var widest = 0.0;
    for (final segment in segments) {
      painter.text = TextSpan(text: segment.label, style: style);
      painter.layout();
      final needed =
          painter.width + _pillChrome(hasIcon: segment.icon != null);
      if (needed > widest) widest = needed;
    }
    painter.dispose();
    // A hair of slack, so a rounding difference at the boundary never decides
    // between "equal widths" and "scrolls" from one frame to the next.
    return widest <= share + 1;
  }

  /// Everything a pill costs before its label, in logical pixels.
  static double _pillChrome({required bool hasIcon}) =>
      (_pillHorizontalPadding * 2) +
      (_pillBorderWidth * 2) +
      (hasIcon ? _pillIconSize + _pillIconGap : 0);
}

class _Pill<T> extends StatelessWidget {
  const _Pill({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final AtriaSegment<T> segment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppRadius.pill);
    final fg = selected ? scheme.primary : scheme.onSurface;

    return Material(
      color: selected ? scheme.primaryContainer : scheme.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          // Horizontal padding, glyph and gap are all smaller than they were:
          // at 360dp a third of the strip plus ~58dp of chrome left 51dp of
          // label, which is less than "All items". See [_pillChrome].
          padding: const EdgeInsets.symmetric(
            horizontal: _pillHorizontalPadding,
            vertical: _pillVerticalPadding,
          ),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              width: _pillBorderWidth,
              color: selected ? scheme.primary : scheme.outline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (segment.icon != null) ...[
                Icon(segment.icon, size: _pillIconSize, color: fg),
                const SizedBox(width: _pillIconGap),
              ],
              // The pill's label has to be the part that gives way. In the
              // non-scrollable form each pill is inside an [Expanded], so on a
              // 360dp screen five document types share ~330dp and a label like
              // "Delivery note" is wider than its share. A bare [Text] in a
              // `min`-sized Row takes its natural width and the Row overflows
              // with the striped banner; wrapped, it ellipsises instead.
              Flexible(
                child: Text(
                  segment.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700, color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet line above a list: how many rows are shown, and what they add
/// up to. Vyapar puts the same two facts at the head of every report.
class AtriaResultsBar extends StatelessWidget {
  const AtriaResultsBar({
    super.key,
    required this.count,
    required this.noun,
    this.total,
    this.totalLabel = 'Total',
    this.filtered = false,
    this.pluralNoun,
  });

  final int count;

  /// Singular noun. The plural is derived by [Formatters.pluralise], so a
  /// `y` noun no longer renders as "partys".
  final String noun;

  /// Overrides the derived plural, for a noun English does not spell the
  /// regular way.
  final String? pluralNoun;

  /// Omitted for lists where a sum would be meaningless (e.g. items).
  final Decimal? total;

  final String totalLabel;

  /// True when a search/filter is narrowing the list, so the line reads
  /// "3 of 40" rather than implying the business only has three.
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Vertical only: this bar lives inside the page gutter, so owning a
    // horizontal inset of its own is what put Sales' results line 16px right of
    // the rows it summarises.
    //
    // Both texts are flexed and ellipsised. Neither used to be: a 7-digit
    // count, a "shown" note and a period total together are more than a 360dp
    // phone's gutter can hold, and `Row` gives a non-flex child an unbounded
    // width — so the overflow was not merely cramped, it was the striped
    // RenderFlex banner across the top of the list. `spaceBetween` keeps the
    // total hard against the right edge (as the old `Spacer` did) while leaving
    // each half free to give way; when there is nothing to sum, the count keeps
    // the left edge on its own.
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: Formatters.count(count, noun, plural: pluralNoun),
                    style: text.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (filtered)
                    TextSpan(
                      text: ' shown',
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
          ),
          if (total != null)
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$totalLabel  ',
                      style: text.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: Formatters.money(total!),
                      style: text.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                textAlign: TextAlign.end,
              ),
            ),
        ],
      ),
    );
  }
}

/// A list screen's filter row, the way QuickBooks Online lays one out: a strip
/// of hairline-bordered selects directly under the page heading — `Type:
/// Invoices ▾   Date: This month ▾` — with the page's quiet actions pushed to
/// the right edge.
///
/// The same strip adapts rather than forking: on a desktop window each filter
/// renders as a select (QBO's web control, which shows the *current* choice
/// without spending a row of width on every option); on a phone it falls back
/// to the segmented pill row, which is what QBO's own mobile app uses. Screens
/// therefore keep a single [AtriaAdaptiveFilter] per filter and never branch on
/// width themselves.
class AtriaFilterBar extends StatelessWidget {
  const AtriaFilterBar({
    super.key,
    required this.filters,
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 8),
  });

  /// One [AtriaAdaptiveFilter] per filter group, in reading order.
  final List<Widget> filters;

  /// Quiet page actions that belong beside the filters, right-aligned.
  final List<Widget> actions;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= Breakpoints.compact;
        return _FilterBarScope(
          wide: wide,
          child: Padding(
            padding: padding,
            child: wide
                // The filter strip scrolls rather than overflowing: a Date
                // filter with a custom From/To pair is wide enough that a
                // narrow desktop window (or a large text scale) would
                // otherwise paint the striped overflow banner across the
                // screen. Actions stay pinned to the right edge.
                ? Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final filter in filters) ...[
                                filter,
                                const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        ),
                      ),
                      if (actions.isNotEmpty) const SizedBox(width: 8),
                      ...actions,
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final filter in filters) filter,
                      if (actions.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(children: actions),
                      ],
                    ],
                  ),
          ),
        );
      },
    );
  }
}

/// Carries the filter bar's width decision down to its filters, so a
/// [AtriaAdaptiveFilter] never has to measure itself (a widget inside a [Row]
/// would only ever see an unbounded width).
class _FilterBarScope extends InheritedWidget {
  const _FilterBarScope({required this.wide, required super.child});

  final bool wide;

  static bool? maybeWide(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FilterBarScope>()?.wide;

  @override
  bool updateShouldNotify(_FilterBarScope oldWidget) => oldWidget.wide != wide;
}

/// One filter, rendered as whichever control fits: a labelled select on wide
/// layouts, the segmented pill row on phones.
class AtriaAdaptiveFilter<T> extends StatelessWidget {
  const AtriaAdaptiveFilter({
    super.key,
    required this.label,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.scrollable = true,
    this.icon,
  });

  /// The field name printed before the current choice — QBO's `Type:`,
  /// `Status:`, `Date:` prefixes.
  final String label;

  final List<AtriaSegment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Phone pill rows scroll by default (five document types do not fit 360dp).
  final bool scrollable;

  /// Optional glyph for the pill form.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final wide = _FilterBarScope.maybeWide(context);
    if (wide != false) {
      return AtriaFilterSelect<T>(
        label: label,
        segments: segments,
        value: value,
        onChanged: onChanged,
      );
    }
    return AtriaSegmentedFilter<T>(
      segments: [
        for (final s in segments)
          AtriaSegment<T>(value: s.value, label: s.label, icon: s.icon ?? icon),
      ],
      value: value,
      onChanged: onChanged,
      scrollable: scrollable,
      padding: EdgeInsets.zero,
    );
  }
}

/// The wide-layout filter control: `Label: Current ▾` in a hairline box.
class AtriaFilterSelect<T> extends StatelessWidget {
  const AtriaFilterSelect({
    super.key,
    required this.label,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final List<AtriaSegment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final current = segments.firstWhere(
      (s) => s.value == value,
      orElse: () => segments.first,
    );
    final radius = BorderRadius.circular(AppRadius.xs);

    return PopupMenuButton<T>(
      tooltip: label,
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final segment in segments)
          PopupMenuItem<T>(
            value: segment.value,
            height: 36,
            child: Row(
              children: [
                if (segment.icon != null) ...[
                  Icon(segment.icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                ],
                Text(segment.label, style: text.bodyMedium),
                if (segment.value == value) ...[
                  const Spacer(),
                  Icon(Icons.check_rounded, size: 16, color: scheme.primary),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: radius,
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (current.icon != null) ...[
              Icon(current.icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
            ],
            Text(
              '$label:  ',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              current.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 2),
            Icon(
              PhosphorIconsRegular.caretDown,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
