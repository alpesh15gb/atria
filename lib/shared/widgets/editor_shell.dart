import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';

/// Actions the [EditorShell] action bar offers.
class EditorActions {
  const EditorActions({
    required this.onSave,
    required this.onExit,
    this.onSaveAndNew,
    this.saving = false,
    this.saveLabel,
    this.saveAndNewLabel,
  });

  final VoidCallback onSave;

  /// Where "back" goes — usually `context.pop()`.
  final VoidCallback onExit;

  /// When set, a secondary "Save & New" action appears (desktop widths).
  final VoidCallback? onSaveAndNew;

  final bool saving;
  final String? saveLabel;
  final String? saveAndNewLabel;
}

/// The shared create/edit chrome: a sticky top action bar — exit on the left,
/// document title, then Save & New (secondary) and Save (primary) on the
/// right, mirroring the desktop billing suites. On phone widths only Save
/// stays in the bar so the title never starves.
///
/// The body is the caller's; build it with [EditorShell.twoPaneBody] to get
/// the form-plus-sticky-summary split on desktop automatically.
class EditorShell extends StatelessWidget {
  const EditorShell({
    super.key,
    required this.title,
    required this.actions,
    required this.body,
    this.floatingActionButton,
  });

  final String title;
  final EditorActions actions;
  final Widget body;

  /// On compact widths the shell may want a FAB (there is no sticky summary
  /// panel there); pass null to disable.
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.compact;
    return Scaffold(
      appBar: _EditorAppBar(title: title, actions: actions, wide: wide),
      body: body,
      floatingActionButton: wide ? null : floatingActionButton,
    );
  }
}

/// A lighter action bar for the simple single-column editors (item, party,
/// expense): same exit + Save identity, plus optional leading-edge [actions]
/// (e.g. the barcode-labels button on the item editor).
class EditorAppBar extends StatelessWidget implements PreferredSizeWidget {
  const EditorAppBar({
    super.key,
    required this.title,
    required this.onSave,
    required this.onExit,
    this.actions = const <Widget>[],
    this.saving = false,
    this.enabled = true,
  });

  final String title;
  final VoidCallback onSave;
  final VoidCallback onExit;
  final List<Widget> actions;
  final bool saving;
  final bool enabled;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        tooltip: 'Exit',
        icon: const Icon(Icons.close_rounded),
        onPressed: saving ? null : onExit,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        ...actions,
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton(
            onPressed: saving || !enabled ? null : onSave,
            child: saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  )
                : const Text('Save'),
          ),
        ),
      ],
    );
  }
}

class _EditorAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _EditorAppBar({
    required this.title,
    required this.actions,
    required this.wide,
  });

  final String title;
  final EditorActions actions;
  final bool wide;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final saveSpinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    );

    return AppBar(
      leading: IconButton(
        tooltip: 'Exit',
        icon: const Icon(Icons.close_rounded),
        onPressed: actions.saving ? null : actions.onExit,
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (wide && actions.onSaveAndNew != null)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.tonal(
              onPressed: actions.saving ? null : actions.onSaveAndNew,
              child: Text(actions.saveAndNewLabel ?? 'Save & New'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: FilledButton(
            onPressed: actions.saving ? null : actions.onSave,
            child: actions.saving
                ? saveSpinner
                : Text(actions.saveLabel ?? 'Save'),
          ),
        ),
      ],
    );
  }
}

/// Splits an editor body into the scrollable form (left / top) and a sticky
/// summary panel (right / bottom). On desktop both are visible at once — the
/// totals never scroll away while the user edits lines; on phones the panel
/// sits under the form and the caller's FAB does the saving.
class EditorShellBody extends StatelessWidget {
  const EditorShellBody({
    super.key,
    required this.form,
    required this.summary,
    this.maxFormWidth = 760,
  });

  final Widget form;
  final Widget summary;
  final double maxFormWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = !constraints.isCompact;
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 7,
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxFormWidth),
                    child: form,
                  ),
                ),
              ),
              VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outline),
              Expanded(
                flex: 4,
                child: summary,
              ),
            ],
          );
        }
        return Column(
          children: [
            Expanded(child: form),
            summary,
          ],
        );
      },
    );
  }
}
