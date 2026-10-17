import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/services/pdf_template_style.dart';
import 'package:atria/shared/widgets/document_template_settings.dart';
import 'package:atria/shared/widgets/mobile_template_picker.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/document_format_fixture.dart';

void main() {
  for (final size in [const Size(360, 640), const Size(1280, 850)]) {
    testWidgets('format chooser supports independent choices at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const channel = MethodChannel('net.nfet.printing');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {'canRaster': false},
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final db = AppDatabase.test(NativeDatabase.memory());
      final (firm, _, _, _, _) = await documentFormatFixture(db);
      var choices = const DocumentTemplates();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => DocumentTemplateSettings(
                firm: firm,
                value: choices,
                onChanged: (value) => setState(() => choices = value),
              ),
            ),
          ),
        ),
      );
      Future<void> frames() async {
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await frames();
      Future<void> choose(int dropdown, String label) async {
        await tester.tap(
          find.byType(DropdownButtonFormField<String>).at(dropdown),
        );
        await frames();
        await tester.tap(find.text(label).last);
        await frames();
      }

      await choose(1, PdfTemplateStyle.ledger.name);
      expect(choices.defaultId, 'ledger');
      await choose(0, 'Invoices');
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await choose(1, PdfTemplateStyle.clean.name);
      expect(choices.invoice, 'clean');
      expect(choices.purchase, isNull);
      expect(choices.quotation, isNull);
      await choose(0, 'Purchases');
      expect(
        tester
            .widget<MobileTemplatePicker>(find.byType(MobileTemplatePicker))
            .document,
        1,
      );
      expect(
        tester
            .widget<MobileTemplatePicker>(find.byType(MobileTemplatePicker))
            .selected
            .id,
        'ledger',
      );
      await choose(0, 'Quotations');
      expect(
        tester
            .widget<MobileTemplatePicker>(find.byType(MobileTemplatePicker))
            .document,
        2,
      );
      await choose(1, PdfTemplateStyle.business.name);
      expect(choices.quotation, 'business');
      expect(choices.invoice, 'clean');
      await tester.tap(find.byType(SwitchListTile));
      await frames();
      expect(choices.quotation, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await frames();
      await db.close();
    });
  }
}
