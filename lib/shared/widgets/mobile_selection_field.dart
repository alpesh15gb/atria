import 'package:flutter/material.dart';

class MobileChoice<T> {
  const MobileChoice({required this.value, required this.label, this.subtitle});
  final T value;
  final String label;
  final String? subtitle;
}

Future<T?> showMobileChoices<T>(
  BuildContext context, {
  required String title,
  required List<MobileChoice<T>> choices,
  VoidCallback? onAddNew,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) =>
        _ChoiceSheet<T>(title: title, choices: choices, onAddNew: onAddNew),
  );
}

class _ChoiceSheet<T> extends StatefulWidget {
  const _ChoiceSheet({
    required this.title,
    required this.choices,
    this.onAddNew,
  });
  final String title;
  final List<MobileChoice<T>> choices;
  final VoidCallback? onAddNew;
  @override
  State<_ChoiceSheet<T>> createState() => _ChoiceSheetState<T>();
}

class _ChoiceSheetState<T> extends State<_ChoiceSheet<T>> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final choices = widget.choices
        .where(
          (c) => '${c.label} ${c.subtitle ?? ''}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close picker',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (widget.onAddNew != null)
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onAddNew!();
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Add new'),
              ),
            Expanded(
              child: choices.isEmpty
                  ? const Center(child: Text('No matches'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: choices.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) {
                        final choice = choices[index];
                        return ListTile(
                          title: Text(choice.label),
                          subtitle: choice.subtitle == null
                              ? null
                              : Text(choice.subtitle!),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.pop(context, choice.value),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A real FormField, not a decorative picker that bypasses required validation.
class MobileSelectionField<T> extends StatelessWidget {
  const MobileSelectionField({
    super.key,
    required this.label,
    required this.placeholder,
    required this.choices,
    required this.onChanged,
    this.value,
    this.onAddNew,
    this.validator,
  });
  final String label, placeholder;
  final List<MobileChoice<T>> choices;
  final T? value;
  final ValueChanged<T> onChanged;
  final VoidCallback? onAddNew;
  final FormFieldValidator<T>? validator;

  @override
  Widget build(BuildContext context) {
    final selected = choices.where((c) => c.value == value).firstOrNull;
    final scheme = Theme.of(context).colorScheme;
    return FormField<T>(
      key: ValueKey(value),
      initialValue: value,
      validator: validator,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          Material(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () async {
                final picked = await showMobileChoices<T>(
                  context,
                  title: placeholder,
                  choices: choices,
                  onAddNew: onAddNew,
                );
                if (picked != null) {
                  field.didChange(picked);
                  onChanged(picked);
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    Icon(
                      selected == null
                          ? Icons.add_circle
                          : Icons.check_circle_outline,
                      size: 19,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        selected?.label ?? placeholder,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (selected != null)
                      const Icon(Icons.expand_more, size: 18),
                  ],
                ),
              ),
            ),
          ),
          if (field.hasError)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                field.errorText!,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
