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
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onSave;
  final bool enabled;

  void _invoke() {
    // `enabled` used to be documented but never read — Ctrl+S kept firing
    // mid-save and re-entered the save path (double-submit amplifier).
    if (!enabled) return;
    onSave();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _invoke,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _invoke,
      },
      // Focus lands in the form's text fields, which live inside this
      // subtree — that is what makes the bindings fire.
      child: child,
    );
  }
}
