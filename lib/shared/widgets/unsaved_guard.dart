import 'package:flutter/material.dart';

/// Blocks the back gesture/button while a form has unsaved input, asking the
/// user to confirm first. Wrap the editor's [Scaffold] in this and drive
/// [hasChanges] from a `setState`-flipped dirty flag.
///
/// Editors that read existing rows need this most: a stray back swipe after
/// editing one field silently discards the whole bill, and the form gives no
/// sign anything happened.
class UnsavedGuard extends StatefulWidget {
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
  State<UnsavedGuard> createState() => _UnsavedGuardState();
}

class _UnsavedGuardState extends State<UnsavedGuard> {
  /// Set once the person has confirmed the discard.
  ///
  /// [PopScope.canPop] is consulted by [Navigator.pop] at the moment the pop is
  /// attempted, so a discard confirmed *inside* [onPopInvokedWithResult] cannot
  /// pop while `canPop` is still false: the pop is vetoed, the callback fires
  /// again with `didPop == false`, and the confirm dialog reopens for ever. The
  /// route only becomes poppable once a rebuild has carried `canPop: true`,
  /// which is why this flag exists and why the pop below waits a frame.
  bool _discardApproved = false;

  bool get _canPop => _discardApproved || !widget.hasChanges;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: _onPop,
      child: widget.child,
    );
  }

  Future<void> _onPop(bool didPop, Object? result) async {
    if (didPop) return;

    // Resolved before the await: the dialog's own context is gone by the time
    // these are used again.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);

    final discard = await _confirm(context);
    if (discard != true || !mounted) return;

    setState(() => _discardApproved = true);

    // Wait for the rebuild that carries `canPop: true`, otherwise this pop is
    // vetoed by the very guard that asked the question.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      navigator.pop();
      messenger?.showSnackBar(
        const SnackBar(content: Text('Changes discarded')),
      );
    });
  }

  Future<bool> _confirm(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        content: Text(widget.message),
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