import 'package:flutter/material.dart';

import '../../core/theme/app_sizes.dart';

/// The leading or trailing glyph inside a form field.
///
/// [InputDecorator] wraps `prefixIcon`/`suffixIcon` in
/// `IconTheme.merge(IconThemeData(size: iconSize))`, where `iconSize` is a
/// hard-coded **24** (18 only when the decoration is dense). That merge sits
/// *inside* the app's `iconTheme`, so it beats it: every field glyph in the
/// product rendered at 24px while every other icon sat at 16-18.
///
/// A bare `Icon` cannot win against it, because `Icon` only falls back to the
/// ambient theme when its own `size` is null. So field icons have to state
/// their size — and this widget is how they do it, once, instead of fifty-five
/// times. (Two fields had already noticed and patched themselves with
/// `size: 18`; they were the only two that looked right.)
///
/// Size is [AppIconSize.md]: a field's glyph is a standalone affordance beside
/// a 13px label, not a decoration on a row.
class AtriaFieldIcon extends StatelessWidget {
  const AtriaFieldIcon(
    this.icon, {
    super.key,
    this.color,
    this.size = AppIconSize.md,
  });

  final IconData icon;
  final Color? color;

  /// Defaults to [AppIconSize.md]; overridable for the rare field whose slot is
  /// genuinely tighter or wider than a standard one.
  final double size;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, size: size, color: color);
}
