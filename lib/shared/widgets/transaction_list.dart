import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import 'money_text.dart';
import 'status_chip.dart';

/// The shared "transactions" look for the document list screens (sales,
/// purchase, expenses): one totals card up top, a search + period toolbar,
/// clean rows with a kebab of actions, and an aligned table on desktop.
///
/// Inspired by the desktop billing suites, rebuilt with Atria's own theme —
/// nothing here is a copy: no sidebar chrome, no fake filter chips for
/// features this app does not have. Every building block is optional so a
/// screen can adopt just the row, just the card, or the whole scaffold.

/// Where the summary lives: as one wide card like the reference desktop app
/// ([TotalsCardStyle.tinted]) or as plain bold figures ([TotalsCardStyle.plain]).
enum TotalsCardStyle { tinted, plain }

/// A single figure inside [TotalsCard].
class TotalsEntry {
  const TotalsEntry({required this.label, required this.amount});

  final String label;
  final Decimal amount;
}

/// The one-card summary strip: heading amount first, secondary figures after
/// a divider — "Total Sales Amount / Received / Balance" rather than three
/// competing cards.
class TotalsCard extends StatelessWidget {
  const TotalsCard({
    super.key,
    required this.title,
    required this.entries,
    this.style = TotalsCardStyle.tinted,
    this.compact = false,
  });

  /// Small caption above the leading amount, e.g. "Total Sales Amount".
  final String title;

  /// First entry leads in bold; the rest follow inline after a divider.
  final List<TotalsEntry> entries;

  final TotalsCardStyle style;

  /// Tighter paddings for phone widths.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;
    final heading = entries.first;
    final rest = entries.skip(1).toList();

    final card = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 16,
        vertical: compact ? 11 : 13,
      ),
      decoration: BoxDecoration(
        color: style == TotalsCardStyle.tinted
            ? colors.brandGradientStart.withValues(alpha: 0.08)
            : scheme.surface,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
        border: Border.all(
          color: style == TotalsCardStyle.tinted
              ? colors.brandGradientStart.withValues(alpha: 0.2)
              : scheme.outline,
          width: 0.9,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: rest.isEmpty ? 1 : 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: text.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                MoneyText(
                  heading.amount,
                  compact: compact,
                  colorize: false,
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          for (var i = 0; i < rest.length; i++) ...[
            const SizedBox(width: 14),
            Container(
              width: 1,
              height: 34,
              color: scheme.outline.withValues(alpha: 0.55),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    rest[i].label,
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  MoneyText(
                    rest[i].amount,
                    compact: compact,
                    colorize: rest[i].amount > Decimal.zero,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    return card;
  }
}

/// The rounded search field used above every transaction list. Debouncing is
/// the caller's job (some screens stream from SQL, others filter in memory).
class TransactionSearchField extends StatelessWidget {
  const TransactionSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    this.onClear,
  });

  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  /// Defaults to clearing the controller and firing [onChanged] with ''.
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return SearchBar(
      controller: controller,
      hintText: hintText,
      leading: const Icon(Icons.search_rounded, size: 19),
      trailing: controller.text.isEmpty
          ? null
          : [
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: onClear ??
                    () {
                      controller.clear();
                      onChanged('');
                    },
              ),
            ],
      onChanged: onChanged,
    );
  }
}

/// One action offered in a row's kebab menu.
class RowAction {
  const RowAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool destructive;
}

/// The kebab (⋮) that ends every row: overflow actions live here instead of
/// crowding the row itself.
class RowActionsButton extends StatelessWidget {
  const RowActionsButton({super.key, required this.actions});

  final List<RowAction> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      tooltip: 'More actions',
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      icon: Icon(
        Icons.more_vert_rounded,
        size: 19,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onSelected: (index) => actions[index].onSelected(),
      itemBuilder: (context) => [
        for (var i = 0; i < actions.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Row(
              children: [
                Icon(
                  actions[i].icon,
                  size: 18,
                  color: actions[i].destructive
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Text(
                  actions[i].label,
                  style: TextStyle(
                    color: actions[i].destructive
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The unified transaction row: [leading] glyph, title line, [subtitle]
/// metadata line, trailing [amount] with a status chip under it.
///
/// A swipe-to-delete can be layered by the caller; the row itself stays
/// presentation-only.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.onTap,
    this.statusLabel,
    this.statusKind = ChipKind.neutral,
    this.amountColorize = false,
    this.trailing,
    this.dimmed = false,
  });

  /// Icon (or initials) in a tinted circle.
  final Widget leading;

  final String title;
  final String subtitle;

  final Decimal amount;
  final VoidCallback onTap;

  /// Optional status pill rendered under the amount.
  final String? statusLabel;
  final ChipKind statusKind;

  /// Whether the amount should wear the debit/credit colour.
  final bool amountColorize;

  /// Extra widget slotted before the kebab (desktop table alignment, etc.).
  final Widget? trailing;

  /// Rendered at reduced opacity for cancelled documents.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Material(
      color: scheme.surface,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
            border: Border.all(color: scheme.outline, width: 0.9),
          ),
          child: Opacity(
            opacity: dimmed ? 0.55 : 1,
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MoneyText(
                      amount,
                      colorize: amountColorize,
                      style:
                          text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (statusLabel != null) ...[
                      const SizedBox(height: 4),
                      StatusChip(label: statusLabel!, kind: statusKind),
                    ],
                  ],
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A tinted-circle glyph used as a row's leading widget.
class LeadingGlyph extends StatelessWidget {
  const LeadingGlyph({
    super.key,
    required this.icon,
    this.tint,
    this.shape = BoxShape.circle,
  });

  final IconData icon;
  final Color? tint;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tint ?? scheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.26 : 0.13),
        shape: shape,
        borderRadius: shape == BoxShape.rectangle
            ? const BorderRadius.all(Radius.circular(AppRadius.sm))
            : null,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 19, color: color),
    );
  }
}

/// Column headings for the desktop table below.
class TransactionColumns {
  const TransactionColumns({
    required this.date,
    required this.number,
    required this.party,
    required this.detail,
    required this.amount,
    required this.balance,
  });

  final String date;
  final String number;
  final String party;
  final String detail;
  final String amount;
  final String balance;
}

/// One aligned desktop row; wraps [TransactionRow]'s data in the same cell
/// grid so wide screens read like a proper ledger instead of stretched cards.
class TransactionTableRow extends StatelessWidget {
  const TransactionTableRow({
    super.key,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    required this.leading,
    required this.date,
    required this.number,
    required this.party,
    required this.detail,
    required this.amount,
    required this.balance,
    required this.statusLabel,
    required this.statusKind,
    required this.trailing,
    this.amountColorize = false,
    this.dimmed = false,
  });

  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final Widget leading;
  final String date;
  final String number;
  final String party;
  final String detail;
  final Decimal amount;
  final Decimal balance;
  final String statusLabel;
  final ChipKind statusKind;
  final Widget trailing;
  final bool amountColorize;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onSecondaryTap,
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
            ),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 10),
              _cell(date, text.bodySmall, flex: 8),
              _cell(number, text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  flex: 8),
              Expanded(
                flex: 16,
                child: Text(
                  party,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              _cell(detail, text.bodySmall, flex: 12),
              Expanded(
                flex: 9,
                child: MoneyText(
                  amount,
                  colorize: amountColorize,
                  style: text.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Expanded(
                flex: 9,
                child: Row(
                  children: [
                    Expanded(
                      child: MoneyText(
                        balance,
                        colorize: balance > Decimal.zero,
                        style: text.bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    StatusChip(label: statusLabel, kind: statusKind),
                  ],
                ),
              ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _cell(String value, TextStyle? style, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}

/// The header row above a [TransactionTableRow] list.
class TransactionTableHeader extends StatelessWidget {
  const TransactionTableHeader({
    super.key,
    required this.columns,
    required this.trailing,
  });

  final TransactionColumns columns;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget head(String label, {required int flex, bool end = false}) {
      return Expanded(
        flex: flex,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: end ? TextAlign.right : TextAlign.left,
          style: text.labelSmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 50),
          head(columns.date, flex: 8),
          head(columns.number, flex: 8),
          head(columns.party, flex: 16),
          head(columns.detail, flex: 12),
          head(columns.amount, flex: 9, end: true),
          head(columns.balance, flex: 9, end: true),
          trailing,
        ],
      ),
    );
  }
}
