import 'package:flutter/widgets.dart';

/// Which of the app's two layouts to render.
enum UiSurface {
  /// The Android/iOS layout: cards, bottom bar, thumb-reachable actions.
  mobile,

  /// The Windows layout: side rail, dense tables, keyboard-driven.
  desktop,
}

/// Decides whether this is the mobile layout or the desktop one.
///
/// Deliberately keyed on [TargetPlatform] and **not** on `dart:io`'s
/// `Platform.isAndroid`. Under `flutter test` `Platform` reports the *host*
/// OS, so on a Windows machine every mobile assertion would silently exercise
/// the desktop widget and pass — then fail on the device. `defaultTargetPlatform`
/// is overridable through the test dispatcher, which is what makes the mobile
/// tree testable at all.
///
/// Width used to decide this. It gets two cases wrong:
///
/// - a Windows window dragged narrow got the phone layout, tables squeezed
///   into a column you had to scroll sideways;
/// - a large Android tablet got the desktop layout, cards stretched wide.
///
/// Keying on platform makes each platform's UI stable at any window size.
/// Within the mobile surface, [contentMaxWidth] still caps how wide a card may
/// grow, so a tablet centres a phone column instead of stretching it.
extension PlatformUi on TargetPlatform {
  /// Whether this platform renders the mobile layout.
  bool get isMobileUi =>
      this == TargetPlatform.android || this == TargetPlatform.iOS;

  /// The layout surface for this platform.
  UiSurface get uiSurface => isMobileUi ? UiSurface.mobile : UiSurface.desktop;

  /// Widest the mobile layout should grow before it centres instead.
  ///
  /// A phone column stretched across a 1260dp tablet reads as broken, so the
  /// mobile surface stops at this and centres the remainder. Desktop is not
  /// affected — it keeps its own width-driven content cap.
  static const double contentMaxWidth = 560;
}

/// [PlatformUi.contentMaxWidth] — for the many widgets that only have
/// [BoxConstraints] in hand.
double mobileContentCap(BoxConstraints constraints) =>
    constraints.maxWidth > PlatformUi.contentMaxWidth
        ? PlatformUi.contentMaxWidth
        : constraints.maxWidth;