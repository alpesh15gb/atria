import 'package:flutter/material.dart';

import '../../core/responsive/platform_ui.dart';
import '../../core/theme/app_sizes.dart';

/// The mobile list **+ FAB** — the reference's one always-there create action.
///
/// A rounded square, bottom-right, above the navigation bar. Desktop has none:
/// there the page's primary action lives in its own header, and
/// `ui_structure_regression_test.dart`'s "there is no FAB" assertion is about
/// that surface and stays true.
///
/// **It renders nothing on desktop** rather than refusing to build, so a list
/// screen can name it unconditionally in its `floatingActionButton:` slot and
/// leave the desktop tree untouched. The desktop `Scaffold` lays out a zero box,
/// which costs nothing — the alternative, a `Widget?` decided by a helper
/// outside `build`, would need the `BuildContext` it does not have, and putting
/// the same `isMobileUi` test in two places is how the two disagree.
class MobileFab extends StatelessWidget {
  const MobileFab({super.key, required this.onPressed, this.tooltip});

  final VoidCallback onPressed;
  final String? tooltip;

  /// 56dp — the Material standard, and what the reference ships.
  ///
  /// Not on [AppIconSize] because it is a box, not a glyph.
  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    if (!Theme.of(context).platform.isMobileUi) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: FloatingActionButton(
        onPressed: onPressed,
        tooltip: tooltip,
        elevation: 2,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        // The reference's FAB reads as a rounded **square**, not a circle, and
        // the squircle is a real part of its look. Material's default is a
        // circle, so the shape is set rather than left alone.
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(size / 4),
        ),
        child: const Icon(Icons.add_rounded, size: AppIconSize.xl),
      ),
    );
  }
}