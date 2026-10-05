import 'package:atria/core/responsive/platform_ui.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/shared/widgets/report_data_table.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mobile UI is chosen by PLATFORM, not by width.
///
/// Two things make this worth a test of its own:
///
/// 1. `Platform.isAndroid` is false inside `flutter test` on a Windows host, so
///    a seam built on `dart:io` would report "desktop" here and the mobile tree
///    would be untestable — every mobile assertion would pass against the
///    desktop widget and then fail on the device.
/// 2. The seam decides what a phone shows. Getting it backwards renders tables
///    on a 360dp screen, which is the bug that made a saved invoice show only
///    its first column.
void main() {
  group('the seam answers by platform, not by width', () {
    test('Android and iOS get the mobile UI', () {
      expect(TargetPlatform.android.isMobileUi, isTrue);
      expect(TargetPlatform.iOS.isMobileUi, isTrue);
    });

    test('Windows, macOS and Linux get the desktop UI', () {
      expect(TargetPlatform.windows.isMobileUi, isFalse);
      expect(TargetPlatform.macOS.isMobileUi, isFalse);
      expect(TargetPlatform.linux.isMobileUi, isFalse);
    });

    test('the surface agrees with the flag', () {
      expect(TargetPlatform.android.uiSurface, UiSurface.mobile);
      expect(TargetPlatform.windows.uiSurface, UiSurface.desktop);
    });

    /// The whole reason this is not `dart:io`.
    test('it reads the overridable platform, so a test can be either one', () {
      expect(TargetPlatform.android.isMobileUi, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(defaultTargetPlatform.isMobileUi, isTrue);
    });
  });

  group('a report renders as cards on a phone however narrow or wide', () {
    // Two columns is a table on any desktop window and would be squeezed on a
    // phone. Before this change the choice was made on width alone, so a
    // phone-width render of a wide report had to be forced by the column count.
    ReportResult twoColumnResult() => ReportResult(
          spec: const ReportSpec(
            id: 'demo',
            title: 'Demo',
            category: 'demo',
            columns: [
              ReportColumn(key: 'name', label: 'Name'),
              ReportColumn(
                key: 'amount',
                label: 'Amount',
                kind: ReportValueKind.money,
              ),
            ],
          ),
          window: const ReportWindow(
            preset: ReportWindowPreset.custom,
            from: null,
            to: null,
          ),
          grandTotals: const {},
          groups: [
            ReportGroup(
              name: 'all',
              label: 'All',
              rows: const [
                ReportRow({
                  'name': 'Kamal Consumer Care',
                  'amount': 20550,
                }),
              ],
              totals: const {},
            ),
          ],
        );

    testWidgets('Android renders the card tree even at desktop width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900) * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReportDataTable(
            result: twoColumnResult(),
            columns: twoColumnResult().spec.columns,
          )),
        ),
      );

      // The table is the only path built on a sliver list; the cards are not.
      // Both label a cell with its column name, so the column heading cannot
      // tell the two apart.
      expect(find.byType(CustomScrollView), findsNothing);
      expect(find.text('Kamal Consumer Care'), findsOneWidget);

      // Flutter asserts no foundation override outlives the test body, so it
      // is cleared here rather than in a tearDown.
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Windows renders the table even at phone width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 700) * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReportDataTable(
            result: twoColumnResult(),
            columns: twoColumnResult().spec.columns,
          )),
        ),
      );

      expect(find.byType(CustomScrollView), findsOneWidget);
      expect(find.text('Amount'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}