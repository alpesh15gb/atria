import 'package:flutter/material.dart';

/// Atria brand color tokens.
///
/// Design intent: a "peacock" teal-emerald primary signals trust and money,
/// paired with a saffron accent for energy. Warm "paper" neutrals keep the
/// surface from feeling sterile, which reads as premium on both mobile and
/// large Windows displays.
class AppColors {
  AppColors._();

  // ---- Brand ----
  // A confident blue carries the "trust and money" signal for a billing app,
  // and stays legible in both directions (see the contrast notes below).
  static const Color primary = Color(0xFF1D4ED8); // blue-700
  static const Color primaryDark = Color(0xFF1E40AF); // blue-800
  static const Color primaryDeep = Color(0xFF1E3A8A); // blue-900
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color primaryContainer = Color(0xFFDBEAFE); // blue-100
  static const Color onPrimaryContainer = Color(0xFF1E3A8A);
  static const Color primarySurface = Color(0xFFEFF6FF); // blue-50

  // Saffron accent — used sparingly for CTAs / highlights
  static const Color saffron = Color(0xFFEA580C);
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

  // ---- Light neutrals (warm paper) ----
  static const Color paper = Color(0xFFF7F6F2);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceVariant = Color(0xFFF1EFE9);
  static const Color surfaceHigh = Color(0xFFFAF9F6);
  static const Color ink = Color(0xFF161A18);
  static const Color inkSecondary = Color(0xFF555C58);
  static const Color inkTertiary = Color(0xFF7C8480);
  static const Color outline = Color(0xFFC4BFB1);
  static const Color outlineStrong = Color(0xFFADA89A);

  // ---- Dark neutrals (ink) ----
  static const Color darkPaper = Color(0xFF0B0F0E);
  static const Color darkSurface = Color(0xFF121817);
  static const Color darkSurfaceVariant = Color(0xFF1B2220);
  static const Color darkSurfaceHigh = Color(0xFF222B28);
  static const Color darkInk = Color(0xFFEDEDEA);
  static const Color darkInkSecondary = Color(0xFFA4ABA7);
  static const Color darkInkTertiary = Color(0xFF79837E);
  static const Color darkOutline = Color(0xFF28302D);
  static const Color darkOutlineStrong = Color(0xFF3A443F);

  // Brand gradient (logo, hero cards)
  static const List<Color> brandGradient = [
    Color(0xFF1D4ED8),
    Color(0xFF1E3A8A),
  ];
  static const List<Color> saffronGradient = [
    Color(0xFFFB923C),
    Color(0xFFEA580C),
  ];
}
