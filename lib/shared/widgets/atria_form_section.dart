import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';
import '../../core/theme/app_radius.dart';

/// One titled block of an editor form.
///
/// Every form in the app — invoice, quotation, sales order, purchase bill,
/// debit note, expense, item, party — uses this instead of hand-rolling a card
/// with a `SectionHeader` inside it, so the anatomy of a "field group" is
/// defined once: hairline surface, small icon + title, optional one-line
/// subtitle on the right, then the fields under a divider.
class AtriaFormSection extends StatelessWidget {
  const AtriaFormSection({
    super.key,
    required this.children,
    this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
    this.dense = false,
  });

  final List<Widget> children;
  final String? title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets padding;

  /// Tighter vertical rhythm, for secondary groups (notes, charges).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Material, not a bare Container: the hosts put `SwitchListTile`s in here,
    // and a ListTile paints its background and ink on the nearest Material —
    // a decorated box in between hides them and trips a framework assertion.
    return Material(
      color: scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: scheme.outline),
        borderRadius: BorderRadius.circular(
          Theme.of(context).platform.isMobileUi ? 20 : AppRadius.md,
        ),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (subtitle != null)
                    Flexible(
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
              SizedBox(height: dense ? 10 : 14),
            ],
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Two fields side by side on wide content areas, stacked on narrow ones —
/// the one place that decision is made, shared by every editor.
class AtriaFormFieldRow extends StatelessWidget {
  const AtriaFormFieldRow({
    super.key,
    required this.first,
    required this.second,
    this.spacing = 12,
    this.minWidth = 560,
  });

  final Widget first;
  final Widget second;
  final double spacing;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < minWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              SizedBox(height: spacing),
              second,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: first),
              SizedBox(width: spacing),
              Expanded(child: second),
            ],
          ),
        );
      },
    );
  }
}

/// Stacks [children] on narrow widths and lays them out two-up once there is
/// room for two real columns.
///
/// This is how an editor uses the width of a desktop window: a single column
/// of full-width cards on a 1600px screen is what makes a form look like a
/// phone layout stretched, so secondary groups (address, credit, adjustments)
/// sit beside each other instead. Order is row-major — the eye still walks
/// left to right, top to bottom, in the order the sections were written.
class AtriaSectionColumns extends StatelessWidget {
  const AtriaSectionColumns({
    super.key,
    required this.children,
    this.gap = 12,
    this.minColumnWidth = 420,
  });

  final List<Widget> children;
  final double gap;

  /// A section needs this much room before a second column is worth it —
  /// below it, the fields inside a section stack and the card is mostly
  /// margin.
  final double minColumnWidth;

  static Widget _stack(List<Widget> items, double gap) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) SizedBox(height: gap),
        items[i],
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoUp =
            children.length > 1 &&
            constraints.maxWidth >= minColumnWidth * 2 + gap;
        if (!twoUp) return _stack(children, gap);
        final left = <Widget>[];
        final right = <Widget>[];
        for (var i = 0; i < children.length; i++) {
          (i.isEven ? left : right).add(children[i]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _stack(left, gap)),
            SizedBox(width: gap),
            Expanded(child: _stack(right, gap)),
          ],
        );
      },
    );
  }
}

/// The page body shared by every editor in the app.
///
/// Top to bottom: the two-up header band (the document's subject on the left,
/// its dates on the right), the line grid, the totals right-aligned under the
/// last line, then the collapsible sections. Kept identical across editors so
/// a user who learns the invoice already knows the purchase bill — and the
/// single-record forms (expense, income) keep the same header band with no
/// line grid at all.
///
/// The form is full-bleed: it takes the whole width the shell gives it, minus
/// a gutter, because the alternative is a fixed centred column that strands
/// hundreds of pixels of empty page on either side of a maximised window. The
/// gutters are the only fixed measure here — they step 16 → 24 → 32 as the
/// window grows.
class AtriaEditorForm extends StatelessWidget {
  const AtriaEditorForm({
    super.key,
    this.header,
    this.headerTrailing,
    this.lines,
    this.totals,
    this.totalsMaxWidth = 460,
    this.sections = const <Widget>[],
    this.footer,
    this.padding,
    this.trailingMaxWidth = 520,
    this.maxContentWidth,
  });

  /// The subject band. Omitted by the forms that have no document header — a
  /// party, an item — so they still get this page's gutter and section
  /// rhythm instead of hand-rolling the same layout.
  final Widget? header;
  final Widget? headerTrailing;

  /// The line grid. Omitted by forms that record a single figure.
  final Widget? lines;
  final Widget? totals;
  final double totalsMaxWidth;
  final List<Widget> sections;

  /// Pinned below the sections at full width — a destructive action, a
  /// document-level hint. Never placed in a section column.
  final Widget? footer;

  /// Overrides the responsive page gutter.
  final EdgeInsets? padding;

  /// Ceiling on the header band's right-hand slot. A date pair stretched over
  /// half of a 1600px window reads as an empty field, not a roomier one, so
  /// the slot keeps its natural size and the subject block absorbs the rest.
  final double trailingMaxWidth;

  /// Optional centred column for forms that must not exceed a reading width.
  final double? maxContentWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // A phone has no width to share between the subject block and the
        // dates, and a maximised window has plenty for both.
        final mobile = Theme.of(context).platform.isMobileUi;
        final wide = !mobile && width >= Breakpoints.medium;
        final gutter = width < Breakpoints.compact
            ? 16.0
            : width >= Breakpoints.large
            ? 32.0
            : 24.0;
        final trailingWidth = math.min(trailingMaxWidth, width * 0.42);
        return SingleChildScrollView(
          padding: padding ?? EdgeInsets.fromLTRB(gutter, 18, gutter, 48),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxContentWidth ?? double.infinity,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (mobile && headerTrailing != null) ...[
                    headerTrailing!,
                    const SizedBox(height: 18),
                    ?header,
                  ] else if (header != null && headerTrailing == null)
                    header!
                  else if (header != null && wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: header!),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: trailingWidth),
                          child: headerTrailing!,
                        ),
                      ],
                    )
                  else if (header != null) ...[
                    header!,
                    const SizedBox(height: 12),
                    headerTrailing!,
                  ],
                  if (lines != null) ...[const SizedBox(height: 18), lines!],
                  if (totals != null) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: totalsMaxWidth),
                        child: totals,
                      ),
                    ),
                  ],
                  if (sections.isNotEmpty) ...[
                    // Only separate the sections from something above them.
                    if (header != null || lines != null || totals != null)
                      const SizedBox(height: 12),
                    AtriaSectionColumns(children: sections),
                  ],
                  if (footer != null) ...[const SizedBox(height: 16), footer!],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
