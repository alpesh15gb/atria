import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../database/app_database.dart';
import '../database/repositories/report_repository.dart';
import 'csv_export.dart';
import 'pdf_fonts.dart';
import '../utils/file_names.dart';
import '../utils/formatters.dart';
import '../utils/number_words.dart';

/// Statement of Account exports — a print-ready A4 PDF and a real .xlsx
/// workbook, both written to `<exports>/apexbooks/statements` and opened with the
/// system viewer.
class StatementExport {
  StatementExport._();

  /// Writes [statement] as a formatted A4 PDF; returns the file path.
  ///
  /// A full-year statement is a normal document, not an edge case, so the
  /// table has to survive more rows than fit on one A4 sheet. See
  /// [_pdfTable] for how the row stream paginates, and
  /// [StatementExport._kMaxPages] for why the page ceiling is raised.
  static Future<String> exportPdf({
    required PartyStatement statement,
    required FirmEntity firm,
    required DateTime? from,
    required DateTime? to,
  }) async {
    // Helvetica has no ₹ (see PdfFonts) — Inter rides along as a fallback.
    final doc = pw.Document(theme: await PdfFonts.theme());
    final period = _periodLabel(from, to);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(34, 30, 34, 30),
        maxPages: _kMaxPages,
        build: (context) => [
          _pdfHeader(statement, firm, period),
          pw.SizedBox(height: 14),
          _pdfSummary(statement),
          pw.SizedBox(height: 14),
          // The ledger. `pw.Table` is a SpanningWidget, so `pw.MultiPage`
          // re-lays it against the space left on each page, carries its row
          // cursor into the next page's pass and stops once every row is
          // consumed. The totals block that has to follow the last row is a
          // SEPARATE child of this list, so it is laid out after the table
          // has finished — on a fresh page, never on top of the ledger.
          // See [_pdfTable] for the repeated header.
          _pdfTable(statement),
          _pdfTail(statement, firm),
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

  /// A busy party's ledger can run to many hundreds of lines. `pw.MultiPage`
  /// defaults to a 20-page ceiling and throws `TooManyPagesException` past it
  /// in debug builds, which is the build a CA is looking at the file in. The
  /// ceiling exists to catch a runaway layout loop, not to ration a ledger.
  static const int _kMaxPages = 400;

  static pw.Widget _pdfHeader(
      PartyStatement statement, FirmEntity firm, String period) {
    final brand = PdfColor.fromInt(0xFF6D28D9); // violet-700
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
            // Cool violet-tinted neutrals, matching the invoice PDF — the
            // mint greys here were leftovers from the teal palette.
            color: PdfColor.fromInt(0xFFF6F5FA),
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

  /// The ledger table. One `pw.Table`, all rows — and `pw.Table` is a
  /// `SpanningWidget`, so `pw.MultiPage` does paginate it: when it overflows
  /// the page it is re-laid out against the remaining space, its row cursor
  /// (`_context.lastLine`) is saved into the next page's pass via
  /// `restoreContext`, and it stops once every row is consumed. That part
  /// works on its own.
  ///
  /// What it does NOT do is repeat the column headings. `pw.TableRow.repeat`
  /// is exactly that switch, and it defaults to `false` — so the second sheet
  /// of a full-year statement was a bare list of rupees under no headings at
  /// all. Set `repeat: true` below and the header is re-emitted at the top of
  /// every continuation page, which is also what makes the rest of the design
  /// (column widths, violet header fill, right-aligned money) legible page to
  /// page.
  static pw.Widget _pdfTable(PartyStatement statement) {
    pw.TextStyle headerStyle(String text) => pw.TextStyle(
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
        // `repeat: true` is what re-emits this row at the top of every
        // continuation page. Without it the second sheet of a statement was a
        // bare list of rupees under no column headings at all.
        pw.TableRow(
          repeat: true,
          decoration:
              const pw.BoxDecoration(color: PdfColor.fromInt(0xFFEDE9FE)),
          children: [
            padded('Date', header: true, style: headerStyle('Date')),
            padded('Particulars',
                header: true, style: headerStyle('Particulars')),
            padded('Debit',
                header: true,
                align: pw.TextAlign.right,
                style: headerStyle('Debit')),
            padded('Credit',
                header: true,
                align: pw.TextAlign.right,
                style: headerStyle('Credit')),
            padded('Balance',
                header: true,
                align: pw.TextAlign.right,
                style: headerStyle('Balance')),
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

  /// Closing balance in words plus the two signature rules.
  ///
  /// A separate child of the `MultiPage` build list, after the table. The
  /// `MultiPage` finishes laying out the table across as many pages as it
  /// needs and only then places this, so the grand total can never be
  /// interleaved with the ledger rows or painted over by the page footer. It
  /// is a `Column`, which is itself a SpanningWidget, so the whole block moves
  /// to a fresh page intact rather than being split across a page edge.
  static pw.Widget _pdfTail(PartyStatement statement, FirmEntity firm) {
    pw.Widget rule(String caption, {bool right = false}) {
      return pw.Container(
        width: 160,
        alignment:
            right ? pw.Alignment.topRight : pw.Alignment.topLeft,
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            top: pw.BorderSide(color: PdfColors.grey400),
          ),
        ),
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(
          caption,
          textAlign: right ? pw.TextAlign.right : pw.TextAlign.left,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      );
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(height: 12),
        pw.Text(
          'Closing balance: ${Formatters.money(statement.closing)}'
          ' (${NumberToWords.indianCurrency(statement.closing.abs().toDouble(), prefix: 'Rupees')})',
          style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 24),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            rule("Receiver's Signature"),
            rule('For ${firm.name}', right: true),
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

    /// Money goes in as a NUMBER with a number format, never as text.
    ///
    /// These used to be `Formatters.money(...)` written through
    /// `TextCellValue`, i.e. the string `"1,23,456.78"`. Excel then saw a
    /// string in every money column: no SUM, no chart, and a locale-dependent
    /// reinterpretation of the separator on a machine whose regional settings
    /// don't use Indian grouping — on which the column simply reads as
    /// nonsense. `csv_export.dart` deliberately keeps amounts plain for the
    /// same reason; the two exporters must agree, and this is the one a CA
    /// actually opens.
    ///
    /// `standard_4` is Excel's built-in `#,##0.00`, so the *stored* value is a
    /// plain double and only the *display* is grouped — Indian users see
    /// `1,23,456.78` because Excel localises the `,` token per the workbook
    /// locale, and the underlying number is exact.
    void putMoney(int col, Decimal value, {bool bold = false}) {
      final cell = CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);
      sheet.cell(cell).value =
          DoubleCellValue(double.parse(value.toStringAsFixed(2)));
      sheet.cell(cell).cellStyle = CellStyle(
        bold: bold,
        numberFormat: NumFormat.standard_4,
      );
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
      // A zero debit/credit stays blank rather than "0.00": a statement is
      // read as two sparse columns, and a run of zeroes reads as money owed.
      if (line.debit != Decimal.zero) putMoney(2, line.debit);
      if (line.credit != Decimal.zero) putMoney(3, line.credit);
      putMoney(4, line.balance, bold: true);
      row++;
    }

    row++;
    put(1, 'Closing Balance', bold: true);
    // Under the Balance column (4), not Debit (2) — the value sat in a
    // column whose heading it contradicts.
    putMoney(4, statement.closing, bold: true);

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
    // `exportRootDirectory`, not `getApplicationDocumentsDirectory`: on
    // Android the latter is app-private, so a statement the user cannot open
    // or send anywhere. See that function for the per-platform reasoning.
    final dir = await exportRootDirectory();
    final statements = Directory(p.join(dir.path, 'apexbooks', 'statements'));
    if (!statements.existsSync()) statements.createSync(recursive: true);
    final safeName = sanitizeFileName(partyName, fallback: 'party');
    // BOTH the period and a minute-resolution stamp go in the name. The old
    // `statement_<party>_<today>.<ext>` carried no period at all, so
    // exporting Apr–Jun and then Jul–Sep for the same party on the same day
    // silently overwrote the first statement — the exact thing a CA does when
    // reconciling a quarter, and exactly the thing nobody notices afterwards.
    // Minute resolution (matching `csv_export.dart`) closes the same-minute
    // case; the period slug makes the two files distinguishable by eye.
    final periodSlug = sanitizeFileName(
      period.replaceAll(RegExp(r'\s*-\s*'), '_to_').replaceAll(' ', '_'),
      fallback: 'period',
    );
    final stamp = exportTimestamp();
    final file = File(p.join(
        statements.path, 'statement_${safeName}_${periodSlug}_$stamp.$ext'));
    await file.writeAsBytes(bytes);
    return file;
  }

  static String _periodLabel(DateTime? from, DateTime? to) {
    if (from == null) return 'All time';
    if (to == null) return 'From ${Formatters.date(from)}';
    return '${Formatters.date(from)} - ${Formatters.date(to)}';
  }
}
