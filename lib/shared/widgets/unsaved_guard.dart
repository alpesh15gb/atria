import 'package:flutter/material.dart';

import 'confirm_destructive.dart';

/// Whether **somewhere in the app** an editor currently holds unsaved changes.
///
/// [UnsavedGuard] is only a `PopScope`, and `PopScope` is consulted by
/// `Navigator.pop` / `maybePop` — nothing else. Every piece of app chrome that
/// navigates with `context.go` (the left rail, the mobile bottom bar, the More
/// sheet, the top-bar business switcher and global search) **replaces the match
/// list**, so the editor route is disposed rather than popped and the guard
/// never fires: type an invoice, click another destination, and the whole
/// document is gone with no prompt. The editors sit inside a
/// `StatefulShellBranch`, so their routes are children of the very shell whose
/// chrome is doing the navigating.
///
/// This is that missing signal. The guard registers itself here while it is
/// armed, and the chrome asks before it navigates.
class UnsavedChanges {
  UnsavedChanges._();

  static final ValueNotifier<bool> _armed = ValueNotifier<bool>(false);

  /// True while at least one [UnsavedGuard] is holding changes.
  static bool get isArmed => _armed.value;

  static void _set(bool value) {
    if (_armed.value != value) _armed.value = value;
  }

  /// Whether this particular guard is the one currently registered.
  static bool isArmedBy(UnsavedGuard guard) => _armed.value;

  /// Asks the operator before discarding, using the app's one confirmation
  /// helper so the wording is the same everywhere.
  ///
  /// Returns true when it is safe to navigate on.
  static Future<bool> confirmLeave(BuildContext context) async {
    if (!_armed.value) return true;
    final ok = await confirmDestructive(
      context,
      title: 'Leave without saving?',
      message: 'You have unsaved changes. They will be lost if you leave.',
      confirmLabel: 'Discard',
    );
    // Navigating disposes the guard either way; clearing the flag here stops a
    // second chrome tap from stacking a second dialog on top of the first.
    if (ok) _set(false);
    return ok;
  }
}

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

  /// True while this guard is the one mounted and holding changes.
  bool _isActive = false;

  bool get _canPop => _discardApproved || !widget.hasChanges;

  @override
  void dispose() {
    // Releasing the registration on dispose is what stops a guard for a
    // *closed* editor from blocking navigation somewhere else.
    if (_isActive) {
      _isActive = false;
      UnsavedChanges._set(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Registered from `build` rather than from a callback so the flag is correct
    // the instant the frame lands — a `didChangeDependencies` registration would
    // lag `hasChanges` by one rebuild and miss the tap that follows an edit.
    final armed = widget.hasChanges && !_discardApproved;
    if (armed != _isActive) {
      _isActive = armed;
      UnsavedChanges._set(armed);
    }
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