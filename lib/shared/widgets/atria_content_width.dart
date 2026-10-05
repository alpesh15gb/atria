import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';

/// Centres a pane's content and caps it at a reading width on a wide window.
///
/// Settings and form screens repeat this by hand — [Center] inside a
/// [LayoutBuilder], [ConstrainedBox] with a width picked per screen — and the
/// copies drift (720 on Settings, uncapped on Firm settings, 980 on the
/// statements). A phone is narrower than every cap, so there it is a no-op and
/// the child fills the pane exactly as before.
///
/// **The cap is chosen by platform, not by width, and that is the whole mobile
/// story on a tablet.** Desktop keeps the width-driven cap: infinity in a
/// window, 1280 maximised. A phone or tablet gets [PlatformUi.contentMaxWidth]
/// — 560dp — **at any window size**, so a 1260dp Android tablet shows a
/// deliberate centred phone column instead of phone cards stretched across the
/// whole screen. The reference app is phone-only and so simply never has this
/// problem; taking the cap from the width would put a tablet straight back into
/// the broken row.
///
/// **This is the one place the cap is applied.** The 560 figure sat defined in
/// `platform_ui.dart` and called from nowhere — a helper that exists and does
/// nothing is the same failure as a column that exists and is never written.
class AtriaContentWidth extends StatelessWidget {
  const AtriaContentWidth({super.key, required this.child, this.maxWidth});

  final Widget child;

  /// Ceiling on the centred column.
  ///
  /// Null — the normal case — means "whichever cap suits this platform". Passing
  /// one overrides that, which is what a screen with a genuinely different
  /// reading width wants.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    // Read through `ThemeData.platform` rather than `defaultTargetPlatform`
    // directly, so a test can declare the surface it is testing — the same way
    // the renderers decide, since a second mechanism here would let the two
    // disagree.
    final isMobile = Theme.of(context).platform.isMobileUi;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cap = maxWidth ??
            (isMobile
                ? PlatformUi.contentMaxWidth
                : constraints.contentMaxWidth);
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
