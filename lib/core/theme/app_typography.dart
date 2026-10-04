import 'package:flutter/material.dart';

/// Inter is bundled (assets/fonts) so typography works fully offline.
///
/// The scale is QuickBooks-dense: 13px body, 13.5px controls, 15-19px
/// headings. Nothing is airy — a table row, a form label and a menu entry all
/// sit in the same 13-14px band, which is what makes QBO feel like a ledger.
class AppTypography {
  AppTypography._();

  static const String family = 'Inter';

  static const TextTheme textTheme = TextTheme(
    // Display
    displayLarge: TextStyle(
      fontFamily: family,
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      height: 1.15,
    ),
    displayMedium: TextStyle(
      fontFamily: family,
      fontSize: 24,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      height: 1.2,
    ),
    displaySmall: TextStyle(
      fontFamily: family,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.25,
    ),
    // Headline
    headlineLarge: TextStyle(
      fontFamily: family,
      fontSize: 19,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.1,
      height: 1.3,
    ),
    headlineMedium: TextStyle(
      fontFamily: family,
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
    headlineSmall: TextStyle(
      fontFamily: family,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
    // Title
    titleLarge: TextStyle(
      fontFamily: family,
      fontSize: 14.5,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
    titleMedium: TextStyle(
      fontFamily: family,
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    titleSmall: TextStyle(
      fontFamily: family,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    // Body
    bodyLarge: TextStyle(
      fontFamily: family,
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.45,
    ),
    bodyMedium: TextStyle(
      fontFamily: family,
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.45,
    ),
    bodySmall: TextStyle(
      fontFamily: family,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.4,
    ),
    // Label
    labelLarge: TextStyle(
      fontFamily: family,
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      height: 1.3,
    ),
    labelMedium: TextStyle(
      fontFamily: family,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      height: 1.3,
    ),
    labelSmall: TextStyle(
      fontFamily: family,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      height: 1.3,
    ),
  );
}
