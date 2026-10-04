import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/shared/widgets/atria_create_menu.dart';
import 'package:atria/shared/widgets/atria_list_toolbar.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:atria/shared/widgets/tax_mode_toggle.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout regressions at the sizes the app is actually sold at, and the
/// accessibility ceilings that used to hide them.
///
/// `app.dart` used to clamp every route's `textScaler` to 1.15, so every layout
/// in the app was only ever exercised at 115% of the platform's font size. The
/// clamp is gone — Android's font-size setting goes all the way to 2.0× — so
/// the strips and the icon-only controls that could not take it are tested at
/// 2.0× directly.
///
/// Every layout test here is a "does Flutter complain" test: the framework
/// reports a `RenderFlex` overflow through the same channel as a thrown
/// exception, so `takeException` is the assertion that matters.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  /// Identifies the one strip under test, so the assertions can be scoped to it
  /// rather than to the whole app tree.
  const stripKey = ValueKey('pill-strip');

  /// Registers the app's bundled Inter weights so text laid out here has the
  /// metrics a real phone gets. The test binding's fallback font is a different
  /// width, so without this the widths measured here are not the widths a
  /// device will see. Idempotent: `FontLoader.load` only needs one call per
  /// process.
  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    await loader.load();
  }

  /// Pins the surface to [size] for the duration of the test.
  void surface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Pumps [child] at [size] with [textScale] applied to everything below it.
  ///
  /// The [MediaQuery] sits *under* `MaterialApp`, so it overrides the app's own
  /// without going anywhere near the platform dispatcher.
  ///
  /// Bounded pumps, never `pumpAndSettle`: a pill's `AnimatedContainer` and the
  /// ink ripple both schedule frames forever.
  Future<Object?> pump(
    WidgetTester tester, {
    required Widget child,
    Size size = const Size(320, 640),
    double textScale = 1.0,
  }) async {
    await loadAppFont();
    surface(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child,
          ),
        ),
      ),
    );
    await tester.pump();
    // Past the pill's 160ms container animation, so what is measured is the
    // settled layout.
    await tester.pump(const Duration(milliseconds: 300));
    return tester.takeException();
  }

  group('AtriaResultsBar', () {
    // A 7-digit count, a "shown" note and a period total is the case D44
    // describes: neither text was flexed, and a `Row` hands a non-flex child an
    // unbounded width, so this overflowed a 360dp phone outright.
    Widget bar({required int count, required Decimal? total}) =>
        AtriaResultsBar(
          count: count,
          noun: 'invoice',
          total: total,
          filtered: true,
        );

    testWidgets('survives a 7-digit count and a period total at 320dp',
        (tester) async {
      final error = await pump(
        tester,
        size: const Size(320, 640),
        child: bar(
          count: 1234567,
          total: Decimal.parse('98765432.10'),
        ),
      );
      expect(error, isNull);
    }, timeout: timeout);

    testWidgets('survives the same at a 2.0x text scale', (tester) async {
      // `app.dart` no longer caps text scaling, so 2.0x is a setting a user can
      // actually be in.
      final error = await pump(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        child: bar(
          count: 1234567,
          total: Decimal.parse('98765432.10'),
        ),
      );
      expect(error, isNull);
    }, timeout: timeout);

    testWidgets('keeps the total against the right edge on a wide pane',
        (tester) async {
      await pump(
        tester,
        size: const Size(1280, 800),
        child: bar(count: 12, total: Decimal.parse('234000')),
      );
      expect(find.textContaining('Total'), findsOneWidget);
      final barRect = tester.getRect(find.byType(AtriaResultsBar));
      final totalRect = tester.getRect(find.textContaining('Total'));
      // `spaceBetween` replaced the old `Spacer`. The total must stay hard
      // against the right edge rather than drifting in beside the count.
      expect(totalRect.right, closeTo(barRect.right, 1.0));
    }, timeout: timeout);
  });

  group('AtriaSegmentedFilter', () {
    // Three pills on a 320dp phone used to leave about 51dp of label each, and
    // "All items" needs about 58dp — every label rendered as "…".
    final three = <AtriaSegment<int>>[
      const AtriaSegment(value: 0, label: 'All items'),
      const AtriaSegment(value: 1, label: 'Products'),
      const AtriaSegment(value: 2, label: 'Services'),
    ];

    /// Keyed so the assertions below can be scoped to this strip: `Expanded`
    /// and `SingleChildScrollView` are widgets the framework itself uses
    /// somewhere in every app, and a bare `find.byType` over the whole tree is
    /// a test that breaks the next time `MaterialApp` changes shape.
    final byStrip = find.byKey(stripKey);

    testWidgets('three labels lay out at 320dp', (tester) async {
      final error = await pump(
        tester,
        size: const Size(320, 640),
        child: AtriaSegmentedFilter<int>(
          key: stripKey,
          segments: three,
          value: 0,
          onChanged: (_) {},
        ),
      );
      expect(error, isNull);
      // The reason the next test needs 2.0x: with the pill chrome down at
      // 18dp, 288dp of strip holds ~226dp of pills at 1.0x, so three pills get
      // 96dp each — 78dp of label against a 54.45dp "Products". They fit, so
      // the equal-width row is the correct form here and does not scroll.
      expect(
        find.descendant(of: byStrip, matching: find.byType(Expanded)),
        findsNWidgets(3),
      );
      expect(
        find.descendant(of: byStrip, matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );
      expect(tester.getSize(find.text('Products')).width, closeTo(54.45, 1.0));
    }, timeout: timeout);

    testWidgets('three labels lay out at a 2.0x text scale', (tester) async {
      final error = await pump(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        child: AtriaSegmentedFilter<int>(
          key: stripKey,
          segments: three,
          value: 0,
          onChanged: (_) {},
        ),
      );
      expect(error, isNull);
    }, timeout: timeout);

    testWidgets('scrolls rather than truncating when the labels do not fit',
        (tester) async {
      // At the default scale the labels *do* fit 320dp — see the sibling test —
      // so the fallback is exercised at 2.0x, where they cannot: 288dp of
      // usable strip against ~226dp of pills at 1.0x becomes ~381dp, and no
      // amount of equal sharing puts "Products" into 72dp of label.
      await pump(
        tester,
        size: const Size(320, 640),
        textScale: 2.0,
        child: AtriaSegmentedFilter<int>(
          key: stripKey,
          segments: three,
          value: 0,
          onChanged: (_) {},
        ),
      );
      expect(
        find.descendant(of: byStrip, matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: byStrip, matching: find.byType(Expanded)),
        findsNothing,
      );
      // The label itself is whole: nothing was cut down to an ellipsis. A
      // `Text` holds its full `data` while it paints "…", so this compares
      // the width the label was laid out at against the width it needs.
      final label = find.text('All items');
      expect(label, findsOneWidget);
      final context = tester.element(label);
      final painter = TextPainter(
        text: TextSpan(
          text: 'All items',
          style: DefaultTextStyle.of(context).style.merge(
            tester.widget<Text>(label).style,
          ),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      expect(
        tester.getSize(label).width,
        greaterThanOrEqualTo(painter.width - 0.5),
        reason: 'the scrolling form must not ellipsise a label that it can '
            'simply let run off the right edge',
      );
      painter.dispose();
    }, timeout: timeout);

    testWidgets('scrolls when one long label does not fit its equal share',
        (tester) async {
      // Fits by total, not by share: at 320dp the three pills below measure
      // ~226dp of content against 288dp, but 'Sales invoice' alone is ~110dp
      // against a 92dp share. An equal-width row would have ellipsised it.
      const mixed = <AtriaSegment<int>>[
        AtriaSegment(value: 0, label: 'All'),
        AtriaSegment(value: 1, label: 'Sales invoice'),
        AtriaSegment(value: 2, label: 'Receipt'),
      ];
      final error = await pump(
        tester,
        size: const Size(320, 640),
        child: AtriaSegmentedFilter<int>(
          key: stripKey,
          segments: mixed,
          value: 0,
          onChanged: (_) {},
        ),
      );
      expect(error, isNull);
      expect(
        find.descendant(of: byStrip, matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: byStrip, matching: find.byType(Expanded)),
        findsNothing,
      );
      expect(find.text('Sales invoice'), findsOneWidget);
    }, timeout: timeout);

    testWidgets('shares the width equally when the labels do fit',
        (tester) async {
      // The equal-width row is the look on a wide pane, and it has to
      // survive as the default rather than every strip becoming
      // natural-width chips.
      await pump(
        tester,
        size: const Size(1280, 800),
        child: AtriaSegmentedFilter<int>(
          key: stripKey,
          segments: three,
          value: 0,
          onChanged: (_) {},
        ),
      );
      expect(
        find.descendant(of: byStrip, matching: find.byType(Expanded)),
        findsNWidgets(3),
      );
      expect(
        find.descendant(
          of: byStrip,
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );
    }, timeout: timeout);
  });

  group('hit targets', () {
    testWidgets('the icon-rail Create button is at least 44x44',
        (tester) async {
      // D41: the collapsed form was `padding: 0` around a lone 18px glyph in a
      // 38-tall box — an 18x38 target for the app's primary create affordance,
      // on every 600-839dp window.
      await pump(
        tester,
        child: const Align(
          alignment: Alignment.topCenter,
          child: AtriaCreateButton(expanded: false),
        ),
      );
      final size = tester.getSize(find.byType(AtriaCreateButton));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }, timeout: timeout);

    testWidgets('a header icon action is at least 44x44', (tester) async {
      await pump(
        tester,
        child: const Align(
          alignment: Alignment.topCenter,
          child: AtriaPageHeader(
            title: 'Stock',
            actions: [
              AtriaHeaderIconAction(
                icon: Icons.print_outlined,
                tooltip: 'Print',
                onPressed: null,
              ),
            ],
          ),
        ),
      );
      final size = tester.getSize(find.byType(AtriaHeaderIconAction));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }, timeout: timeout);

    testWidgets('the grid tax-mode pill is at least 44x44', (tester) async {
      // It sits in spreadsheet cells, which size to their tallest child, so a
      // bigger target grows the row rather than overflowing it.
      await pump(
        tester,
        child: const Align(
          alignment: Alignment.topCenter,
          child: AtriaTaxModePill(
            value: TaxMode.exclusive,
            onChanged: _ignoreTaxMode,
          ),
        ),
      );
      final size = tester.getSize(find.byType(AtriaTaxModePill));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }, timeout: timeout);
  });
}

/// Top-level so it can be referenced from a `const` widget tree.
void _ignoreTaxMode(TaxMode _) {}