import 'package:flutter/material.dart';

/// Atria brand color tokens — 2026 "modern fintech" refresh.
///
/// Design intent: a deep violet-indigo primary (the reference language of
/// contemporary finance apps) paired with soft lilac containers and a warm
/// coral accent. Violet reads premium and modern while staying fully
/// accessible; neutrals are cool-tinted so surfaces feel crisp, not beige.
class AppColors {
  AppColors._();

  // ---- Brand ----
  static const Color primary = Color(0xFF6D28D9); // violet-700
  static const Color primaryDark = Color(0xFF5B21B6); // violet-800
  static const Color primaryDeep = Color(0xFF4C1D95); // violet-900
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color primaryContainer = Color(0xFFEDE9FE); // violet-100
  static const Color onPrimaryContainer = Color(0xFF4C1D95);
  static const Color primarySurface = Color(0xFFF5F3FF); // violet-50

  // Coral accent — CTAs / highlights (replaces saffron)
  static const Color saffron = Color(0xFFF97316); // orange-500
  static const Color saffronLight = Color(0xFFFDBA74);
  static const Color amber = Color(0xFFF59E0B);

  // ---- Semantic ----
  static const Color success = Color(0xFF059669);
  static const Color successSurface = Color(0xFFD1FAE5);
  static const Color error = Color(0xFFDC2626);
  static const Color errorSurface = Color(0xFFFEE2E2);
  static const Color warning = Color(0xFFD97706);
  static const Color warningSurface = Color(0xFFFEF3C7);
  static const Color info = Color(0xFF2563EB);
  static const Color infoSurface = Color(0xFFDBEAFE);

  // ---- Light neutrals (cool paper) ----
  static const Color paper = Color(0xFFF6F5FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceVariant = Color(0xFFEEECF5);
  static const Color surfaceHigh = Color(0xFFFAF9FD);
  static const Color ink = Color(0xFF16141F);
  static const Color inkSecondary = Color(0xFF565263);
  static const Color inkTertiary = Color(0xFF7D7889);
  static const Color outline = Color(0xFFD4D0E0);
  static const Color outlineStrong = Color(0xFFB9B4CC);

  // ---- Dark neutrals (violet-tinted ink) ----
  static const Color darkPaper = Color(0xFF0C0A12);
  static const Color darkSurface = Color(0xFF14111D);
  static const Color darkSurfaceVariant = Color(0xFF1E1930);
  static const Color darkSurfaceHigh = Color(0xFF272040);
  static const Color darkInk = Color(0xFFEDEBF4);
  static const Color darkInkSecondary = Color(0xFFA6A1B8);
  static const Color darkInkTertiary = Color(0xFF7E7890);
  static const Color darkOutline = Color(0xFF2A2340);
  static const Color darkOutlineStrong = Color(0xFF3D3459);

  // Brand gradients (logo, hero cards, rail CTA)
  static const List<Color> brandGradient = [
    Color(0xFF7C3AED), // violet-600
    Color(0xFF4C1D95), // violet-900
  ];
  static const List<Color> saffronGradient = [
    Color(0xFFFB923C),
    Color(0xFFEA580C),
  ];

  /// The hero-card gradient: violet core with a warm ember tail, echoing the
  /// reference's signature card.
  static const List<Color> heroGradient = [
    Color(0xFF7C3AED),
    Color(0xFF5B21B6),
    Color(0xFF2E1065),
  ];
}
