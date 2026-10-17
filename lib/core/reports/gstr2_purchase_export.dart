import 'dart:io';

import 'package:path/path.dart' as p;

import 'engine/report_result.dart';
import 'export/report_export_service.dart';
import 'vyapar_gst_workbook.dart';

class Gstr2PurchaseExport {
  Future<File> write(
    ReportResult result,
    Directory dir, {
    String gstin = '',
    String firmName = '',
  }) => VyaparGstWorkbook().gstr2(
    result,
    File(p.join(dir.path, '${ReportExportService.fileStem(result)}.xlsx')),
    gstin: gstin,
    firmName: firmName,
  );
}
