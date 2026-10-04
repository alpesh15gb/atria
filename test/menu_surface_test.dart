import 'dart:ui' as ui;

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_colors.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/shared/widgets/atria_top_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The top bar's menus drop their panel onto whatever page is below them — and
/// the dashboard's header band is the same colour as the panel, in both themes.
/// With a drop shadow as the only separation, the panel's own edge disappeared
/// against that band: the page's greeting and business name read *through* the
/// open menu, so the menu looked transparent.
///
/// This pins the fix at the pixel level, in both themes (dark is the harder
/// case: `darkSurface` and `darkPaper` are nine parts in 255 apart, so the
/// hairline is doing nearly all of the work).
const _captureKey = ValueKey<String>('menu-surface');

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    // The database is used only to mint a firm — so the row is built by the
    // real schema rather than by a 25-field constructor. Seeded here, because
    // drift writes never complete inside the fake-async zone a `testWidgets`
    // body runs in.
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    // The tree is handed the firm directly. Subscribing it to
    // `activeFirmProvider` (a drift StreamProvider) closes a stream on
    // teardown, and the zero-duration timer drift schedules then trips the
    // framework's "a Timer is still pending" invariant.
    container = ProviderContainer(
      overrides: [activeFirmProvider.overrideWith((ref) => Stream.value(firm))],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  final themes = {'light': AppTheme.light, 'dark': AppTheme.dark};

  for (final entry in themes.entries) {
    final name = entry.key;
    final theme = entry.value();
    final scheme = theme.colorScheme;
    final isLight = theme.brightness == Brightness.light;
    // The band the panel drops onto, and the page beneath it.
    final band = isLight ? AppColors.surface : AppColors.darkSurface;
    final page = isLight ? AppColors.paper : AppColors.darkPaper;

    testWidgets('the business switcher panel edges itself against a $name page', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(700, 460));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: theme,
            debugShowCheckedModeBanner: false,
            // The boundary must sit ABOVE the navigator's overlay, where the
            // menu route paints — wrapping `home` would miss the panel.
            builder: (context, child) =>
                RepaintBoundary(key: _captureKey, child: child!),
            home: Scaffold(
              body: Column(
                children: [
                  const AtriaTopBar(leadingWidth: 236, compactLeading: false),
                  // The dashboard's header band, then its page: the panel's
                  // top edge lands in the band.
                  SizedBox(height: 72, child: ColoredBox(color: band)),
                  Expanded(child: ColoredBox(color: page)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // The switcher's label, not any other copy of the business name.
      await tester.tap(
        find.descendant(
          of: find.byType(AtriaTopBar),
          matching: find.text('Apex Integrations'),
        ),
      );
      // The popup route fades and grows over ~300ms; settle it explicitly
      // rather than with pumpAndSettle, which would wait on the app's looping
      // animations.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final panelFinder = find
          .ancestor(
            // Anything inside the menu: the header item is the first row.
            of: find.text('BUSINESS'),
            matching: find.byWidgetPredicate(
              (widget) => widget is Material && widget.shape != null,
            ),
          )
          .first;
      final panel = tester.widget<Material>(panelFinder);
      final rect = tester.getRect(panelFinder);

      // The panel is the theme's menu surface — opaque, and hairline-edged.
      expect(panel.color, scheme.surface);
      expect(panel.elevation, AppTheme.menuElevation);
      final shape = panel.shape! as RoundedRectangleBorder;
      expect(shape.side.style, BorderStyle.solid);
      expect(shape.side.color, scheme.outline);

      // Now the rendering. Device pixel ratio so the 1px hairline covers whole
      // pixels and can be compared exactly.
      final dpr = tester.view.devicePixelRatio;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(_captureKey),
      );
      final imageWidth = (boundary.size.width * dpr).round();
      // The rasteriser's future only completes on the real event loop; awaited
      // straight from the test body it simply never settles.
      final rawBytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: dpr);
        return image.toByteData(format: ui.ImageByteFormat.rawRgba);
      }))!;
      int argbAt(double logicalX, double logicalY) {
        final i =
            ((logicalY * dpr).round() * imageWidth +
                (logicalX * dpr).round()) *
            4;
        return (rawBytes.getUint8(i + 3) << 24) |
            (rawBytes.getUint8(i) << 16) |
            (rawBytes.getUint8(i + 1) << 8) |
            rawBytes.getUint8(i + 2);
      }

      /// Whether the panel's own hairline is painted within a few pixels of
      /// `(x, y)`. A window, not a single pixel, so a half-pixel offset in where
      /// the 1px stroke lands cannot make the check flaky.
      bool hairlineNear(double x, double y) {
        final outline = scheme.outline.toARGB32();
        for (var dy = -2; dy <= 2; dy++) {
          for (var dx = -2; dx <= 2; dx++) {
            if (argbAt(x + dx, y + dy) == outline) return true;
          }
        }
        return false;
      }

      // The band above and beside the panel is the panel's own colour, so a
      // shadow-only panel has nothing but shadow here — this is the edge the
      // reported bug lost.
      expect(
        hairlineNear(rect.center.dx, rect.top),
        isTrue,
        reason: '$name: the panel top edge is drawn against the band above it',
      );
      expect(
        hairlineNear(rect.left, rect.top + 24),
        isTrue,
        reason: '$name: the panel left edge is drawn against the band beside it',
      );
      // And the page does not read through the panel itself.
      expect(argbAt(rect.center.dx, rect.top + 40), scheme.surface.toARGB32());
      expect(
        argbAt(rect.center.dx, rect.bottom - 8),
        scheme.surface.toARGB32(),
      );

      // Unmount so the popup route's tickers are disposed inside the test.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  }
}
