import 'package:atria/core/responsive/platform_ui.dart';
import 'package:atria/shared/widgets/atria_content_width.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mobile UI's platform seam, verified against the reference screenshots.
///
/// **Every test here declares its platform through `ThemeData`**, because
/// `flutter test` defaults `defaultTargetPlatform` to android and an undeclared
/// platform makes a desktop assertion pass against the phone widget. That trap
/// has already cost seven tests in this repo; it is not hypothetical.
void main() {
  /// The laid-out width of the probe child.
  double probeWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('probe'))).width;

  Future<void> pumpAt(
    WidgetTester tester, {
    required Size size,
    required TargetPlatform platform,
    double? maxWidth,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: AtriaContentWidth(
            maxWidth: maxWidth,
            // `width: double.infinity`, not just a height: a bare
            // `SizedBox(height: 10)` sizes itself to **zero** wide inside the
            // loose constraints `Center` hands down, so every assertion here
            // would read 0 and prove nothing.
            child: const SizedBox(
              key: Key('probe'),
              width: double.infinity,
              height: 10,
            ),
          ),
        ),
      ),
    );
  }

  group('the platform seam', () {
    test('reads the overridable platform, so a test can be either one', () {
      expect(TargetPlatform.android.isMobileUi, isTrue);
      expect(TargetPlatform.iOS.isMobileUi, isTrue);
      expect(TargetPlatform.windows.isMobileUi, isFalse);
      expect(TargetPlatform.macOS.isMobileUi, isFalse);
      expect(TargetPlatform.linux.isMobileUi, isFalse);
    });

    test('names its own surface', () {
      expect(TargetPlatform.android.uiSurface, UiSurface.mobile);
      expect(TargetPlatform.windows.uiSurface, UiSurface.desktop);
    });
  });

  group('the mobile content cap', () {
    // The reference app is phone-only and so never has to answer this. A 1260dp
    // Android tablet given phone cards stretched across the full width reads as
    // broken, and this cap is the whole answer to that.
    testWidgets('centres a phone column on a wide tablet',
        (tester) async {
      await pumpAt(
        tester,
        size: const Size(1260, 900),
        platform: TargetPlatform.android,
      );

      expect(probeWidth(tester), PlatformUi.contentMaxWidth);
    });

    testWidgets('leaves a phone alone — the cap is wider than any phone',
        (tester) async {
      await pumpAt(
        tester,
        size: const Size(360, 640),
        platform: TargetPlatform.android,
      );

      expect(probeWidth(tester), 360);
    });

    testWidgets('does not cap the desktop with the phone rule',
        (tester) async {
      // The distinction that makes this a platform rule and not a width rule: a
      // maximised desktop keeps its own cap, and is never squeezed to 560.
      await pumpAt(
        tester,
        size: const Size(1920, 900),
        platform: TargetPlatform.windows,
      );

      expect(
        probeWidth(tester),
        greaterThan(PlatformUi.contentMaxWidth),
        reason: 'desktop is capped by the desktop rule, not the phone one',
      );
    });

    testWidgets('a narrow desktop window still fills the pane',
        (tester) async {
      // The other half of the platform decision: a Windows window dragged to
      // phone width stays desktop. Uncapped, because the desktop rule is
      // infinity below `expanded`.
      await pumpAt(
        tester,
        size: const Size(500, 900),
        platform: TargetPlatform.windows,
      );

      expect(probeWidth(tester), 500);
    });

    testWidgets('an explicit maxWidth still wins on mobile', (tester) async {
      // A screen with a genuinely different reading width — the statements —
      // overrides rather than being forced into the phone cap.
      await pumpAt(
        tester,
        size: const Size(1260, 900),
        platform: TargetPlatform.android,
        maxWidth: 400,
      );

      expect(probeWidth(tester), 400);
    });
  });
}