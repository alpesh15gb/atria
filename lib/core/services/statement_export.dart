import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../database/app_database.dart';
import '../database/repositories/report_repository.dart';
import '../utils/formatters.dart';
import '../utils/number_words.dart';

/// Statement of Account exports — a print-ready A4 PDF and a real .xlsx
/// workbook, both written to Documents/atria/statements and opened with the
/// system viewer.
class StatementExport {
  StatementExport._();

  /// Writes [statement] as a formatted A4 PDF; returns the file path.
  static Future<String> exportPdf({
    required PartyStatement statement,
    required FirmEntity firm,
    required DateTime? from,
    required DateTime? to,
  }) async {
    final doc = pw.Document();
    final period = _periodLabel(from, to);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 30),
        build: (context) => [
          _pdfHeader(statement, firm, period),
          pw.SizedBox(height: 14),
          _pdfSummary(statement),
          pw.SizedBox(height: 14),
          _pdfTable(statement),
          pw.SizedBox(height: 12),
          pw.Text(
            'Closing balance: ${Formatters.money(statement.closing)}'
            ' (${NumberToWords.indianCurrency(statement.closing.abs().toDouble(), prefix: 'Rupees')})',
            style:
                pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 24),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Container(
                width: 160,
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    top: pw.BorderSide(color: PdfColors.grey400),
                  ),
                ),
                padding: const pw.EdgeInsets.only(top: 4),
                child: pw.Text(
                  "Receiver's Signature",
                  style: const pw.TextStyle(
                      fontSize: 8, color: PdfColors.grey600),
                ),
              ),
              pw.Container(
                width: 160,
                decoration: const pw.BoxDecoration(
                  border: pw.Border(
                    top: pw.BorderSide(color: PdfColors.grey400),
                  ),
                ),
                padding: const pw.EdgeInsets.only(top: 4),
                child: pw.Text(
                  'For ${firm.name}',
                  textAlign: pw.TextAlign.right,
                  style: const pw.TextStyle(
                      fontSize: 8, color: PdfColors.grey600),
                ),
              ),
            ],
          ),
        ],
        footer: (context) => pw.Container(
          alignment: pw.Alignment.center,
          child: pw.Text(
            '${firm.name} • Statement of Account • '
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style:
                const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey600),
          ),
        ),
      ),
    );

    final bytes = await doc.save();
    final file = await _write(statement.partyName, period, 'pdf', bytes);
    return file.path;
  }

  static pw.Widget _pdfHeader(
      PartyStatement statement, FirmEntity firm, String period) {
    final brand = PdfColor.fromInt(0xFF1D4ED8);
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400),
        ),
      ),
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  firm.name.toUpperCase(),
                  style: pw.TextStyle(
                      fontSize: 15,
                      fontWeight: pw.FontWeight.bold,
                      color: brand),
                ),
                if ((firm.addressLine1 ?? '').isNotEmpty)
                  pw.Text(firm.addressLine1!,
                      style: const pw.TextStyle(
                          fontSize: 8.5, color: PdfColors.grey700)),
                if ((firm.gstin ?? '').isNotEmpty)
                  pw.Text('GSTIN: ${firm.gstin!.toUpperCase()}',
                      style: const pw.TextStyle(
                          fontSize: 8.5, color: PdfColors.grey700)),
                if ((firm.phone ?? '').isNotEmpty)
                  pw.Text('Phone: ${firm.phone!}',
                      style: const pw.TextStyle(
                          fontSize: 8.5, color: PdfColors.grey700)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text('STATEMENT OF ACCOUNT',
                  style: pw.TextStyle(
                      fontSize: 13, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 4),
              pw.Text('Party: ${statement.partyName}',
                  style: const pw.TextStyle(fontSize: 9.5)),
              pw.Text('Period: $period',
                  style: const pw.TextStyle(fontSize: 9.5)),
              pw.Text('Generated: ${Formatters.date(DateTime.now())}',
                  style: const pw.TextStyle(
                      fontSize: 8.5, color: PdfColors.grey600)),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _pdfSummary(PartyStatement statement) {
    pw.Widget cell(String label, String value, {bool bold = false}) {
      return pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.all(8),
          decoration: pw.BoxDecoration(
            color: PdfColor.fromInt(0xFFF3F6F5),
            border: pw.Border.all(color: PdfColors.grey300),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label,
                  style: pw.TextStyle(
                      fontSize: 7.5,
                      color: PdfColors.grey700,
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text(value,
                  style: pw.TextStyle(
                      fontSize: 11.5,
                      fontWeight: bold
                          ? pw.FontWeight.bold
                          : pw.FontWeight.normal)),
            ],
          ),
        ),
      );
    }

    return pw.Row(
      children: [
        cell('Opening Balance', Formatters.money(statement.opening)),
        pw.SizedBox(width: 6),
        cell('Total Debit', Formatters.money(statement.totalDebit)),
        pw.SizedBox(width: 6),
        cell('Total Credit', Formatters.money(statement.totalCredit)),
        pw.SizedBox(width: 6),
        cell('Closing Balance', Formatters.money(statement.closing),
            bold: true),
      ],
    );
  }

  static pw.Widget _pdfTable(PartyStatement statement) {
    pw.TextStyle header(String text) => pw.TextStyle(
        fontSize: 8,
        fontWeight: pw.FontWeight.bold,
        color: PdfColors.grey700);
    pw.TextStyle cellText(String text,
        {bool bold = false, pw.TextAlign? align}) {
      return pw.TextStyle(
          fontSize: 8.6,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          color: bold ? PdfColors.black : PdfColors.grey800);
    }

    pw.Widget padded(String text,
        {bool bold = false,
        bool header = false,
        pw.TextAlign? align,
        pw.TextStyle? style}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: pw.Text(text,
            textAlign: align,
            style: style ??
                cellText(text,
                    bold: bold || header, align: align)),
      );
    }

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(5),
        2: const pw.FlexColumnWidth(2.4),
        3: const pw.FlexColumnWidth(2.4),
        4: const pw.FlexColumnWidth(2.6),
      },
      children: [
        pw.TableRow(
          decoration:
              const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEFF3F2)),
          children: [
            padded('Date', header: true, style: header('Date')),
            padded('Particulars', header: true, style: header('Particulars')),
            padded('Debit',
                header: true,
                align: pw.TextAlign.right,
                style: header('Debit')),
            padded('Credit',
                header: true,
                align: pw.TextAlign.right,
                style: header('Credit')),
            padded('Balance',
                header: true,
                align: pw.TextAlign.right,
                style: header('Balance')),
          ],
        ),
        for (final line in statement.lines)
          pw.TableRow(
            children: [
              padded(Formatters.date(line.date)),
              padded(line.particulars),
              padded(
                line.debit == Decimal.zero
                    ? ''
                    : Formatters.money(line.debit, showSymbol: false),
                align: pw.TextAlign.right,
              ),
              padded(
                line.credit == Decimal.zero
                    ? ''
                    : Formatters.money(line.credit, showSymbol: false),
                align: pw.TextAlign.right,
              ),
              padded(
                Formatters.money(line.balance, showSymbol: false),
                align: pw.TextAlign.right,
                bold: true,
              ),
            ],
          ),
      ],
    );
  }

  /// Writes [statement] as a real .xlsx workbook; returns the file path.
  static Future<String> exportExcel({
    required PartyStatement statement,
    required FirmEntity firm,
    required DateTime? from,
    required DateTime? to,
  }) async {
    final excel = Excel.createExcel();

    final sheet = excel['Statement'];
    // The default "Sheet1" would linger empty next to ours.
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null && defaultName != 'Statement') {
      excel.rename(defaultName, 'Statement');
    }

    var row = 0;
    void put(int col, String value, {bool bold = false}) {
      final cell = CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);
      sheet.cell(cell).value = TextCellValue(value);
      if (bold) {
        sheet.cell(cell).cellStyle = CellStyle(bold: true);
      }
    }

    // Title block.
    put(0, firm.name, bold: true);
    row = 1;
    put(0, 'Statement of Account - ${statement.partyName}', bold: true);
    row = 2;
    put(0, 'Period: ${_periodLabel(from, to)}');
    row = 3;
    put(0, 'Generated: ${Formatters.date(DateTime.now())}');
    row = 5;

    // Header row.
    const headers = ['Date', 'Particulars', 'Debit', 'Credit', 'Balance'];
    for (var i = 0; i < headers.length; i++) {
      put(i, headers[i], bold: true);
    }
    row = 6;

    for (final line in statement.lines) {
      put(0, Formatters.isoDate(line.date));
      put(1, line.particulars);
      put(2,
          line.debit == Decimal.zero ? '' : Formatters.money(line.debit, showSymbol: false));
      put(3,
          line.credit == Decimal.zero ? '' : Formatters.money(line.credit, showSymbol: false));
      put(4, Formatters.money(line.balance, showSymbol: false), bold: true);
      row++;
    }

    row++;
    put(1, 'Closing Balance', bold: true);
    put(2, Formatters.money(statement.closing, showSymbol: false), bold: true);

    // Excel column widths are in character units.
    sheet.setColumnWidth(0, 13);
    sheet.setColumnWidth(1, 42);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 14);
    sheet.setColumnWidth(4, 15);

    final bytes = excel.save() ?? <int>[];
    final file =
        await _write(statement.partyName, _periodLabel(from, to), 'xlsx', bytes);
    return file.path;
  }

  static Future<File> _write(
      String partyName, String period, String ext, List<int> bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final statements = Directory(p.join(dir.path, 'atria', 'statements'));
    if (!statements.existsSync()) statements.createSync(recursive: true);
    final safeName = partyName.replaceAll(RegExp(r'[^\w-]+'), '_');
    final stamp = Formatters.isoDate(DateTime.now()).replaceAll('-', '');
    final file =
        File(p.join(statements.path, 'statement_${safeName}_$stamp.$ext'));
    await file.writeAsBytes(bytes);
    return file;
  }

  static String _periodLabel(DateTime? from, DateTime? to) {
    if (from == null) return 'All time';
    if (to == null) return 'From ${Formatters.date(from)}';
    return '${Formatters.date(from)} - ${Formatters.date(to)}';
  }
}
