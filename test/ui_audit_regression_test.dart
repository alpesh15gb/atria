import 'dart:async';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_sizes.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedSettings extends SettingsRepository {
  DelayedSettings(super.db);
  final loaded = Completer<String?>();
  @override
  Future<String?> get(String key, {String? firmId}) => loaded.future;
  @override
  Future<void> set(String key, String value, {String? firmId}) async {}
}

void main() {
  test('a startup read cannot overwrite a newly selected theme', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final settings = DelayedSettings(db);
    final controller = ThemeModeController(settings);
    await controller.set(ThemeMode.light);
    settings.loaded.complete('dark');
    await Future<void>.delayed(Duration.zero);
    expect(controller.state, ThemeMode.light);
    controller.dispose();
    await db.close();
  });
  test('theme startup can finish safely after disposal', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final settings = DelayedSettings(db);
    ThemeModeController(settings).dispose();
    settings.loaded.complete('dark');
    await Future<void>.delayed(Duration.zero);
    await db.close();
  });
  testWidgets('desktop page actions align with the right page gutter', (
    tester,
  ) async {
    // **Pin the surface and the ratio explicitly.**
    //
    // This assertion is a difference between two rects, so it depends on the
    // ambient `tester.view`. `tester.getRect` reports *logical* pixels, and the
    // logical surface is `physicalSize / devicePixelRatio` — so a view left at a
    // phone's 1236×2800 @3x, or one carrying a display cutout, changes what this
    // measures. Run alone it saw the 800×600 default and passed; after any other
    // suite had pumped a phone-sized view it measured a ~587px column and failed
    // at 212.9. Both numbers are "the layout is fine" — the test was reading
    // whatever the previous file happened to leave behind.
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AtriaPageHeader(
            title: 'Invoices',
            actions: [
              TextButton(onPressed: () {}, child: const Text('New invoice')),
            ],
          ),
        ),
      ),
    );
    final header = tester.getRect(find.byType(AtriaPageHeader));
    final action = tester.getRect(find.byType(TextButton));
    expect(header.right - action.right, AppPage.gutter);
  });
}
