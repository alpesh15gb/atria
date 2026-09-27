import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Soft, diffused elevation — 2026 refresh. Shadows are violet-tinted and
/// larger-blurred so cards float instead of sitting in outlines.
class AppShadows {
  AppShadows._();

  static List<BoxShadow> get card => [
        BoxShadow(
          color: AppColors.primaryDeep.withValues(alpha: 0.05),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: AppColors.primaryDeep.withValues(alpha: 0.03),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];

  static List<BoxShadow> get cardHigh => [
        BoxShadow(
          color: AppColors.primaryDeep.withValues(alpha: 0.10),
          blurRadius: 32,
          offset: const Offset(0, 14),
        ),
        BoxShadow(
          color: AppColors.primaryDeep.withValues(alpha: 0.05),
          blurRadius: 8,
          offset: const Offset(0, 4),
        ),
      ];

  static List<BoxShadow> get floating => [
        BoxShadow(
          color: AppColors.primary.withValues(alpha: 0.35),
          blurRadius: 36,
          offset: const Offset(0, 16),
        ),
      ];

  static List<BoxShadow> get darkCard => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.4),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
      ];
}
