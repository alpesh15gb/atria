import 'dart:io';

import 'package:atria/core/theme/app_colors.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule this file guards: **a panel that can open over the page undimmed
/// has to carry its own edge.**
///
/// A `PopupMenuButton`, a dropdown menu or an autocomplete's suggestions are
/// popup routes with no barrier, so they land on whatever page is behind them,
/// undimmed. The dashboard's header band and the editors' pages are the same
/// white as those panels, and Material's drop shadow is far too faint to part
/// them (the app's shadow colour is an 8% grey). The panel's own edge then
/// disappears and the page's text reads as the menu's contents — which is
/// exactly how the business switcher came to look transparent.
///
/// Dialogs and modal sheets are the documented exceptions: their barrier dims
/// the page, and that dimming is their edge.
///
/// Kept as assertions on the theme plus a scan of the sources, because the way
/// this broke last time was five call sites quietly re-stating `Material`'s
/// defaults (`color`, `elevation: 8`, a borderless `shape`) over the theme.
void main() {
  const surfaces = {'light': AppTheme.light, 'dark': AppTheme.dark};

  void expectHairline(
    ShapeBorder? shape,
    Color outline,
    String what,
  ) {
    expect(shape, isA<RoundedRectangleBorder>(), reason: '$what: wrong shape');
    final side = (shape! as RoundedRectangleBorder).side;
    expect(
      side.style,
      BorderStyle.solid,
      reason: '$what: a floating panel needs a hairline, not just a shadow',
    );
    expect(side.color, outline, reason: '$what: edge it in the outline colour');
  }

  for (final entry in surfaces.entries) {
    final name = entry.key;
    final theme = entry.value();
    final scheme = theme.colorScheme;

    test('the $name theme edges every floating panel', () {
      final popup = theme.popupMenuTheme;
      expect(popup.color, scheme.surface, reason: '$name popup menu surface');
      expect(popup.elevation, AppTheme.menuElevation);
      expectHairline(popup.shape, scheme.outline, '$name popupMenuTheme');

      final menu = theme.menuTheme.style;
      expect(menu?.backgroundColor?.resolve({}), scheme.surface);
      expect(menu?.elevation?.resolve({}), AppTheme.menuElevation);
      expectHairline(
        menu?.shape?.resolve({}),
        scheme.outline,
        '$name menuTheme (MenuAnchor)',
      );

      final dropdown = theme.dropdownMenuTheme.menuStyle;
      expect(dropdown?.backgroundColor?.resolve({}), scheme.surface);
      expectHairline(
        dropdown?.shape?.resolve({}),
        scheme.outline,
        '$name dropdownMenuTheme (DropdownMenu)',
      );

      expectHairline(
        theme.datePickerTheme.shape,
        scheme.outline,
        '$name datePickerTheme',
      );
      expectHairline(
        theme.timePickerTheme.shape,
        scheme.outline,
        '$name timePickerTheme',
      );
    });

    test('the $name theme keeps the page-hairline surfaces it already had', () {
      // Cards separate with a hairline rather than elevation; the chrome band
      // and every app bar close with one at the bottom.
      expectHairline(theme.cardTheme.shape, scheme.outline, '$name cardTheme');
      final chrome = theme.appBarTheme.shape;
      expect(
        chrome,
        isA<Border>(),
        reason: '$name appBarTheme should close with a bottom hairline',
      );
      expect(
        (chrome! as Border).bottom.style,
        BorderStyle.solid,
        reason: '$name appBarTheme bottom hairline',
      );
    });

    test('the $name theme keeps its shadows quiet', () {
      // Material draws elevation shadows with `canvas.drawShadow`, which scales
      // the drawn shadow by this colour's alpha. An opaque shadow colour paints
      // an almost solid black band around every raised surface — dialogs, menus,
      // cards, the FAB. The light scheme sits at 8%; the dark one matches the
      // app's own dark card shadow, 50%.
      expect(
        scheme.shadow.a,
        lessThan(0.75),
        reason: '$name: an opaque shadow colour paints a black halo',
      );
    });

    test('the $name canvas is the panel colour, not the page grey', () {
      // `DropdownButton` paints its menu with `dropdownColor ?? canvasColor`,
      // and there is no `DropdownButtonTheme` in this Flutter version, so this
      // IS the knob for all 26 dropdowns in the app. Undefined, it inherited
      // the page grey: a panel the same colour as the page it opened over.
      expect(theme.canvasColor, scheme.surface);
      expect(
        theme.canvasColor,
        isNot(theme.scaffoldBackgroundColor),
        reason: '$name: the page and its panels are different colours',
      );
      expect(
        theme.scaffoldBackgroundColor,
        theme.brightness == Brightness.light
            ? AppColors.paper
            : AppColors.darkPaper,
      );
    });
  }

  test('no floating Material is built without the app surface shape', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('Material(')) continue;
        // Read the whole construction: arguments can be a dozen lines apart.
        final call = lines.skip(i).take(14).join('\n');
        final elevation = RegExp(r'elevation:\s*([0-9.]+)').firstMatch(call);
        final floats =
            call.contains('elevation: AppTheme.menuElevation') ||
            (elevation != null && (double.tryParse(elevation[1]!) ?? 0) > 0);
        if (!floats) continue;
        // A shape is what can carry the hairline; a bare borderRadius cannot.
        if (call.contains('shape:')) continue;
        offenders.add('${entity.path.replaceAll(r'\', '/')}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A raised Material without a `shape:` has no edge of its own, so it\n'
          'vanishes where the page behind it is the same colour. Give it\n'
          '`shape: AppTheme.menuShape(scheme)`, or drop the elevation and put\n'
          'a hairline on the child.',
    );
  });
}
