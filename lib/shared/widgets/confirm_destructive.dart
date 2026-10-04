import 'package:flutter/material.dart';

/// Asks the one question every irreversible action in this app asks, and
/// answers it the same way every time.
///
/// There were eleven hand-rolled `showDialog` → `AlertDialog(title, content,
/// actions)` confirmations before this, and they had already drifted: some used
/// `FilledButton.tonal` in the error colour, some a plain `TextButton`; some
/// said "Cancel" to back out, some said "Keep"; several spelled the destructive
/// button's colour from a captured `BuildContext` and several did not. Two
/// copies of this dialog is already how a destructive action ends up looking
/// like a harmless one.
///
/// Deliberately **not** a widget. It returns the answer, so callers keep their
/// own `if (confirmed != true) return;` guard and cannot accidentally swallow
/// the dialog's result in a builder's rebuild.
///
/// [title] names the thing being destroyed ("Delete 24 invoices?"), never the
/// action alone — the whole point is that the operator can tell what they are
/// about to lose from the title without reading the body.
///
/// [message] says what survives and what does not. "You can restore it later
/// from the recycle bin" is load-bearing: without it, soft-delete is
/// indistinguishable from permanent deletion, and people hesitate over
/// something reversible.
///
/// Set [confirmLabel] for actions that are not literally deletions — a cancel
/// invoice, a bounced cheque — but leave the destructive styling alone. The
/// error-coloured button is the signal that this cannot be undone by going back.
///
/// [icon] is for the handful of actions big enough to deserve a warning glyph
/// above the title — currently only restoring a backup, which replaces every
/// row in the database. Adding one is not decoration: a dialog with a glyph in
/// it reads as more serious than one without, which is the correct reading for
/// "this replaces all of your data".
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
  Widget? icon,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: icon,
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancelLabel),
        ),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed == true;
}
