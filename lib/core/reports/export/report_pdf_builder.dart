import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../services/pdf_fonts.dart';
import '../../services/pdf_template_style.dart';
import '../../utils/money.dart';
import '../engine/report_result.dart';
import '../spec/report_spec.dart';
import 'report_export_service.dart';

/// A report as a paginated PDF.
///
/// **Why this is not `PdfSections`.** Everything in that file assumes an
/// invoice's anatomy: a parties panel, an items table, a totals block, a
/// footer. A report has none of that — it has a header block, an arbitrarily
/// wide table whose columns are declared rather than known, group headings
/// scattered through it, and a total that must sit on the last page. Forcing a
/// report through it would mean passing a fake firm and a fake party list.
///
/// What it *does* reuse is the layer that matters: [PdfTemplateStyle] for the
/// page geometry and the ink, and [PdfFonts] so `₹` and Devanagari render rather
/// than printing as a placeholder box.
class ReportPdfBuilder {
  const ReportPdfBuilder({
    this.style = PdfTemplateStyle.classic,
    this.maxPages = 200,
  });

  final PdfTemplateStyle style;

  /// A ceiling, not a target. A year of a day book is thousands of rows; the
  /// `pdf` package paginates for us but will happily allocate a document large
  /// enough to OOM a 4GB phone if a source ever returns one.
  final int maxPages;

  /// Builds the bytes. Split from [write] so a test can assert on the document
  /// without touching a filesystem, and so the print path and the save path
  /// cannot drift apart.
  Future<Uint8List> build(
    ReportResult result, {
    required String title,
    PdfPageFormat? format,
  }) async {
    final spec = result.spec;
    // Helvetica has no ₹ (see PdfFonts); Inter rides along as a fallback.
    final doc = pw.Document(
      title: title,
      theme: await PdfFonts.theme(),
    );

    doc.addPage(
      pw.MultiPage(
        // The print preview passes the reader's own paper through [format]; every
        // other caller gets the firm's template page. Without the parameter a
        // reader who switched to A5 got an A4 document laid out at A4 widths,
        // which runs the right-hand columns off the edge of the page.
        pageFormat: format ?? style.pageFormat,
        margin: pw.EdgeInsets.symmetric(
          horizontal: style.gutter,
          vertical: 28,
        ),
        maxPages: maxPages,
        header: (context) => _runningHead(result, context),
        footer: (context) => _pageFoot(context),
        build: (context) => [
          _titleBlock(result),
          pw.SizedBox(height: 12),
          if (result.notes.isNotEmpty) _notes(result),
          _table(result),
          if (spec.footnote != null) ...[
            pw.SizedBox(height: 10),
            _footnote(spec.footnote!),
          ],
        ],
      ),
    );
    return doc.save();
  }

  /// Writes the PDF under the shared export directory and returns the file.
  Future<File> write(ReportResult result, Directory dir) async {
    final file = File('${dir.path}/${ReportExportService.fileStem(result)}.pdf');
    final bytes = await build(result, title: result.spec.title);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Hands the document to the platform's print dialog and returns whether the
  /// job was sent.
  ///
  /// **This is `Printing.layoutPdf`, not `Printing.sharePdf`.** The obvious
  /// spelling — share the bytes and let the user find the print option — opens a
  /// *share sheet*, not a print dialog, and a menu item labelled "Print" that
  /// sends the reader to a list of messaging apps is a menu item that does not do
  /// what it says. `layoutPdf` opens the real spooler preview, which is also
  /// where the reader gets to choose pages and copies.
  ///
  /// The document is rebuilt through [onLayout] rather than passed as fixed
  /// bytes, because the preview lets the reader change paper size and
  /// orientation and a document built for A4 lays out wrongly on A5. The
  /// template's own format is used on the first pass, so the preview opens on
  /// the firm's page and the reader only overrides it if they want to.
  ///
  /// Returns `false` when the reader cancels — which the caller reports as
  /// nothing, not as a failure, since a cancelled print job is not a broken
  /// one. Throws when the platform refuses, which is.
  Future<bool> print(ReportResult result, {String? jobName}) {
    final title = result.spec.title;
    return Printing.layoutPdf(
      name: jobName ?? title,
      format: style.pageFormat,
      // The printer's own settings win where the platform supports it (Windows).
      // Off elsewhere: it is documented as driver-dependent, and a driver that
      // misreads the page size prints every number off the right edge.
      usePrinterSettings: false,
      onLayout: (format) => build(result, title: title, format: format),
    );
  }

  // ---- Furniture ----------------------------------------------------------

  pw.Widget _titleBlock(ReportResult result) {
    final spec = result.spec;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          spec.title,
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
            color: style.ink,
          ),
        ),
        pw.SizedBox(height: 4),
        // The window on the page, not just in the file name. A printed report
        // gets separated from its cover sheet, and a figure with no period is
        // not evidence of anything.
        pw.Text(
          result.window.spanLabel,
          style: pw.TextStyle(fontSize: 9, color: style.inkSoft),
        ),
        if (spec.subtitle != null)
          pw.Text(
            spec.subtitle!,
            style: pw.TextStyle(fontSize: 9, color: style.inkSoft),
          ),
        pw.SizedBox(height: 8),
        pw.Divider(color: style.line, thickness: 0.6),
      ],
    );
  }

  pw.Widget _runningHead(ReportResult result, pw.Context context) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 6),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: style.line, width: 0.6),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            result.spec.title,
            style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
          ),
          pw.Text(
            result.window.spanLabel,
            style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
          ),
        ],
      ),
    );
  }

  pw.Widget _pageFoot(pw.Context context) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(top: 6),
      decoration: pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: style.line, width: 0.6),
        ),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            'Generated ${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ')}',
            style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
          ),
          pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
          ),
        ],
      ),
    );
  }

  pw.Widget _notes(ReportResult result) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      margin: const pw.EdgeInsets.only(bottom: 10),
      decoration: pw.BoxDecoration(
        color: style.tint,
        border: pw.Border.all(color: style.line, width: 0.5),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          for (final note in result.notes)
            pw.Text(
              note,
              style: pw.TextStyle(fontSize: 8.5, color: style.ink),
            ),
        ],
      ),
    );
  }

  pw.Widget _footnote(String text) {
    return pw.Text(
      text,
      style: pw.TextStyle(fontSize: 8, color: style.inkSoft),
    );
  }

  // ---- The table ----------------------------------------------------------

  /// The whole table, as a [pw.TableHelper].
  ///
  /// A `TableHelper` rather than a `Table` because the row stream is unbounded:
  /// `Table` lays out every row before it yields, so a 5,000-row report builds
  /// a 5,000-row widget tree in memory first. `TableHelper` pages it, which is
  /// what makes a year of a day book printable on a phone.
  /// The whole table.
  ///
  /// [pw.Table] rather than a hand-rolled column layout because it is the only
  /// one that shares width by flex, and a report's columns are declared as
  /// weights. The header row carries `repeat: true` so `MultiPage` draws it on
  /// every page — a heading row that appears on page 1 only makes page 7 a page
  /// of numbers with no way to tell what they are.
  pw.Widget _table(ReportResult result) {
    final spec = result.spec;
    return pw.Table(
      columnWidths: {
        for (var i = 0; i < spec.columns.length; i++)
          i: pw.FlexColumnWidth(spec.columns[i].flex.toDouble()),
      },
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(color: style.line, width: 0.4),
        bottom: pw.BorderSide(color: style.line, width: 0.6),
      ),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(color: style.footerBand),
          children: [
            for (final column in spec.columns)
              pw.Container(
                alignment: _alignment(column),
                padding: const pw.EdgeInsets.symmetric(
                  vertical: 5,
                  horizontal: 3,
                ),
                child: pw.Text(
                  column.label,
                  textAlign: _textAlign(column),
                  style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: pw.FontWeight.bold,
                    color: style.ink,
                  ),
                ),
              ),
          ],
        ),
        ..._pdfRows(result),
      ],
    );
  }

  /// Every printable row, group headings and totals included.
  List<pw.TableRow> _pdfRows(ReportResult result) {
    final spec = result.spec;
    final rows = <pw.TableRow>[];

    void dataRow(ReportRow row) {
      rows.add(
        pw.TableRow(
          children: [
            for (final column in spec.columns)
              pw.Container(
                alignment: _alignment(column),
                padding:
                    const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
                child: pw.Text(
                  row.text(column),
                  textAlign: _textAlign(column),
                  style: pw.TextStyle(
                    fontSize: 8.5,
                    fontWeight: column.emphasise ? pw.FontWeight.bold : null,
                    color: _colorFor(row, column),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    for (final group in result.groups) {
      if (spec.isGrouped) {
        rows.add(
          pw.TableRow(
            decoration: pw.BoxDecoration(color: style.tint),
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
                child: pw.Text(
                  group.label == null ? group.name : '${group.name} · ${group.label}',
                  style: pw.TextStyle(
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                    color: style.ink,
                  ),
                ),
              ),
              for (final _ in spec.columns.skip(1))
                pw.SizedBox.shrink(),
            ],
          ),
        );
      }
      for (final row in group.rows) {
        dataRow(row);
      }
      if (spec.isGrouped) {
        rows.add(
          pw.TableRow(
            decoration: pw.BoxDecoration(color: style.tint),
            children: [
              _cell(spec.groupBy.totalLabel, spec.columns.first, bold: true),
              for (final column in spec.columns.skip(1))
                column.isSummable
                    ? _cell(
                        ReportRow.exportNumber(group.totalFor(column)),
                        column,
                        bold: true,
                      )
                    : _cell('', column),
            ],
          ),
        );
      }
    }

    // The grand total, on the fill the style reserves for it. Repeating it on
    // every page would be wrong — it is one number.
    rows.add(
      pw.TableRow(
        decoration: pw.BoxDecoration(color: style.accentBand),
        children: [
          _cell('Total', spec.columns.first, bold: true),
          for (final column in spec.columns.skip(1))
            column.isSummable
                ? _cell(
                    ReportRow.exportNumber(result.grandTotalFor(column)),
                    column,
                    bold: true,
                  )
                : _cell('', column),
        ],
      ),
    );

    return rows;
  }

  pw.Widget _cell(
    String value,
    ReportColumn column, {
    bool bold = false,
  }) {
    return pw.Container(
      alignment: _alignment(column),
      padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 3),
      child: pw.Text(
        value,
        textAlign: _textAlign(column),
        style: pw.TextStyle(
          fontSize: 8.5,
          fontWeight: bold ? pw.FontWeight.bold : null,
          color: style.ink,
        ),
      ),
    );
  }

  pw.Alignment _alignment(ReportColumn column) => switch (
      column.effectiveAlign) {
    ReportColumnAlign.left => pw.Alignment.centerLeft,
    ReportColumnAlign.right => pw.Alignment.centerRight,
    ReportColumnAlign.center => pw.Alignment.center,
    ReportColumnAlign.auto => pw.Alignment.centerLeft,
  };

  pw.TextAlign _textAlign(ReportColumn column) => switch (
      column.effectiveAlign) {
    ReportColumnAlign.left => pw.TextAlign.left,
    ReportColumnAlign.right => pw.TextAlign.right,
    ReportColumnAlign.center => pw.TextAlign.center,
    ReportColumnAlign.auto => pw.TextAlign.left,
  };

  /// Red for a negative, and only where the column asked for it.
  ///
  /// A report where a negative is ordinary — a credit note, a sales return —
  /// sets `colorize` anyway: seeing the sign in red is information there.
  PdfColor? _colorFor(ReportRow row, ReportColumn column) {
    if (!column.colorize) return null;
    final value = row.number(column);
    if (Money.isNegative(value)) return PdfColors.red700;
    return null;
  }
}