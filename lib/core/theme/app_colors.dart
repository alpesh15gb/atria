import 'package:flutter/material.dart';

/// Apex Books color tokens — QuickBooks Online parity.
///
/// Design intent: Intuit's accounting language. A single saturated brand
/// **green** carries every primary action and the active navigation state,
/// links are **Intuit blue**, and everything else is a neutral grey ramp over
/// a `#F4F5F7` page with hairline `#D4D7DC` borders. Colour is therefore
/// information, not decoration: green means "primary/paid", blue means
/// "a link/informational", red means "overdue/danger".
///
/// The token *names* are the app-wide contract (every screen reads them via
/// [ColorScheme] / `atriaColors`), so the palette can move without touching a
/// screen.
class AppColors {
  AppColors._();

  // ---- Brand (QuickBooks green) ----
  static const Color primary = Color(0xFF2CA01C); // QBO green
  static const Color primaryDark = Color(0xFF248615); // hover / pressed
  static const Color primaryDeep = Color(0xFF14690B); // deep green (gradient tail)
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color primaryContainer = Color(0xFFE4F1E0); // selected-row tint
  static const Color onPrimaryContainer = Color(0xFF14690B);
  static const Color primarySurface = Color(0xFFF2F8F0);

  // Link / informational blue — QBO's secondary action colour.
  //
  // A notch darker than Intuit's #0077C5, which measures 4.33:1 on the
  // #F4F5F7 page — just under WCAG AA for body text, and every quiet action in
  // the product ("View all", "Reports", "Skip") is that colour on that page.
  // #0068AC is 5.38:1 on the page and 5.87:1 on white, and reads as the same
  // blue next to the brand green.
  static const Color link = Color(0xFF0068AC);
  static const Color linkSurface = Color(0xFFE6F1F8);

  // Amber accent — CTAs / highlights (replaces saffron)
  static const Color saffron = Color(0xFFD68B00); // QBO amber
  static const Color saffronLight = Color(0xFFF0B860);
  static const Color amber = Color(0xFFF0A000);

  // ---- Semantic ----
  static const Color success = Color(0xFF218214);
  static const Color successSurface = Color(0xFFE4F1E0);
  static const Color error = Color(0xFFE43834); // QBO red
  static const Color errorSurface = Color(0xFFFCE9E8);
  static const Color warning = Color(0xFFC77700);
  static const Color warningSurface = Color(0xFFFDF1DC);
  static const Color info = link;
  static const Color infoSurface = Color(0xFFE6F1F8);

  // ---- Light neutrals (QBO grey ramp) ----
  static const Color paper = Color(0xFFF4F5F7); // page background
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceVariant = Color(0xFFF4F5F7); // field fill / table head
  static const Color surfaceHigh = Color(0xFFFAFAFB);
  static const Color ink = Color(0xFF393A3D); // QBO body text
  static const Color inkSecondary = Color(0xFF6B6C72);
  static const Color inkTertiary = Color(0xFF8C8F94);
  static const Color outline = Color(0xFFD4D7DC); // hairline border
  static const Color outlineStrong = Color(0xFF8C8F94);

  // ---- Dark neutrals (neutral charcoal, no violet cast) ----
  static const Color darkPaper = Color(0xFF16171A);
  static const Color darkSurface = Color(0xFF1F2124);
  static const Color darkSurfaceVariant = Color(0xFF2A2C30);
  static const Color darkSurfaceHigh = Color(0xFF34363B);
  static const Color darkInk = Color(0xFFE8E9EB);
  static const Color darkInkSecondary = Color(0xFFB0B3B8);
  static const Color darkInkTertiary = Color(0xFF85888E);
  static const Color darkOutline = Color(0xFF34363B);
  static const Color darkOutlineStrong = Color(0xFF4A4D53);

  // Brand gradients (logo, hero cards, rail CTA).
  //
  // QuickBooks does not use gradients: the brand is a flat green. These stay
  // two-stop lists so the existing call sites keep working, but both stops are
  // the same family, which renders flat.
  static const List<Color> brandGradient = [
    Color(0xFF2CA01C),
    Color(0xFF218214),
  ];
  static const List<Color> saffronGradient = [
    Color(0xFFF0B860),
    Color(0xFFD68B00),
  ];

  /// The hero-card treatment: QBO's dark charcoal chrome band — the one place
  /// the product goes dark, so the money strip on the dashboard reads as a
  /// summary bar rather than decoration.
  static const List<Color> heroGradient = [
    Color(0xFF3D3E42),
    Color(0xFF2B2C2F),
  ];
}
