import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';

/// Centres a pane's content and caps it at a reading width on a wide window.
///
/// Settings and form screens repeat this by hand — [Center] inside a
/// [LayoutBuilder], [ConstrainedBox] with a width picked per screen — and the
/// copies drift (720 on Settings, uncapped on Firm settings, 980 on the
/// statements). A phone is narrower than every cap, so there it is a no-op and
/// the child fills the pane exactly as before.
class AtriaContentWidth extends StatelessWidget {
  const AtriaContentWidth({super.key, required this.child, this.maxWidth});

  final Widget child;

  /// Ceiling on the centred column. Defaults to the window's
  /// [WindowSizeX.contentMaxWidth] — infinity below `expanded`, so a windowed
  /// desktop app is untouched and only a maximised one gets margins.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cap = maxWidth ?? constraints.contentMaxWidth;
        if (!cap.isFinite) return child;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: cap),
            child: child,
          ),
        );
      },
    );
  }
}
