import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/export/report_export_service.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('every catalogue link resolves to a report detail route', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    await container.read(appInitializationProvider.future);
    final router = container.read(appRouterProvider);
    for (final report in ReportCatalogue.all) {
      final match = router.configuration.findMatch(
        Uri.parse('/reports/${report.spec.id}'),
      );
      expect(match.isError, isFalse, reason: report.spec.id);
      expect(match.pathParameters['reportId'], report.spec.id);
    }
    container.dispose();
    await db.close();
  });

  test(
    'all catalogue sources execute and produce readable Excel exports',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      final dir = await Directory.systemTemp.createTemp('atria-report-audit-');
      addTearDown(() => dir.delete(recursive: true));
      final firm = await db.firmRepository.create(
        name: 'Report audit',
        stateCode: '36',
        gstin: '36CZFPM0045M2Z7',
      );
      final range = ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 4, 1),
        to: DateTime(2026, 4, 30, 23, 59, 59),
      );
      for (final definition in ReportCatalogue.all) {
        expect(definition.source, isNot(isA<PlaceholderReportSource>()));
        final result = await definition.run(db, firm.id, range);
        final file = await const ReportExportService().writeExcel(result, dir);
        final bytes = await file.readAsBytes();
        final decoded = Excel.decodeBytes(bytes);
        expect(
          decoded.tables.keys,
          isNot(contains('Sheet1')),
          reason: definition.spec.id,
        );
        expect(decoded.tables, isNotEmpty, reason: definition.spec.id);
        expect(
          const ReportExportService().toCsv(result),
          contains(result.spec.title),
        );
      }
    },
  );
}
