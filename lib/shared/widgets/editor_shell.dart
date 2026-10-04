import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_sizes.dart';

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
/// The body is the caller's; typically [EditorShellBody] wrapping an
/// [AtriaEditorForm]. Pass [hint] to pin the keyboard model to the bottom of a
/// desktop window — the fastest way to make an app feel like a spreadsheet is
/// to say, in one quiet line, that it behaves like one.
class EditorShell extends StatelessWidget {
  const EditorShell({
    super.key,
    required this.title,
    required this.actions,
    required this.body,
    this.hint,
  });

  final String title;
  final EditorActions actions;
  final Widget body;

  /// One-line keyboard reminder shown in a slim bar above the bottom edge on
  /// desktop widths. Hidden on phones, where there is no keyboard.
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.compact;
    final showHint = hint != null && wide;
    return Scaffold(
      appBar: _EditorAppBar(title: title, actions: actions, wide: wide),
      body: showHint
          ? Column(
              children: [
                Expanded(child: body),
                _KeyboardHintBar(hint: hint!),
              ],
            )
          : body,
      bottomNavigationBar: EditorBottomBar(
        onSave: actions.onSave,
        onSaveAndNew: actions.onSaveAndNew,
        saving: actions.saving,
        saveLabel: actions.saveLabel,
        saveAndNewLabel: actions.saveAndNewLabel,
      ),
    );
  }
}

/// The editor's primary action, pinned to the bottom edge on a phone.
///
/// On a phone the Save button leaves the app bar for this bar, because the one
/// control a user reaches for mid-entry was the single worst-placed thing on
/// the screen: top-right of a 412px viewport, under the hand that is holding
/// the phone. Every editor now saves with a thumb.
///
/// Renders nothing at or above [Breakpoints.compact], so a desktop keeps the
/// app-bar pair and a screen can pass this unconditionally.
class EditorBottomBar extends StatelessWidget {
  const EditorBottomBar({
    super.key,
    required this.onSave,
    this.onSaveAndNew,
    this.saving = false,
    this.saveLabel,
    this.saveAndNewLabel,
  });

  final VoidCallback onSave;
  final VoidCallback? onSaveAndNew;
  final bool saving;
  final String? saveLabel;
  final String? saveAndNewLabel;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width >= Breakpoints.compact) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final saveAndNew = onSaveAndNew;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.sm,
        ),
        child: Row(
          children: [
            if (saveAndNew != null) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: saving ? null : saveAndNew,
                  child: Text(
                    saveAndNewLabel ?? 'Save and new',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            Expanded(
              child: FilledButton(
                onPressed: saving ? null : onSave,
                child: saving
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.onPrimary,
                        ),
                      )
                    : Text(
                        saveLabel ?? 'Save and close',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The quiet bottom strip that documents the editor's keyboard model.
class _KeyboardHintBar extends StatelessWidget {
  const _KeyboardHintBar({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      child: Row(
        children: [
          Icon(
            Icons.keyboard_alt_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
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
    // Same rule as [EditorShell]: on a phone the Save button belongs in
    // [EditorBottomBar], which the screen supplies as its bottomNavigationBar.
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.compact;

    return AppBar(
      leading: IconButton(
        tooltip: 'Exit',
        icon: const Icon(Icons.close_rounded),
        onPressed: saving ? null : () => Navigator.of(context).maybePop(),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        ...actions,
        if (wide)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.md),
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
                  : const Text('Save and close'),
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
        onPressed: actions.saving
            ? null
            : () => Navigator.of(context).maybePop(),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      // On a phone both buttons live in [EditorBottomBar] instead, under the
      // thumb — and the title gets the width back.
      actions: [
        if (wide && actions.onSaveAndNew != null)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.sm),
            child: FilledButton.tonal(
              onPressed: actions.saving ? null : actions.onSaveAndNew,
              child: Text(actions.saveAndNewLabel ?? 'Save and new'),
            ),
          ),
        if (wide)
          Padding(
            padding: const EdgeInsets.only(right: AppSpace.md),
            child: FilledButton(
              onPressed: actions.saving ? null : actions.onSave,
              child: actions.saving
                  ? saveSpinner
                  : Text(actions.saveLabel ?? 'Save and close'),
            ),
          ),
      ],
    );
  }
}

/// The one-page editor body: a single column with no side rail, used now that
/// every document's totals sit inside the form itself (right-aligned, under
/// the last line) instead of in a sticky panel the eye has to travel back to
/// on every edit.
///
/// The column fills the pane, and the form owns its own page gutters (see
/// [AtriaEditorForm]), so a maximised window is spent on the line grid rather
/// than on two grey margins. Pass a finite [maxFormWidth] only for a form that
/// must stay narrow — a single figure, not a table.
class EditorShellBody extends StatelessWidget {
  const EditorShellBody({
    super.key,
    required this.form,
    this.maxFormWidth = double.infinity,
  });

  final Widget form;
  final double maxFormWidth;

  @override
  Widget build(BuildContext context) {
    if (!maxFormWidth.isFinite) return form;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxFormWidth),
        child: form,
      ),
    );
  }
}
