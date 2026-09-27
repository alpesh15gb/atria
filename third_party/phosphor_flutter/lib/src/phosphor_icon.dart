library phosphor_flutter;

import 'package:flutter/material.dart';

/// Patched for Flutter 3.47+: the duotone two-layer branch is gone.
///
/// The original build() special-cased [PhosphorDuotoneIconData], which subclassed
/// `IconData`. Since `IconData` is now `final`, the duotone data class no longer
/// exists in this vendored copy (duotone icons resolve to a single-layer
/// [IconData] glyph from `Phosphor-Duotone.ttf`), so the widget is now a plain
/// [Icon]. The app only uses the Regular and Fill styles.
class PhosphorIcon extends Icon {
  const PhosphorIcon(
    IconData icon, {
    Key? key,
    double? size,
    double? fill,
    double? weight,
    double? grade,
    double? opticalSize,
    Color? color,
    List<Shadow>? shadows,
    String? semanticLabel,
    TextDirection? textDirection,
    this.duotoneSecondaryOpacity = 0.20,
    this.duotoneSecondaryColor,
  }) : super(
          icon,
          color: color,
          fill: fill,
          grade: grade,
          key: key,
          opticalSize: opticalSize,
          semanticLabel: semanticLabel,
          shadows: shadows,
          size: size,
          textDirection: textDirection,
          weight: weight,
        );

  final double duotoneSecondaryOpacity;
  final Color? duotoneSecondaryColor;
}
