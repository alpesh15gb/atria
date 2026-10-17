import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';

import '../../services/csv_export.dart';
import '../engine/report_result.dart';
import '../window/report_window.dart';

/// The one export path every report inherits.
///
/// CSV and Excel here; PDF and print in `ReportPdfBuilder`. All four are the
/// same job — **export what is on screen** — and having them in one place is
/// what makes "every report has an export affordance" true by construction
/// rather than by remembering to add one to each of 46 screens.
///
/// Two rules every format obeys:
///
/// 1. **The window and the filters go into the file.** An export without them is
///    a number with no meaning: a party statement covering an unstated three
///    months cannot be checked against anything.
/// 2. **Money exports as a number, never as text.** No rupee sign, no grouping.
///    A CA pastes the column into a spreadsheet and sums it; a formatted figure
///    is a string and the total comes out zero.
class ReportExportService {
  const ReportExportService();

  /// A safe filename stem: the title, with everything a filesystem or a share
  /// sheet objects to removed.
  static String fileStem(ReportResult result) {
    final title = result.spec.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    final stem = title.replaceAll(RegExp(r'^_+|_+$'), '');
    return '${stem.isEmpty ? 'report' : stem}_${exportTimestamp()}';
  }

  /// The header block that makes an exported file self-describing.
  List<List<Object?>> headerBlock(ReportResult result) {
    final rows = <List<Object?>>[
      [result.spec.title],
      ['Period', result.window.spanLabel],
      if (result.spec.groupBy.isGrouped)
        ['Grouped by', result.spec.groupBy.name],
      if (result.notes.isNotEmpty) ['Notes', result.notes.join(' | ')],
      ['Exported', DateTime.now().toIso8601String().substring(0, 16)],
      const [],
    ];
    return rows;
  }

  /// CSV, with the header block, the column names, the data, a total row and
  /// the spec's footnote.
  String toCsv(ReportResult result) {
    final spec = result.spec;
    final buffer = StringBuffer();
    for (final line in headerBlock(result)) {
      buffer.writeln(CsvExport.row(line));
    }
    buffer.writeln(CsvExport.row(spec.columns.map((c) => c.label).toList()));

    for (final group in result.groups) {
      for (final row in group.rows) {
        buffer.writeln(
          CsvExport.row(spec.columns.map((c) => row.export(c)).toList()),
        );
      }
      if (spec.groupBy.isGrouped) {
        buffer.writeln(
          CsvExport.row([
            spec.groupBy.totalLabel,
            for (final column in spec.columns.skip(1))
              column.isSummable
                  ? ReportRow.exportNumber(group.totalFor(column))
                  : '',
          ]),
        );
      }
    }

    // The grand total, always — including the label in column 1 so the row is
    // self-describing once it is separated from the table.
    buffer.writeln(
      CsvExport.row([
        'Total',
        for (final column in spec.columns.skip(1))
          column.isSummable
              ? ReportRow.exportNumber(result.grandTotalFor(column))
              : '',
      ]),
    );
    if (spec.footnote != null) {
      buffer
        ..writeln()
        ..writeln(CsvExport.row([spec.footnote!]));
    }
    return buffer.toString();
  }

  /// Excel, via the `excel` package.
  ///
  /// Numbers go in as [DoubleCellValue] with a number format rather than as
  /// text, which is the whole reason this is not just CSV with a different
  /// extension.
  Future<File> writeExcel(ReportResult result, Directory dir) async {
    final spec = result.spec;
    final excel = Excel.createExcel();
    final defaultName = excel.getDefaultSheet();
    if (defaultName != null && defaultName != spec.title) {
      excel.rename(defaultName, spec.title);
    }
    excel.setDefaultSheet(spec.title);
    final sheet = excel[spec.title];

    var r = 0;
    void text(int col, String value, {bool bold = false}) {
      sheet
          .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: r))
          .value = TextCellValue(
        value,
      );
      if (bold) {
        sheet
            .cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: r))
            .cellStyle = CellStyle(
          bold: true,
        );
      }
    }

    for (final line in headerBlock(result)) {
      for (var c = 0; c < line.length; c++) {
        text(c, '${line[c]}', bold: c == 0);
      }
      r++;
    }

    for (var c = 0; c < spec.columns.length; c++) {
      text(c, spec.columns[c].label, bold: true);
    }
    r++;

    void putRow(ReportRow row, {bool bold = false}) {
      for (var c = 0; c < spec.columns.length; c++) {
        final column = spec.columns[c];
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
        );
        if (column.isSummable) {
          cell.value = DoubleCellValue(row.number(column).toDouble());
          cell.cellStyle = CellStyle(
            numberFormat: NumFormat.standard_4,
            bold: bold,
          );
        } else {
          cell.value = TextCellValue(row.export(column));
          if (bold) cell.cellStyle = CellStyle(bold: true);
        }
      }
      r++;
    }

    for (final group in result.groups) {
      for (final row in group.rows) {
        putRow(row);
      }
      if (spec.groupBy.isGrouped) {
        // A subtotal row is text in column 1 and a real number in the rest, so
        // a spreadsheet can sum the whole block without the label breaking it.
        for (var c = 0; c < spec.columns.length; c++) {
          final column = spec.columns[c];
          final cell = sheet.cell(
            CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
          );
          if (c == 0) {
            cell.value = TextCellValue(spec.groupBy.totalLabel);
            cell.cellStyle = CellStyle(bold: true);
          } else if (column.isSummable) {
            cell.value = DoubleCellValue(group.totalFor(column).toDouble());
            cell.cellStyle = CellStyle(
              numberFormat: NumFormat.standard_4,
              bold: true,
            );
          }
        }
        r++;
      }
    }

    // Grand total, as numbers. Same reasoning as the subtotals.
    for (var c = 0; c < spec.columns.length; c++) {
      final column = spec.columns[c];
      final cell = sheet.cell(
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r),
      );
      if (c == 0) {
        cell.value = TextCellValue('Total');
        cell.cellStyle = CellStyle(bold: true);
      } else if (column.isSummable) {
        cell.value = DoubleCellValue(result.grandTotalFor(column).toDouble());
        cell.cellStyle = CellStyle(
          numberFormat: NumFormat.standard_4,
          bold: true,
        );
      }
    }
    r++;

    if (spec.footnote != null) {
      r++;
      text(0, spec.footnote!);
    }

    final file = File('${dir.path}/${fileStem(result)}.xlsx');
    final bytes = excel.save();
    // `excel.save()` returns null when the workbook could not be encoded.
    // Writing null would throw a TypeError from inside writeAsBytes, which
    // reads like a filesystem problem rather than an encoding one.
    if (bytes == null) {
      throw StateError('Could not encode ${spec.title} as a workbook.');
    }
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// CSV on disk, with the UTF-8 BOM Excel needs to read it as UTF-8.
  ///
  /// The BOM is written as an **escape**, not as the character itself. A literal
  /// U+FEFF in a source file survives most editors and some copy-pastes as the
  /// three visible characters `ï»¿`, and then the file starts with the *text*
  /// "ï»¿" rather than the byte mark — which is exactly what happened here, and
  /// what [gst_export_service.dart] already gets right.
  Future<File> writeCsv(ReportResult result, Directory dir) async {
    final file = File('${dir.path}/${fileStem(result)}.csv');
    await file.writeAsString(
      '\uFEFF${toCsv(result)}',
      encoding: utf8,
      flush: true,
    );
    return file;
  }

  /// One-line summary for the snackbar after an export, e.g.
  /// "Party Statement · 47 rows".
  ///
  /// The window's own [ReportWindow.spanLabel] is deliberately absent. It is
  /// already printed in the header block at the top of the file, and repeating
  /// it in a filename or a toast is how the two drift apart.
  static String describe(ReportResult result) {
    final parts = <String>[
      result.spec.title,
      '${result.count} ${result.count == 1 ? 'row' : 'rows'}',
    ];
    return parts.join(' · ');
  }
}
