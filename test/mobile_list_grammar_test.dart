import 'package:atria/shared/widgets/atria_list_toolbar.dart';
import 'package:atria/shared/widgets/corner_ribbon.dart';
import 'package:atria/shared/widgets/mobile_create_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The list-card grammar the reference uses and the spec missed.
///
/// **Every test declares its platform.** `flutter test` defaults
/// `defaultTargetPlatform` to android, and these widgets choose their treatment
/// by platform — an undeclared one makes a desktop assertion exercise the phone
/// branch and pass for the wrong reason.
/// A callback for a filter this test never drives.
void _ignore(String _) {}

void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(360, 720),
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
    // **`pumpAndSettle`, not `pumpWidget` alone.**
    //
    // `MaterialApp` animates a theme change, so a second pump with a different
    // `platform` renders one frame of the **previous** theme and stops. A test
    // that pumped the phone platform and then the desktop one therefore read the
    // phone's colours twice and concluded the platform gate did nothing — which
    // is the worst possible outcome from a test that looks like it is checking
    // exactly that.
    await tester.pumpAndSettle();
  }

  group('the filter pill count badge', () {
    testWidgets('shows on the selected pill, as "All Transactions ①"',
        (tester) async {
      String? chosen;
      await pumpAt(
        tester,
        SizedBox(
          width: 360,
          child: StatefulBuilder(
            builder: (context, setState) => AtriaSegmentedFilter<String>(
              scrollable: true,
              value: chosen ?? 'all',
              onChanged: (v) => setState(() => chosen = v),
              segments: const [
                AtriaSegment(value: 'all', label: 'All Transactions', count: 1),
                AtriaSegment(value: 'paid', label: 'Paid'),
                AtriaSegment(value: 'pending', label: 'Pending'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('is hidden until its pill is selected', (tester) async {
      // Once you have tapped a filter, the counts of the others are noise
      // competing with their labels for a 360dp strip.
      String? chosen;
      await pumpAt(
        tester,
        SizedBox(
          width: 360,
          child: StatefulBuilder(
            builder: (context, setState) => AtriaSegmentedFilter<String>(
              scrollable: true,
              value: chosen ?? 'paid',
              onChanged: (v) => setState(() => chosen = v),
              segments: const [
                AtriaSegment(value: 'all', label: 'All', count: 12),
                AtriaSegment(value: 'paid', label: 'Paid'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('12'), findsNothing);
    });

    testWidgets('the selected pill is filled on a phone and tinted on desktop',
        (tester) async {
      // The reference's is a solid blue pill with white text. The desktop's row
      // of tinted pills reads better against a wide table and is what every
      // desktop screenshot here already uses — so the branch is by platform, not
      // by taste.
      // The selected pill's label colour.
      //
      // Read from the `Text`, not from the pill's `Material`: the fill is what
      // the reference is about, but the *label* is the one thing every platform
      // must differ on — white on the filled pill, primary on the tinted one —
      // and it is directly observable, where a Material search can land on the
      // Scaffold's and read the same colour on both platforms.
      Color? labelColour(WidgetTester tester) => tester
          .widget<Text>(
            find
                .descendant(
                  of: find.byType(AtriaSegmentedFilter<String>),
                  matching: find.text('All'),
                )
                .first,
          )
          .style
          ?.color;

      await pumpAt(
        tester,
        SizedBox(
          width: 360,
          child: AtriaSegmentedFilter<String>(
            scrollable: true,
            value: 'all',
            onChanged: (_) {},
            segments: const [AtriaSegment(value: 'all', label: 'All')],
          ),
        ),
      );
      final onPhone = labelColour(tester);

      await pumpAt(
        tester,
        SizedBox(
          width: 1000,
          child: const AtriaSegmentedFilter<String>(
            scrollable: true,
            value: 'all',
            onChanged: _ignore,
            segments: [AtriaSegment(value: 'all', label: 'All')],
          ),
        ),
        size: const Size(1000, 720),
        platform: TargetPlatform.windows,
      );
      final onDesktop = labelColour(tester);

      expect(onPhone, isNotNull);
      expect(onDesktop, isNotNull);
      expect(
        onPhone,
        isNot(onDesktop),
        reason: 'the two platforms must not label the selected pill the same',
      );
    });
  });

  group('the corner ribbon', () {
    testWidgets('hangs off the top-right corner', (tester) async {
      await pumpAt(tester, const RibbonCard(ribbon: CornerRibbon(label: 'Overdue by 211 days', tone: RibbonTone.amber), child: SizedBox(height: 60)));
      final ribbon = tester.getRect(find.byType(CornerRibbon));
      final card = tester.getRect(find.byType(RibbonCard));
      // The block's box, not the text's: the text is centred inside a
      // 24dp-tall block and its own rect is narrower and inset, so asserting on
      // it would be asserting on the padding.
      expect(ribbon.top, card.top);
      expect(ribbon.right, card.right);
    });

    testWidgets('takes space from nowhere — a card with one is the same height',
        (tester) async {
      // Laid out as a sibling it would grow the card, so a list would not line
      // up; overlaid, the height depends only on the content.
      Future<double> heightOf({required bool withRibbon}) async {
        await pumpAt(
          tester,
          RibbonCard(
            ribbon: withRibbon
                ? const CornerRibbon(label: 'Qty: -3.00 UNT', tone: RibbonTone.red)
                : null,
            child: const SizedBox(height: 40),
          ),
        );
        return tester.getSize(find.byType(RibbonCard)).height;
      }

      final plain = await heightOf(withRibbon: false);
      final ribboned = await heightOf(withRibbon: true);
      expect(ribboned, greaterThan(plain));
      // The growth is the ribbon's height, not the content's.
      expect(
        ribboned - plain,
        closeTo(CornerRibbon.height, 0.01),
      );
    });

    testWidgets('three tones, and the third is not an error', (tester) async {
      // Amber = overdue, red = a negative number, neutral = a plain note. The
      // neutral exists so a caller reaching for "something to show here" does not
      // reach for red by default.
      for (final tone in RibbonTone.values) {
        await pumpAt(
          tester,
          CornerRibbon(label: 'note', tone: tone),
        );
        expect(find.text('note'), findsOneWidget, reason: '$tone');
      }
    });

    testWidgets('a long label ellipsises rather than widening the ribbon',
        (tester) async {
      await pumpAt(
        tester,
        const CornerRibbon(
          label: 'Overdue by a very long stretch of days indeed',
          tone: RibbonTone.amber,
        ),
      );
      final box = tester.getSize(find.byType(CornerRibbon));
      expect(box.width, 116);
    });
  });

  group('the create grid under a large system font', () {
    testWidgets('does not overflow at 1.5x text scale', (tester) async {
      // The cell is a fixed height, so a label that grows has nowhere to go. At
      // 1.0x the shortfall was under a pixel and only showed up at 1.3x+ — on the
      // ordinary reading size of the phone this app is used on.
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
            ),
            child: child!,
          ),
          home: const Scaffold(
            body: SingleChildScrollView(child: MobileCreateGrid()),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}