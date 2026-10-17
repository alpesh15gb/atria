import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Elevation — QuickBooks parity.
///
/// QBO separates surfaces with a hairline border first and a barely-there
/// shadow second, so cards read as panels of one sheet rather than floating
/// tiles. The tokens stay in place so existing call sites keep working; they
/// are simply much quieter, and neutral-tinted instead of brand-tinted.
class AppShadows {
  AppShadows._();

  static List<BoxShadow> get card => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.06),
          blurRadius: 8,
          offset: const Offset(0, 2),
          spreadRadius: -2,
        ),
      ];

  static List<BoxShadow> get cardHigh => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.12),
          blurRadius: 20,
          offset: const Offset(0, 8),
          spreadRadius: -4,
        ),
      ];

  static List<BoxShadow> get floating => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get darkCard => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ];

  /// The one deliberately heavy shadow: the rail's "Create" button, which
  /// QBO treats as the page's loudest element.
  static List<BoxShadow> get brandCta => [
        BoxShadow(
          color: AppColors.primary.withValues(alpha: 0.28),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
      ];
}
