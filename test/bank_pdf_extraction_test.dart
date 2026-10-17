import 'dart:io';

import 'package:atria/core/services/bank_reconciliation.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native PDF extraction reads a statement text layer locally',
    () async {
      Pdfrx.pdfiumModulePath = File(
        'build/windows/x64/runner/Release/pdfium.dll',
      ).absolute.path;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          build: (_) => pw.Column(
            children: [
              pw.Text('Date Description Debit Credit'),
              pw.Text('15/10/2026 NEFT KEYSTONE 1000.00'),
            ],
          ),
        ),
      );
      final text = await extractBankPdf(await pdf.save());
      expect(text, contains('KEYSTONE'));
      expect(text, contains('1000.00'));
    },
    skip:
        !Platform.isWindows ||
        !File('build/windows/x64/runner/Release/pdfium.dll').existsSync(),
  );
}
