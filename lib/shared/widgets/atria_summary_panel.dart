import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';

/// A high-emphasis financial surface. The local theme keeps every nested
/// amount, label and icon readable regardless of the surrounding page theme.
class AtriaSummaryPanel extends StatelessWidget {
  const AtriaSummaryPanel({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: AppRadius.lgAll,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppColors.heroGradient,
        ),
      ),
      child: Theme(
        data: AppTheme.dark(),
        child: Builder(builder: builder),
      ),
    );
  }
}
