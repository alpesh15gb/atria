import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps an editor scaffold so Ctrl+S (Windows/Linux) or Cmd+S (macOS) fires
/// [onSave] from anywhere in the form — the desktop-native way to save
/// without reaching for the button. Does nothing while [enabled] is false
/// (e.g. mid-save).
class SaveShortcut extends StatelessWidget {
  const SaveShortcut({
    super.key,
    required this.child,
    required this.onSave,
    this.onExit,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onSave;
  final VoidCallback? onExit;
  final bool enabled;

  void _invoke() {
    // `enabled` used to be documented but never read — Ctrl+S kept firing
    // mid-save and re-entered the save path (double-submit amplifier).
    if (!enabled) return;
    onSave();
  }

  void _invokeExit(BuildContext context) {
    // `enabled` gates Escape as well as Ctrl+S: leaving a half-saved form
    // mid-save is exactly what the guard exists to stop.
    if (!enabled) return;
    // NOTE: this binding is an ANCESTOR of every field in the form, and
    // shortcut lookup walks up from the focused node — so any widget that owns
    // Escape nearer the focus (a type-ahead's suggestion list, a dialog) has
    // to consume it first or this exits the editor with its list open. The
    // shared type-ahead field does not yet, which is the known gap.
    if (onExit != null) {
      onExit!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _invoke,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _invoke,
        const SingleActivator(LogicalKeyboardKey.escape): () => _invokeExit(context),
      },
      // Focus lands in the form's text fields, which live inside this
      // subtree — that is what makes the bindings fire.
      child: child,
    );
  }
}
