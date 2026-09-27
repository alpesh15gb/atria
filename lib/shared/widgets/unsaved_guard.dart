import 'package:flutter/material.dart';

/// Blocks the back gesture/button while a form has unsaved input, asking the
/// user to confirm first. Wrap the editor's [Scaffold] in this and drive
/// [hasChanges] from a `setState`-flipped dirty flag.
///
/// Editors that read existing rows need this most: a stray back swipe after
/// editing one field silently discards the whole bill, and the form gives no
/// sign anything happened.
class UnsavedGuard extends StatelessWidget {
  const UnsavedGuard({
    super.key,
    required this.child,
    required this.hasChanges,
    this.message = 'You have unsaved changes. Discard them?',
  });

  final Widget child;
  final bool hasChanges;
  final String message;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        final navigator = Navigator.of(context);
        final discard = await _confirm(context);
        if (!discard) return;
        // Keep the navigator/messenger across the async gap: the dialog's own
        // context is gone by the time we use them.
        navigator.pop();
        messenger?.showSnackBar(
          const SnackBar(content: Text('Changes discarded')),
        );
      },
      child: child,
    );
  }

  Future<bool> _confirm(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    ).then((value) => value ?? false);
  }
}
