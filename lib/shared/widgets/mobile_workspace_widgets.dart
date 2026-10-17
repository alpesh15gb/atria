import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';

/// One segmented control for phone document, directory and preview surfaces.
class MobileTabSwitch extends StatelessWidget {
  const MobileTabSwitch({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.trailing,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: scheme.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Row(
          children: [
            for (var index = 0; index < labels.length; index++)
              Expanded(
                child: Semantics(
                  selected: index == selected,
                  button: true,
                  child: InkWell(
                    borderRadius: AppRadius.smAll,
                    onTap: () => onSelected(index),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      constraints: const BoxConstraints(minHeight: 44),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: AppRadius.smAll,
                        color: index == selected
                            ? scheme.primaryContainer
                            : Colors.transparent,
                      ),
                      child: Text(
                        labels[index],
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: index == selected
                                  ? scheme.onPrimaryContainer
                                  : scheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ),
                ),
              ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
