import 'package:flutter/material.dart';

import '../../core/bulk/bulk_actions.dart';
import '../../core/utils/formatters.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';

/// The bar that replaces a list's ordinary toolbar row while rows are ticked.
///
/// It goes in `AtriaListPage.toolbar`, which is already the full-width slot
/// between the filters and the body — so a list gains selection without a
/// second layout and without the actions jumping when the bar appears.
///
/// **Hidden when nothing is selected.** An always-present bar with "0
/// selected" and three greyed-out buttons is noise on every screen, and it
/// advertises a capability the operator has to hunt for. This returns `SizedBox
/// .shrink()` rather than an empty container so the row genuinely collapses.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.selection,
    required this.onChanged,
    required this.actions,
    this.onSelectAll,
    this.selectionNoun = 'selected',
  });

  /// What is ticked right now.
  final BulkSelection selection;

  /// Called with the next selection when the operator ticks, unticks, or
  /// selects all.
  final ValueChanged<BulkSelection> onChanged;

  /// The buttons to offer — PDF, CSV, Delete.
  final List<Widget> actions;

  /// Select-all / clear-all. Omit it and the bar shows only the count.
  final VoidCallback? onSelectAll;

  /// "12 selected", "12 invoices selected". Kept singular so the caller can
  /// match its own list.
  final String selectionNoun;

  @override
  Widget build(BuildContext context) {
    if (selection.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    // The bar takes the accent rather than a neutral surface: the whole point
    // is that it is a *mode*, not another card sitting above the list.
    final colors = theme.colorScheme;

    return Material(
      color: colors.primaryContainer.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        child: Row(
          children: [
            if (onSelectAll != null)
              Checkbox(
                value: selection.isAllLoaded,
                tristate: false,
                onChanged: (_) => onSelectAll!(),
                // The count lives in the text beside it; repeating it inside
                // the checkbox's semantics makes a screen reader say "3 of 3"
                // immediately after saying "12 selected".
                visualDensity: VisualDensity.compact,
              ),
            Text(
              // Pluralised, so the bar reads "1 invoice" / "2 invoices" like
              // every other count in the app. Handing it a singular noun and
              // interpolating the bare number gives "2 invoice".
              Formatters.count(selection.count, selectionNoun),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(width: AppSpace.sm),
            // "all 200 loaded" — see BulkSelection.loadedCount. Only shown when
            // the claim is actually about a bounded set, so it never implies
            // there are more rows than exist.
            if (selection.isAllLoaded && selection.count > 0)
              Flexible(
                child: Text(
                  'all ${selection.loadedCount} loaded',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ),
            const Spacer(),
            ...actions,
            const SizedBox(width: AppSpace.sm),
            TextButton(
              onPressed: () => onChanged(selection.cleared()),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    );
  }
}
