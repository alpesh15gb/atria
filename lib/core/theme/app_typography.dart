import 'package:flutter/material.dart';

/// Inter is bundled (assets/fonts) so typography works fully offline.
class AppTypography {
  AppTypography._();

  static const String family = 'Inter';

  static const TextTheme textTheme = TextTheme(
    // Display
    displayLarge: TextStyle(
      fontFamily: family,
      fontSize: 34,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.5,
      height: 1.15,
    ),
    displayMedium: TextStyle(
      fontFamily: family,
      fontSize: 27,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      height: 1.2,
    ),
    displaySmall: TextStyle(
      fontFamily: family,
      fontSize: 22,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
      height: 1.25,
    ),
    // Headline
    headlineLarge: TextStyle(
      fontFamily: family,
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.3,
    ),
    headlineMedium: TextStyle(
      fontFamily: family,
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.15,
      height: 1.35,
    ),
    headlineSmall: TextStyle(
      fontFamily: family,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    // Title
    titleLarge: TextStyle(
      fontFamily: family,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.4,
    ),
    titleMedium: TextStyle(
      fontFamily: family,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.45,
    ),
    titleSmall: TextStyle(
      fontFamily: family,
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.45,
    ),
    // Body
    bodyLarge: TextStyle(
      fontFamily: family,
      fontSize: 15,
      fontWeight: FontWeight.w400,
      height: 1.5,
    ),
    bodyMedium: TextStyle(
      fontFamily: family,
      fontSize: 13.5,
      fontWeight: FontWeight.w400,
      height: 1.5,
    ),
    bodySmall: TextStyle(
      fontFamily: family,
      fontSize: 12,
      fontWeight: FontWeight.w400,
      height: 1.45,
    ),
    // Label
    labelLarge: TextStyle(
      fontFamily: family,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      height: 1.4,
    ),
    labelMedium: TextStyle(
      fontFamily: family,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      height: 1.4,
    ),
    labelSmall: TextStyle(
      fontFamily: family,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
      height: 1.4,
    ),
  );
}
