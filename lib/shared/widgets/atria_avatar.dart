import 'package:flutter/material.dart';

import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';

/// The tint an [AtriaAvatar] declares, mapped to a themed
/// background/foreground pair.
///
/// Tones exist so a screen never picks a raw colour for an avatar: the pairs
/// below are the only combinations in the product, and each one is checked for
/// contrast in both light and dark mode.
enum AtriaAvatarTone {
  /// Brand green — a party, or a document about money in.
  brand,

  /// Intuit blue — an informational/document glyph.
  info,

  /// Green — received, paid, complete.
  success,

  /// Red — overdue, cancelled.
  danger,

  /// Amber — pending, partial.
  warning,

  /// Grey — nothing semantic (a note, a walk-in, a placeholder).
  neutral,
}

/// A round avatar holding either initials or a glyph.
///
/// Before this widget there were five of these — a private `_Avatar` in the
/// party list, and four hand-rolled `CircleAvatar`s on the dashboard, the
/// party transactions pane (twice) and the payments list. They used radii of
/// 16, 18, 20, 22 and 24, four different initials font sizes (one of them
/// derived as `radius * 0.82`, which is where the app's one 14.8px text style
/// came from), and three different kind of tint. On the same screen that is
/// invisible; flicking between the party list and the payments list it reads
/// as two apps.
///
/// Two radii remain, chosen by rank rather than by taste:
///
/// * [row] — beside a list row, matching [AppPage.rowHeight].
/// * [header] — a detail header or a sheet, where the avatar is the anchor of
///   the block rather than an ornament on a row.
class AtriaAvatar extends StatelessWidget {
  /// A person, party, company or business: their initials, on the brand tint.
  const AtriaAvatar.initials({
    super.key,
    required this.name,
    this.radius = row,
    this.tone = AtriaAvatarTone.brand,
  }) : icon = null;

  /// A document, a money movement or a status: a glyph on a tinted circle.
  const AtriaAvatar.glyph({
    super.key,
    required IconData this.icon,
    this.radius = row,
    this.tone = AtriaAvatarTone.brand,
  }) : name = '';

  /// Sized for a list row (36px across).
  static const double row = 18;

  /// Sized to anchor a detail header or a bottom sheet (44px across).
  static const double header = 22;

  final double radius;
  final AtriaAvatarTone tone;

  /// The name whose initials are shown; empty for a glyph avatar.
  final String name;

  /// The glyph shown; null for an initials avatar.
  final IconData? icon;

  /// True for the larger of the two permitted radii, so the initials step up
  /// with the circle instead of floating in it.
  bool get _isLarge => radius >= header - 0.5;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    // Every pair is a *surface + its own on-surface ink* from the token set,
    // never an accent colour on a tint of itself: brand green on a pale green
    // fill measured 2.54:1, which fails WCAG AA outright.
    final (Color background, Color foreground) = switch (tone) {
      AtriaAvatarTone.brand => (
          scheme.primaryContainer,
          scheme.onPrimaryContainer,
        ),
      AtriaAvatarTone.info => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
      AtriaAvatarTone.success => (
          colors.successSurface,
          colors.onSuccessSurface,
        ),
      AtriaAvatarTone.danger => (
          colors.dangerSurface,
          colors.onDangerSurface,
        ),
      AtriaAvatarTone.warning => (
          colors.warningSurface,
          colors.onWarningSurface,
        ),
      AtriaAvatarTone.neutral => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
        ),
    };

    final text = Theme.of(context).textTheme;
    final glyph = icon;

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: glyph != null
          ? Icon(glyph, size: AppIconSize.md, color: foreground)
          : Text(
              initialsFor(name),
              maxLines: 1,
              style: (_isLarge ? text.titleMedium : text.titleSmall)?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
    );
  }

  /// First letters of the first two words: "Shri Balaji Traders" -> "SB".
  ///
  /// Shared so a name cannot render as "SBT" in the party list and "SB" on the
  /// dashboard, which is exactly what happened while each screen owned its own
  /// copy of this.
  static String initialsFor(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      final word = words.first;
      return word.characters.take(2).toString().toUpperCase();
    }
    return '${words[0].characters.first}${words[1].characters.first}'
        .toUpperCase();
  }
}
