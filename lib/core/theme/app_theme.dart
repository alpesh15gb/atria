import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_radius.dart';
import 'app_sizes.dart';
import 'app_typography.dart';

/// Builds the Apex Books [ThemeData] for light and dark modes.
///
/// Uses an explicit [ColorScheme] (not fromSeed) so brand tones stay exact.
class AppTheme {
  AppTheme._();


  /// The lift on every floating panel: menus, popovers, and the pickers that
  /// borrow their surface. Material's own default for a menu is 8, which reads
  /// as a different product beside the app's hairline cards.
  static const double menuElevation = 3;

  /// The surface shape of every floating panel in the app.
  ///
  /// The hairline side is load-bearing, not decoration. A popup route has no
  /// barrier, so a menu, a type-ahead or a dropdown lands on the page
  /// undimmed — and several pages are the very same white as the panel: the
  /// dashboard's header band (a white `SliverAppBar` under a white chrome
  /// band) and the editors. A drop shadow alone does not part them (the app's
  /// shadow is an 8% grey, about one part in 255 above a panel), so the
  /// panel's own edge vanished and the page's greeting and business name read
  /// *through* the open menu: the menu looked transparent. Cards, app bars and
  /// the chrome band all separate with a hairline for the same reason.
  ///
  /// Dialogs and modal sheets are deliberately excluded: their barrier dims
  /// the page, and that dimming is their edge.
  static RoundedRectangleBorder menuShape(ColorScheme scheme) =>
      RoundedRectangleBorder(
        borderRadius: AppRadius.mdAll,
        side: BorderSide(color: scheme.outline),
      );

  static ThemeData light() {
    final scheme = const ColorScheme(
      brightness: Brightness.light,
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.primaryContainer,
      onPrimaryContainer: AppColors.onPrimaryContainer,
      secondary: AppColors.link,
      onSecondary: Colors.white,
      secondaryContainer: AppColors.linkSurface,
      onSecondaryContainer: Color(0xFF005A96),
      tertiary: AppColors.amber,
      onTertiary: Colors.white,
      tertiaryContainer: AppColors.warningSurface,
      onTertiaryContainer: Color(0xFF6B4200),
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
      shadow: Color(0x14393A3D),
      scrim: Color(0x99000000),
      inverseSurface: AppColors.ink,
      onInverseSurface: AppColors.paper,
      inversePrimary: Color(0xFF7FD46F),
    );

    return _base(scheme, Brightness.light);
  }

  static ThemeData dark() {
    final scheme = const ColorScheme(
      brightness: Brightness.dark,
      primary: Color(0xFF56C246), // QBO green, lightened for dark surfaces
      onPrimary: Color(0xFF0C2E06),
      primaryContainer: Color(0xFF1E4A16),
      onPrimaryContainer: Color(0xFFC9EAC3),
      secondary: Color(0xFF6FB8E8), // link blue on dark
      onSecondary: Color(0xFF06283E),
      secondaryContainer: Color(0xFF143A55),
      onSecondaryContainer: Color(0xFFCDE8F8),
      tertiary: Color(0xFFF0B860),
      onTertiary: Color(0xFF3B2500),
      tertiaryContainer: Color(0xFF4A3208),
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
      // NOT `Colors.black`, which is what a Material 3 scheme defaults to.
      // Material draws its elevation shadow with `canvas.drawShadow`, which
      // scales the drawn shadow by this colour's alpha — so an opaque shadow
      // colour paints an almost solid black band around every raised surface.
      // The light scheme already sits at 8% (`0x14393A3D`); this matches the
      // app's own dark card shadow, `AppShadows.darkCard`, at 50%.
      shadow: Color(0x80000000),
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
    final menuShape = AppTheme.menuShape(scheme);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      // Panels are the surface colour; only the *page* is grey. This is also
      // the colour `DropdownButton` paints its menu with (`dropdownColor ??
      // canvasColor`) — there is no `DropdownButtonTheme` in this Flutter
      // version, so this is the app-wide knob for every dropdown menu and for
      // the SDK's default autocomplete suggestions. Set to the page grey it
      // opened a panel the same colour as the page it covered, defined only by
      // Material 2's drop shadow.
      canvasColor: scheme.surface,
      brightness: brightness,
      fontFamily: AppTypography.family,
      // A bare `Icon` used to fall through to Material's 24px default, so a
      // widget that forgot a size was 24 while everything around it was 16-18.
      // Now it lands on the scale (see [AppIconSize]).
      iconTheme: IconThemeData(
        size: AppIconSize.fallback,
        color: scheme.onSurfaceVariant,
      ),
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
        // QBO's header band is a white strip with a hairline under it, sitting
        // on a grey page.
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        shape: Border(bottom: BorderSide(color: scheme.outline)),
        titleTextStyle: AppTypography.textTheme.headlineMedium?.copyWith(
          color: scheme.onSurface,
        ),
        // App bars carry their own icon theme, so without this their actions
        // fell back to Material's 24px default while the rest of the app sat
        // at 16-18. The audit counted 146 icons at the wrong size because of
        // it — every AppBar action on every editor and settings screen.
        iconTheme: IconThemeData(
          size: AppIconSize.md,
          color: scheme.onSurface,
        ),
        actionsIconTheme: IconThemeData(
          size: AppIconSize.md,
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
      // Cards — QBO: a hairline border does the separation, not elevation.
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: scheme.outline),
        ),
        margin: EdgeInsets.zero,
      ),
      // Buttons
      //
      // Filled buttons are the app's primary action. `primaryDark` rather than
      // `primary` for the fill: white on Intuit's #2CA01C is 3.41:1, which
      // fails WCAG AA at this text size, and white on #248615 is 4.67:1. The
      // brand green is unchanged everywhere it is a brand mark or an accent —
      // only the *button fill* moves, which is also QBO's own hover tone.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 40),
          backgroundColor: isLight ? AppColors.primaryDark : scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.smAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, 40),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.smAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.smAll,
          ),
          side: BorderSide(color: scheme.outline),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      // QBO's quiet actions are blue links, not grey buttons.
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isLight ? AppColors.link : const Color(0xFF6FB8E8),
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.smAll,
          ),
          textStyle: AppTypography.textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          shape: const RoundedRectangleBorder(
            borderRadius: AppRadius.smAll,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
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
      // Menus — the filter selects, the kebab menus and the Create menu all
      // route through these. Material's defaults gave them a 4px radius and an
      // 8px elevation, so they read as a different surface than every card.
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: menuElevation,
        shape: menuShape,
        textStyle: AppTypography.textTheme.bodyMedium,
        position: PopupMenuPosition.under,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(menuElevation),
          shape: WidgetStatePropertyAll(menuShape),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(menuElevation),
          shape: WidgetStatePropertyAll(menuShape),
        ),
      ),
      // Pickers — the date picker is on every editor's toolbar. Material 3
      // renders it as a 28px-radius sheet with a tinted header; QBO's is a
      // flat white panel with a hairline and our radius.
      datePickerTheme: DatePickerThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: menuShape,
        headerBackgroundColor: scheme.surface,
        headerForegroundColor: scheme.onSurface,
        elevation: menuElevation,
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: scheme.surface,
        shape: menuShape,
        elevation: menuElevation,
      ),
      // Dialogs / bottom sheets
      dialogTheme: DialogThemeData(
        elevation: 0,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        titleTextStyle: AppTypography.textTheme.headlineMedium,
        contentTextStyle: AppTypography.textTheme.bodyMedium,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        showDragHandle: true,
        dragHandleColor: scheme.outline,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 62,
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
          borderRadius: AppRadius.smAll,
        ),
        elevation: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        // Gradient handled per-instance via AtriaGradientFab; this keeps the
        // default shape and elevation consistent.
        elevation: 4,
        highlightElevation: 6,
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.smAll,
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
              : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : AppColors.outlineStrong.withValues(alpha: 0.6),
        ),
      ),
      // Checkboxes sit next to 4px fields, so they take the same 4px corner
      // instead of Material's 2px — a 2px radius beside a 4px one reads as a
      // rendering slip, not a choice.
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.xsAll,
        ),
        side: BorderSide(color: AppColors.outlineStrong, width: 1.5),
      ),
      radioTheme: RadioThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      // Material 3 gives these a stadium radius by default (999), which put a
      // fully-round track under a 999-pill status chip in the same row.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppRadius.smAll),
          ),
          visualDensity: VisualDensity.compact,
          textStyle: WidgetStatePropertyAll(
            AppTypography.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(8),
        radius: const Radius.circular(4),
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.dragged) ||
                  states.contains(WidgetState.hovered)
              ? scheme.onSurfaceVariant
              : AppColors.outlineStrong,
        ),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        collapsedShape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primaryContainer,
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
      ),
      // QBO's tabs are an underlining strip with a hairline beneath it, and
      // that is what this theme renders — the earlier "segmented pill
      // control" comment described a design that is no longer here.
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        labelStyle: AppTypography.textTheme.labelLarge?.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: AppTypography.textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        indicatorSize: TabBarIndicatorSize.label,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: scheme.primary, width: 2.5),
        ),
        dividerColor: scheme.outline,
        splashBorderRadius: BorderRadius.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: 12),
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
    // QBO fields are white boxes with a hairline edge — the page is what is
    // grey, never the input.
    final fill = isLight ? AppColors.surface : AppColors.darkSurfaceVariant;
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      hintStyle: AppTypography.textTheme.bodyMedium
          ?.copyWith(color: scheme.onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.xsAll,
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: AppRadius.xsAll,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: AppRadius.xsAll,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: AppRadius.xsAll,
        borderSide: BorderSide(color: scheme.error, width: 1.6),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: AppRadius.xsAll,
        borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.6)),
      ),
      floatingLabelStyle: AppTypography.textTheme.bodySmall?.copyWith(
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
    onSuccessSurface: Color(0xFF0B3A05),
    danger: AppColors.error,
    onDanger: Colors.white,
    dangerSurface: AppColors.errorSurface,
    onDangerSurface: Color(0xFF7A1A17),
    warning: AppColors.warning,
    onWarning: Colors.white,
    warningSurface: AppColors.warningSurface,
    onWarningSurface: Color(0xFF6B4200),
    positive: AppColors.success,
    negative: AppColors.error,
    brandGradientStart: Color(0xFF2CA01C),
    brandGradientEnd: Color(0xFF14690B),
    saffronGradientStart: Color(0xFFF0B860),
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
    positive: Color(0xFF56C246),
    negative: Color(0xFFF87171),
    brandGradientStart: Color(0xFF56C246),
    brandGradientEnd: Color(0xFF218214),
    saffronGradientStart: Color(0xFFF0B860),
    saffronGradientEnd: Color(0xFFD68B00),
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
  /// test or an isolated overlay — instead of throwing. Any Apex Books screen is
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
