import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/engine/gst_engine.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import 'common_widgets.dart' show AtriaCard;
import 'money_text.dart';

/// One figure in the [EditorTotalsPanel].
class EditorTotalsRow {
  const EditorTotalsRow(
    this.label,
    this.amount, {
    this.emphasize = false,
    this.signed = false,
  });

  final String label;
  final Decimal amount;

  /// Slightly bolder label — for the taxable-value line.
  final bool emphasize;

  /// Renders discounts as “− ₹ 12.00” style negatives.
  final bool signed;
}

/// The sticky summary panel: tax breakdown rows, the bold Total Amount, and
/// a caller-provided footer slot (payment status / balance). Shown as-is on
/// desktop (right rail) and compact (bottom bar).
class EditorTotalsPanel extends StatelessWidget {
  const EditorTotalsPanel({
    super.key,
    required this.rows,
    required this.total,
    this.totalLabel = 'Total Amount',
    this.footer,
    this.inline = false,
  });

  final List<EditorTotalsRow> rows;
  final Decimal total;
  final String totalLabel;

  /// Below the total: the mark-paid toggle / balance, on sales.
  final Widget? footer;

  /// QuickBooks puts the totals *under the last line*, right-aligned, instead
  /// of parking them in a side rail. [inline] drops the pane chrome (border,
  /// scrolling) so the panel can sit inside the editor's own scroll view.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (inline) {
      // Material (not a bare DecoratedBox): the footer carries a
      // CheckboxListTile, and a ListTile needs a Material ancestor to paint
      // its background and ink on.
      return Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outline),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: _content(context, scheme, text),
        ),
      );
    }

    return Material(
      color: scheme.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: scheme.outline.withValues(alpha: 0.7)),
            top: BorderSide(color: scheme.outline.withValues(alpha: 0.7)),
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: _content(context, scheme, text),
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context,
    ColorScheme scheme,
    TextTheme text,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    row.label,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight:
                          row.emphasize ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                MoneyText(
                  row.signed
                      ? (row.amount < Decimal.zero
                            ? -row.amount
                            : row.amount)
                      : row.amount,
                  style: text.bodySmall?.copyWith(
                    fontWeight:
                        row.emphasize ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Divider(color: scheme.outline, height: 1),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                totalLabel,
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            MoneyText(
              total,
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        if (footer != null) ...[
          const SizedBox(height: 6),
          footer!,
        ],
      ],
    );
  }
}

/// The ready-made breakdown every document editor shows under its lines:
/// subtotal, the two discount lines, taxable value, the CGST/SGST or IGST
/// split (labelled with the rate, the way Tally prints it), cess, any extra
/// charges the caller passes, then round-off and the grand total.
///
/// Having one implementation is what keeps an invoice and a purchase bill
/// arithmetic-identical, price-for-price.
class AtriaTotalsBlock extends StatelessWidget {
  const AtriaTotalsBlock({
    super.key,
    required this.totals,
    this.extraCharges,
    this.extraRows = const <EditorTotalsRow>[],
    this.isInterState = false,
    this.split,
    this.totalLabel = 'Total',
    this.footer,
    this.inline = true,
  });

  /// Engine output for the document's valid lines.
  final GstResult totals;

  /// Shipping, freight, other charges — added on top of the engine's total.
  final Decimal? extraCharges;

  /// Rows describing those charges, rendered above round-off.
  final List<EditorTotalsRow> extraRows;

  /// Whether this document charges IGST. Kept for callers that only know the
  /// stored boolean; [split] wins when it is supplied.
  final bool isInterState;

  /// The tax split the engine computed this document with.
  ///
  /// Pass it when you have it: it is the only way a Union Territory firm gets
  /// CGST + **UTGST** on the face of its own editor instead of a hardcoded
  /// "SGST", which is a misstatement the customer reconciles against their own
  /// return (see `intraStateSecondHead`). It also keeps the totals block
  /// agreeing with the document detail screen, which passes the resolved split.
  final GstSplit? split;

  final String totalLabel;
  final Widget? footer;
  final bool inline;

  Decimal get _grandTotal => totals.grandTotal + (extraCharges ?? Decimal.zero);

  /// The resolved split, from [split] when given and from [isInterState]
  /// otherwise.
  GstSplit get _split =>
      split ?? (isInterState ? GstSplit.interState : GstSplit.intraState);

  /// Half the document's single tax rate, for the "CGST 9%" row labels.
  ///
  /// Only when there is exactly ONE rate to name: `rateWise` is sorted
  /// ASCENDING, so on a mixed 5% + 18% invoice `first` is the 5% slab and both
  /// aggregate rows used to be labelled "2.5%" while their amounts covered
  /// three slabs. A rate label that can be wrong is worse than none — Tally's
  /// rate-wise table is the place a mixed invoice shows its rates.
  String? get _halfRateLabel {
    if (totals.rateWise.length != 1) return null;
    final half = totals.rateWise.first.rate / 2;
    if (half <= 0) return null;
    return Formatters.percent(half);
  }

  @override
  Widget build(BuildContext context) {
    final half = _halfRateLabel;
    // 'SGST', or 'UTGST' for a firm in or supplying a Union Territory.
    final secondHead = intraStateSecondHead(_split);
    final rows = <EditorTotalsRow>[
      EditorTotalsRow('Subtotal', totals.subTotal),
      if (totals.itemDiscountTotal > Decimal.zero)
        EditorTotalsRow('Item discount', -totals.itemDiscountTotal,
            signed: true),
      if (totals.invoiceDiscount > Decimal.zero)
        EditorTotalsRow('Invoice discount', -totals.invoiceDiscount,
            signed: true),
      EditorTotalsRow('Taxable value', totals.taxableValue, emphasize: true),
      if (_split != GstSplit.interState) ...[
        if (totals.cgstTotal > Decimal.zero)
          EditorTotalsRow(
              half == null ? 'CGST' : 'CGST $half', totals.cgstTotal),
        if (totals.sgstTotal > Decimal.zero)
          EditorTotalsRow(
              half == null ? secondHead : '$secondHead $half', totals.sgstTotal),
      ] else if (totals.igstTotal > Decimal.zero)
        EditorTotalsRow('IGST', totals.igstTotal),
      if (totals.cessTotal > Decimal.zero)
        EditorTotalsRow('Cess', totals.cessTotal),
      ...extraRows,
      if (totals.roundOff.abs() > Decimal.zero)
        EditorTotalsRow('Round off', totals.roundOff, signed: true),
    ];

    return EditorTotalsPanel(
      rows: rows,
      total: _grandTotal,
      totalLabel: totalLabel,
      inline: inline,
      footer: footer,
    );
  }
}

/// A collapsed "Add Notes"-style link that expands in place to reveal its
/// editor. Used so notes/terms/charges don't crowd the form.
class EditorLinkSection extends StatefulWidget {
  const EditorLinkSection({
    super.key,
    required this.icon,
    required this.title,
    required this.builder,
    this.initiallyOpen = false,
  });

  final IconData icon;
  final String title;

  /// Builds the editor revealed when the link is tapped.
  final WidgetBuilder builder;
  final bool initiallyOpen;

  @override
  State<EditorLinkSection> createState() => _EditorLinkSectionState();
}

class _EditorLinkSectionState extends State<EditorLinkSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: EdgeInsets.symmetric(
        horizontal: 14,
        vertical: _open ? 14 : 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(widget.icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState:
                _open ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: widget.builder(context),
            ),
            secondChild: const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
