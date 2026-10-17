import 'dart:async';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/shared/widgets/interface_scale.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class DelayedScaleSettings extends SettingsRepository {
  DelayedScaleSettings(super.db);
  final loaded = Completer<String?>();
  @override
  Future<String?> get(String key, {String? firmId}) => loaded.future;
  @override
  Future<void> set(String key, String value, {String? firmId}) async {}
}

void main() {
  test(
    'zoom persists and restores; invalid values keep a usable default',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      final settings = SettingsRepository(db);
      final controller = InterfaceScaleController(settings);
      await controller.set(1.3);
      expect(await settings.get(SettingsRepository.kInterfaceScale), '1.3');
      final restored = InterfaceScaleController(settings);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(restored.state, 1.3);
      await restored.set(double.nan);
      expect(restored.state, 1.3);
      await settings.set(SettingsRepository.kInterfaceScale, 'Infinity');
      final invalid = InterfaceScaleController(settings);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(invalid.state, 1);
      controller.dispose();
      restored.dispose();
      invalid.dispose();
      await db.close();
    },
  );
  test(
    'startup zoom read cannot overwrite a new choice or update after disposal',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      final settings = DelayedScaleSettings(db);
      final controller = InterfaceScaleController(settings);
      await controller.set(.85);
      settings.loaded.complete('1.3');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, .85);
      controller.dispose();
      final disposedSettings = DelayedScaleSettings(db);
      InterfaceScaleController(disposedSettings).dispose();
      disposedSettings.loaded.complete('1.3');
      await Future<void>.delayed(Duration.zero);
      await db.close();
    },
  );
  for (final scale in InterfaceScaleController.options) {
    testWidgets(
      'zoom $scale adjusts viewport, keyboard and hit testing without capping OS text',
      (tester) async {
        var taps = 0;
        late MediaQueryData inside;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(800, 600),
                viewInsets: EdgeInsets.only(bottom: 200),
                padding: EdgeInsets.only(top: 24),
                textScaler: TextScaler.linear(2),
              ),
              child: InterfaceScale(
                scale: scale,
                child: Builder(
                  builder: (context) {
                    inside = MediaQuery.of(context);
                    return Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () {
                            taps++;
                          },
                          child: const Text('Tap'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        expect(inside.size.width, closeTo(800 / scale, .01));
        expect(inside.viewInsets.bottom, closeTo(200 / scale, .01));
        expect(inside.padding.top, closeTo(24 / scale, .01));
        expect(inside.textScaler.scale(10), 20);
        await tester.tap(find.text('Tap'));
        expect(taps, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
