import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';
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
  });

  final List<EditorTotalsRow> rows;
  final Decimal total;
  final String totalLabel;

  /// Below the total: the mark-paid toggle / balance, on sales.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

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
          child: Column(
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
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  MoneyText(
                    total,
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              if (footer != null) ...[
                const SizedBox(height: 6),
                footer!,
              ],
            ],
          ),
        ),
      ),
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
