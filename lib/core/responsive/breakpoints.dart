import 'package:flutter/widgets.dart';

/// Layout breakpoints. The app must feel native on a 360dp phone and on a
/// 1920dp Windows window, so every layout decision funnels through these.
class Breakpoints {
  Breakpoints._();

  /// Phones in portrait.
  static const double compact = 600;

  /// Small tablets / phones in landscape.
  static const double medium = 840;

  /// Tablets and narrow desktop windows.
  static const double expanded = 1200;

  /// Wide desktop windows.
  static const double large = 1600;
}

enum WindowSize { compact, medium, expanded, large }

extension WindowSizeX on BoxConstraints {
  /// The coarsest layout bucket for the available width.
  WindowSize get windowSize {
    if (maxWidth < Breakpoints.compact) return WindowSize.compact;
    if (maxWidth < Breakpoints.medium) return WindowSize.medium;
    if (maxWidth < Breakpoints.expanded) return WindowSize.expanded;
    return WindowSize.large;
  }

  bool get isCompact => maxWidth < Breakpoints.compact;
  bool get isMedium =>
      maxWidth >= Breakpoints.compact && maxWidth < Breakpoints.medium;
  bool get isExpanded =>
      maxWidth >= Breakpoints.medium && maxWidth < Breakpoints.expanded;
  bool get isLarge => maxWidth >= Breakpoints.expanded;

  /// Whether the two-pane "master-detail" pattern should be used.
  bool get supportsTwoPane => maxWidth >= Breakpoints.medium;

  /// Ideal content max width for readable line lengths on large screens.
  double get contentMaxWidth => isLarge ? 1280 : double.infinity;
}
