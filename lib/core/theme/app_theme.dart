import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_radius.dart';
import 'app_typography.dart';

/// Builds the Atria [ThemeData] for light and dark modes.
///
/// Uses an explicit [ColorScheme] (not fromSeed) so brand tones stay exact.
class AppTheme {
  AppTheme._();


  static ThemeData light() {
    final scheme = const ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.onPrimaryContainer,
      secondary: AppColors.saffron,
      onSecondary: Colors.white,
      secondaryContainer: Color(0xFFFFE8D9),
      onSecondaryContainer: Color(0xFF6B2B07),
      tertiary: AppColors.amber,
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xFFFEF0D3),
      onTertiaryContainer: Color(0xFF5C3A00),
      error: AppColors.error,
      onError: Colors.white,
      errorContainer: AppColors.errorSurface,
      onErrorContainer: Color(0xFF7F1D1D),
      surface: AppColors.surface,
      onSurface: AppColors.ink,
      surfaceContainerHighest: AppColors.surfaceVariant,
      onSurfaceVariant: AppColors.inkSecondary,
      outline: AppColors.outline,
      outlineVariant: AppColors.outline,
      shadow: Color(0x14161A18),
      scrim: Color(0x99000000),
      inverseSurface: AppColors.ink,
      onInverseSurface: AppColors.paper,
      inversePrimary: Color(0xFF93C5FD),
    );

    return _base(scheme, Brightness.light);
  }

  static ThemeData dark() {
    final scheme = const ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF93C5FD),
      onPrimary: Color(0xFF102E50),
      primaryContainer: Color(0xFF1E3A8A),
      onPrimaryContainer: Color(0xFFD5E2FF),
      secondary: AppColors.saffronLight,
      onSecondary: Color(0xFF4A1D04),
      secondaryContainer: Color(0xFF5C2A0B),
      onSecondaryContainer: Color(0xFFFFDCBE),
      tertiary: Color(0xFFFBBF24),
      onTertiary: Color(0xFF3B2500),
      tertiaryContainer: Color(0xFF5C3A00),
      onTertiaryContainer: Color(0xFFFCE9BC),
      error: Color(0xFFF87171),
      onError: Color(0xFF450A0A),
      errorContainer: Color(0xFF5C1414),
      onErrorContainer: Color(0xFFFECACA),
      surface: AppColors.darkSurface,
      onSurface: AppColors.darkInk,
      surfaceContainerHighest: AppColors.darkSurfaceVariant,
      onSurfaceVariant: AppColors.darkInkSecondary,
      outline: AppColors.darkOutline,
      outlineVariant: AppColors.darkOutline,
      shadow: Colors.black,
      scrim: Color(0xCC000000),
      inverseSurface: AppColors.darkInk,
      onInverseSurface: AppColors.darkSurface,
      inversePrimary: AppColors.primary,
    );

    return _base(scheme, Brightness.dark);
  }

  static ThemeData _base(ColorScheme scheme, Brightness brightness) {
    final isLight = brightness == Brightness.light;
    final bg = isLight ? AppColors.paper : AppColors.darkPaper;

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      brightness: brightness,
      fontFamily: AppTypography.family,
      textTheme: AppTypography.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
      primaryTextTheme: AppTypography.textTheme.apply(
        bodyColor: scheme.onPrimary,
        displayColor: scheme.onPrimary,
      ),
      // App bar
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: AppTypography.textTheme.headlineMedium?.copyWith(
          color: scheme.onSurface,
        ),
        systemOverlayStyle: isLight
            ? SystemUiOverlayStyle.dark.copyWith(
                statusBarColor: Colors.transparent,
              )
            : SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
              ),
      ),
      // Cards
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: AppColors.outline, width: 0.8),
        ),
        margin: EdgeInsets.zero,
      ),
      // Buttons
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 48),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
          ),
          side: BorderSide(color: scheme.outline, width: 1.2),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
          ),
        ),
      ),
      // Inputs
      inputDecorationTheme: _inputDecoration(scheme, isLight),
      // Lists
      listTileTheme: ListTileThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        // Colors are EXPLICIT: these raw styles replace the Material 3
        // defaults wholesale, and colorless styles left titles/subtitles
        // rendering with an unresolved fallback — the ghost text users saw
        // in light mode (Settings' Data & backup card).
        titleTextStyle: AppTypography.textTheme.titleMedium?.copyWith(
          color: scheme.onSurface,
        ),
        subtitleTextStyle: AppTypography.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      // Chips
      chipTheme: ChipThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.pill)),
        ),
        side: BorderSide(color: scheme.outline, width: 1),
        labelStyle: AppTypography.textTheme.labelMedium?.copyWith(
          color: scheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      // Dividers
      dividerTheme: DividerThemeData(
        color: scheme.outline,
        thickness: 1,
        space: 1,
      ),
      // Dialogs / bottom sheets
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.xlAll,
        ),
        titleTextStyle: AppTypography.textTheme.headlineMedium,
        contentTextStyle: AppTypography.textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
        ),
        showDragHandle: true,
        dragHandleColor: scheme.outline,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => AppTypography.textTheme.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: bg,
        elevation: 0,
        indicatorColor: scheme.primaryContainer,
        minWidth: 72,
        minExtendedWidth: 240,
        labelType: NavigationRailLabelType.all,
        selectedIconTheme: IconThemeData(color: scheme.primary, size: 22),
        unselectedIconTheme:
            IconThemeData(color: scheme.onSurfaceVariant, size: 22),
        selectedLabelTextStyle: AppTypography.textTheme.labelMedium?.copyWith(
          color: scheme.primary,
        ),
        unselectedLabelTextStyle: AppTypography.textTheme.labelMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isLight ? AppColors.ink : AppColors.darkSurfaceHigh,
        contentTextStyle: AppTypography.textTheme.bodyMedium?.copyWith(
          color: isLight ? Colors.white : AppColors.darkInk,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        elevation: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        highlightElevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        circularTrackColor: scheme.primaryContainer,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.xs - 2)),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primaryContainer,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: AppTypography.textTheme.labelLarge?.copyWith(
          color: scheme.primary,
        ),
        unselectedLabelStyle: AppTypography.textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        indicatorColor: scheme.primary,
        dividerColor: Colors.transparent,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isLight ? AppColors.ink : AppColors.darkSurfaceHigh,
          borderRadius: AppRadius.smAll,
        ),
        textStyle: AppTypography.textTheme.bodySmall?.copyWith(
          color: isLight ? Colors.white : AppColors.darkInk,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      extensions: [
        isLight ? _lightExt : _darkExt,
      ],
    );
  }

  static InputDecorationTheme _inputDecoration(
      ColorScheme scheme, bool isLight) {
    final fill = isLight
        ? const Color(0xFFFAF9F6)
        : AppColors.darkSurfaceVariant;
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      hintStyle: AppTypography.textTheme.bodyMedium
          ?.copyWith(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.outline, width: 1.2),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.primary, width: 1.8),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.error, width: 1.8),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.mdAll,
        borderSide: BorderSide(color: scheme.outline, width: 1),
      ),
      floatingLabelStyle: AppTypography.textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      alignLabelWithHint: true,
    );
  }

  // ---- ThemeExtension: semantic status colors used across the app ----
  static const AtriaColorsExtension _lightExt = AtriaColorsExtension(
    success: AppColors.success,
    onSuccess: Colors.white,
    successSurface: AppColors.successSurface,
    onSuccessSurface: Color(0xFF064E3B),
    danger: AppColors.error,
    onDanger: Colors.white,
    dangerSurface: AppColors.errorSurface,
    onDangerSurface: Color(0xFF7F1D1D),
    warning: AppColors.warning,
    onWarning: Colors.white,
    warningSurface: AppColors.warningSurface,
    onWarningSurface: Color(0xFF78350F),
    positive: AppColors.success,
    negative: AppColors.error,
    brandGradientStart: AppColors.primary,
    brandGradientEnd: AppColors.primaryDeep,
    saffronGradientStart: Color(0xFFFB923C),
    saffronGradientEnd: AppColors.saffron,
  );

  static const AtriaColorsExtension _darkExt = AtriaColorsExtension(
    success: Color(0xFF34D399),
    onSuccess: Color(0xFF052E22),
    successSurface: Color(0xFF0C3A2D),
    onSuccessSurface: Color(0xFFA7F3D0),
    danger: Color(0xFFF87171),
    onDanger: Color(0xFF450A0A),
    dangerSurface: Color(0xFF431212),
    onDangerSurface: Color(0xFFFECACA),
    warning: Color(0xFFFBBF24),
    onWarning: Color(0xFF3B2500),
    warningSurface: Color(0xFF3A2A05),
    onWarningSurface: Color(0xFFFDE68A),
    positive: Color(0xFF34D399),
    negative: Color(0xFFF87171),
    brandGradientStart: Color(0xFF60A5FA),
    brandGradientEnd: Color(0xFF1E3A8A),
    saffronGradientStart: Color(0xFFFB923C),
    saffronGradientEnd: Color(0xFFEA580C),
  );
}

/// Semantic colors exposed via [ThemeExtension].
@immutable
class AtriaColorsExtension extends ThemeExtension<AtriaColorsExtension> {
  final Color success;
  final Color onSuccess;
  final Color successSurface;
  final Color onSuccessSurface;
  final Color danger;
  final Color onDanger;
  final Color dangerSurface;
  final Color onDangerSurface;
  final Color warning;
  final Color onWarning;
  final Color warningSurface;
  final Color onWarningSurface;
  final Color positive;
  final Color negative;
  final Color brandGradientStart;
  final Color brandGradientEnd;
  final Color saffronGradientStart;
  final Color saffronGradientEnd;

  const AtriaColorsExtension({
    required this.success,
    required this.onSuccess,
    required this.successSurface,
    required this.onSuccessSurface,
    required this.danger,
    required this.onDanger,
    required this.dangerSurface,
    required this.onDangerSurface,
    required this.warning,
    required this.onWarning,
    required this.warningSurface,
    required this.onWarningSurface,
    required this.positive,
    required this.negative,
    required this.brandGradientStart,
    required this.brandGradientEnd,
    required this.saffronGradientStart,
    required this.saffronGradientEnd,
  });

  /// The app's semantic colors, resolving from the active theme.
  ///
  /// Falls back to the light extension when the enclosing [ThemeData] does not
  /// provide one — e.g. a widget rendered under a plain `MaterialApp` in a
  /// test or an isolated overlay — instead of throwing. Any Atria screen is
  /// always under [AppTheme], so this only guards the edge.
  static AtriaColorsExtension of(BuildContext context) =>
      Theme.of(context).extension<AtriaColorsExtension>() ??
      AppTheme._lightExt;

  @override
  AtriaColorsExtension copyWith({
    Color? success,
    Color? onSuccess,
    Color? successSurface,
    Color? onSuccessSurface,
    Color? danger,
    Color? onDanger,
    Color? dangerSurface,
    Color? onDangerSurface,
    Color? warning,
    Color? onWarning,
    Color? warningSurface,
    Color? onWarningSurface,
    Color? positive,
    Color? negative,
    Color? brandGradientStart,
    Color? brandGradientEnd,
    Color? saffronGradientStart,
    Color? saffronGradientEnd,
  }) {
    return AtriaColorsExtension(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successSurface: successSurface ?? this.successSurface,
      onSuccessSurface: onSuccessSurface ?? this.onSuccessSurface,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      dangerSurface: dangerSurface ?? this.dangerSurface,
      onDangerSurface: onDangerSurface ?? this.onDangerSurface,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningSurface: warningSurface ?? this.warningSurface,
      onWarningSurface: onWarningSurface ?? this.onWarningSurface,
      positive: positive ?? this.positive,
      negative: negative ?? this.negative,
      brandGradientStart: brandGradientStart ?? this.brandGradientStart,
      brandGradientEnd: brandGradientEnd ?? this.brandGradientEnd,
      saffronGradientStart: saffronGradientStart ?? this.saffronGradientStart,
      saffronGradientEnd: saffronGradientEnd ?? this.saffronGradientEnd,
    );
  }

  @override
  AtriaColorsExtension lerp(
      covariant ThemeExtension<AtriaColorsExtension>? other, double t) {
    if (other is! AtriaColorsExtension) return this;
    return AtriaColorsExtension(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successSurface: Color.lerp(successSurface, other.successSurface, t)!,
      onSuccessSurface:
          Color.lerp(onSuccessSurface, other.onSuccessSurface, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      onDanger: Color.lerp(onDanger, other.onDanger, t)!,
      dangerSurface: Color.lerp(dangerSurface, other.dangerSurface, t)!,
      onDangerSurface: Color.lerp(onDangerSurface, other.onDangerSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningSurface: Color.lerp(warningSurface, other.warningSurface, t)!,
      onWarningSurface: Color.lerp(onWarningSurface, other.onWarningSurface, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      negative: Color.lerp(negative, other.negative, t)!,
      brandGradientStart:
          Color.lerp(brandGradientStart, other.brandGradientStart, t)!,
      brandGradientEnd: Color.lerp(brandGradientEnd, other.brandGradientEnd, t)!,
      saffronGradientStart:
          Color.lerp(saffronGradientStart, other.saffronGradientStart, t)!,
      saffronGradientEnd:
          Color.lerp(saffronGradientEnd, other.saffronGradientEnd, t)!,
    );
  }
}

/// Accessor for the [AtriaColorsExtension].
AtriaColorsExtension atriaColors(BuildContext context) =>
    AtriaColorsExtension.of(context);
