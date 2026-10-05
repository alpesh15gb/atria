import 'package:atria/core/responsive/platform_ui.dart';
import 'package:atria/shared/widgets/atria_content_width.dart';
import 'package:atria/shared/widgets/mobile_create_grid.dart';
import 'package:atria/shared/widgets/mobile_fab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Phase 3 mobile surfaces, built from the screenshots in
/// `mobile reference/` rather than from the spec's summary of them.
///
/// **Every test declares its platform through `ThemeData`.** `flutter test`
/// defaults `defaultTargetPlatform` to android, so an undeclared platform means
/// a desktop assertion silently exercises the phone widget — the failure that
/// has already cost this repo seven tests.
void main() {
  Future<void> pumpMobile(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(360, 720),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(body: child),
      ),
    );
  }

  Future<void> pumpDesktop(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(body: child),
      ),
    );
  }

  group('the create tile grid', () {
    testWidgets('is four across, as in the reference', (tester) async {
      await pumpMobile(tester, const MobileCreateGrid());
      final grid = find.byType(GridView);
      expect(grid, findsOneWidget);

      final delegate = tester
          .widget<GridView>(grid)
          .gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
    });

    testWidgets('names itself in a heading', (tester) async {
      await pumpMobile(tester, const MobileCreateGrid());
      expect(find.text('Create'), findsOneWidget);
    });

    testWidgets('carries the phone\'s documents, in the phone\'s words',
          (tester) async {
      // The desktop menu calls it "Bill"; the reference's phone tile says
      // "Purchase". A tile reading "Bill" on a shop floor is a word the person
      // using it has to translate, and slicing the first eight off the desktop
      // order would have produced a phone grid with no purchase in it at all.
      await pumpMobile(tester, const MobileCreateGrid());
      for (final label in [
        'Invoice',
        'Purchase',
        'Quotation',
        'Expenses',
        'Credit Note',
        'Sales Order',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label tile');
      }
      expect(find.text('Bill'), findsNothing);
    });

    testWidgets('every tile goes somewhere', (tester) async {
      await pumpMobile(tester, const MobileCreateGrid());
      // A tile that is not on a real route renders fine and does nothing when
      // tapped, which is the worst kind of wrong.
      for (final tile in MobileCreateGrid.tiles) {
        expect(tile.route, startsWith('/'));
      }
      expect(
        MobileCreateGrid.tiles.map((t) => t.route).toSet().length,
        MobileCreateGrid.tiles.length,
        reason: 'two tiles on one route means one of them is a dead duplicate',
      );
    });

    testWidgets('carries no OCR upload and no plan badge', (tester) async {
      // The reference offers "Upload with SwipeAI" beside its Create heading.
      // That is OCR, which Apex does not have and is not being built; an
      // affordance for a product that does not exist is worse than a gap.
      await pumpMobile(tester, const MobileCreateGrid());
      expect(find.textContaining('SwipeAI'), findsNothing);
      expect(find.textContaining('PRO'), findsNothing);
      expect(find.textContaining('Upload'), findsNothing);
    });

    testWidgets('renders nothing at all on desktop', (tester) async {
      // Desktop puts create actions in the chrome and the rail menu. A tile grid
      // across a 1920px window is a strip of icons with nothing under them.
      await pumpDesktop(tester, const MobileCreateGrid());
      expect(find.text('Create'), findsNothing);
      expect(find.byType(GridView), findsNothing);
    });
  });

  group('the quick access grid', () {
    testWidgets('has its own heading', (tester) async {
      await pumpMobile(
        tester,
        const MobileQuickAccessGrid(entries: [
          (route: '/reports', label: 'Reports', icon: Icons.insights_outlined),
        ]),
      );
      expect(find.text('Quick Access'), findsOneWidget);
      expect(find.text('Reports'), findsOneWidget);
    });

    testWidgets('is built from the same tile as Create', (tester) async {
      // Two copies of a tile is how they drift. Both grids resolve to one
      // `_TileGrid`, which is only possible because neither builds its own.
      await pumpMobile(
        tester,
        const Column(children: [
          MobileCreateGrid(),
          MobileQuickAccessGrid(entries: [
            (route: '/reports', label: 'Reports', icon: Icons.insights_outlined),
          ]),
        ]),
      );

      expect(find.byType(GridView), findsNWidgets(2));
      final grids = tester
          .widgetList<GridView>(find.byType(GridView))
          .map((g) => g.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .toList();
      expect(
        grids[0].crossAxisCount,
        grids[1].crossAxisCount,
        reason: 'the two grids are the same width, in the reference and here',
      );
    });
  });

  group('the list FAB', () {
    testWidgets('is a rounded square, not a circle', (tester) async {
      // The squircle is a real part of the reference's look and Material's
      // default is a circle, so the shape has to be asserted or it silently
      // reverts.
      await pumpMobile(tester, const MobileFab(onPressed: _noop));
      final fab = tester.widget<FloatingActionButton>(
        find.byType(FloatingActionButton),
      );
      final shape = fab.shape! as RoundedRectangleBorder;
      expect(
        shape.borderRadius,
        BorderRadius.circular(MobileFab.size / 4),
      );
    });

    testWidgets('taps', (tester) async {
      var pressed = 0;
      await pumpMobile(tester, MobileFab(onPressed: () => pressed++));
      await tester.tap(find.byType(FloatingActionButton));
      expect(pressed, 1);
    });

    testWidgets('renders nothing on desktop', (tester) async {
      // The desktop surface has no FAB at all: the page's primary action is in
      // its header, and `ui_structure_regression_test.dart` asserts that.
      await pumpDesktop(tester, const MobileFab(onPressed: _noop));
      expect(find.byType(FloatingActionButton), findsNothing);
    });
  });

  group('the content cap, as mounted', () {
    testWidgets('centres the branches on a tablet', (tester) async {
      // The end-to-end statement of the tablet rule, at the size that matters.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: AtriaContentWidth(
              child: SizedBox(
                key: const Key('branch'),
                width: double.infinity,
                height: 10,
              ),
            ),
          ),
        ),
      );
      tester.view.physicalSize = const Size(1260, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(const Key('branch'))).width,
        PlatformUi.contentMaxWidth,
      );
    });
  });
}

void _noop() {}