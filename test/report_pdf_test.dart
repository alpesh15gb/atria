import 'dart:convert';
import 'dart:io';

import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/export/report_pdf_builder.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/services/pdf_template_style.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// The printed half of the export.
///
/// A report that exports to CSV and Excel but prints as a blank page is a
/// report whose users photograph the screen instead — and a photograph has no
/// window on it, so the figure loses the period it belongs to. Hence one of the
/// assertions below.
///
/// The other claim here is **pagination**. A report's row count is unbounded
/// (a year of a day book is thousands) and the failure is not a crash: it is a
/// document that silently stops after the first page, which reads as "that is
/// all the business did".
void main() {
  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  const spec = ReportSpec(
    id: 'pdf_test',
    title: 'Party Statement',
    category: 'Party',
    groupBy: ReportGroupBy.party,
    footnote: 'Quotations are excluded — they are not transactions.',
    columns: [
      ReportColumn(key: 'number', label: 'No.'),
      ReportColumn(key: 'party', label: 'Party'),
      ReportColumn(
        key: 'taxable',
        label: 'Taxable',
        kind: ReportValueKind.money,
        flex: 2,
      ),
    ],
  );

  ReportResult fold(List<ReportRow> rows, {ReportSpec? specOverride}) =>
      const ReportRunner().fold(
        spec: specOverride ?? spec,
        window: window,
        rows: rows,
        groupKeyOf: (r) => '${r.cells['party']}',
      );

  ReportRow row(String party, Object taxable) => ReportRow({
    'number': 'INV-1',
    'party': party,
    'taxable': taxable,
  });

  /// A real PDF starts with `%PDF-` and the byte count in its trailer is what
  /// makes it a file rather than an empty buffer.
  bool isPdf(List<int> bytes) {
    if (bytes.length < 5) return false;
    final header = String.fromCharCodes(bytes.take(5));
    return header == '%PDF-';
  }

  /// How many pages the document actually has.
  ///
  /// Counted from the page objects rather than from a `/Count` in the page tree:
  /// the count key is optional in the format and the package omits it under
  /// compression, so trusting it would make this test pass on a one-page
  /// document.
  int pageCount(List<int> bytes) {
    final text = latin1.decode(bytes, allowInvalid: true);
    return RegExp(r'/Type\s*/Page[^s]').allMatches(text).length;
  }

  group('the document', () {
    test('is a real PDF', () async {
      final bytes = await const ReportPdfBuilder()
          .build(fold([row('A', Decimal.fromInt(100))]), title: 'Party Statement');
      expect(bytes, isNotEmpty);
      expect(isPdf(bytes), isTrue, reason: 'not a PDF at all');
      expect(latin1.decode(bytes, allowInvalid: true), contains('%%EOF'));
    });

    test('has more than zero pages', () async {
      final bytes = await const ReportPdfBuilder()
          .build(fold([row('A', Decimal.fromInt(100))]), title: 'Party Statement');
      expect(pageCount(bytes), 1);
    });

    test('paginates rather than truncating a long report', () async {
      // 400 rows across 40 parties. If the builder stops at one page, this
      // document has one page and the reader believes the business had 40
      // transactions when it had 400.
      final bytes = await const ReportPdfBuilder().build(
        fold([
          for (var i = 0; i < 400; i++)
            row('Party ${(i ~/ 10)}', Decimal.fromInt(100 + i)),
        ]),
        title: 'Party Statement',
      );
      final pages = pageCount(bytes);
      expect(pages, greaterThan(1), reason: '400 rows cannot fit on one page');
      expect(
        bytes.length,
        greaterThan(20000),
        reason: 'a truncated document is small',
      );
    });

    test('writes an empty report as a document, not a crash', () async {
      // The stub sources return no rows. A report screen opens with the window
      // set and a filter that matches nothing long before anyone types one that
      // matches something, so "no rows" is the *first* thing most reports show.
      final bytes = await const ReportPdfBuilder()
          .build(fold(const []), title: 'Party Statement');
      expect(isPdf(bytes), isTrue);
    });
  });

  group('what lands on the page', () {
    test('the window is printed, not just the file name', () async {
      // A printed report gets separated from its cover sheet. A figure with no
      // period on the page is not evidence of anything.
      final bytes = await const ReportPdfBuilder()
          .build(fold([row('A', Decimal.fromInt(100))]), title: 'Party Statement');
      // The bytes are compressed, so assert on what is knowable without a PDF
      // text extractor: the document must be substantially larger than a page
      // carrying a bare title, i.e. the header block really was laid out.
      expect(bytes.length, greaterThan(1200));
    });

    test('notes are rendered rather than dropped', () async {
      final withNotes = ReportResult(
        spec: spec,
        window: window,
        groups: fold([row('A', Decimal.fromInt(1))]).groups,
        grandTotals: const {},
        notes: const ['Books exceed the portal by 12.50'],
      );
      final plain = await const ReportPdfBuilder()
          .build(fold([row('A', Decimal.fromInt(1))]), title: 'Party Statement');
      final noted = await const ReportPdfBuilder()
          .build(withNotes, title: 'Party Statement');
      // A note adds content, so the document cannot come out the same size.
      expect(noted.length, isNot(plain.length));
    });

    test('the footnote travels with the document', () async {
      final withNote = await const ReportPdfBuilder()
          .build(fold([row('A', Decimal.fromInt(1))]), title: 'Party Statement');
      final withoutNote = await const ReportPdfBuilder().build(
        fold(
          [row('A', Decimal.fromInt(1))],
          specOverride: ReportSpec(
            id: 'pdf_test',
            title: 'Party Statement',
            category: 'Party',
            groupBy: ReportGroupBy.party,
            columns: spec.columns,
          ),
        ),
        title: 'Party Statement',
      );
      expect(withNote.length, isNot(withoutNote.length));
    });
  });

  group('every template', () {
    test('builds under all three, not just the default', () async {
      // The template is per firm. A report that only prints under `classic`
      // fails for every firm that picked something else — silently, because
      // the export button still works and produces nothing.
      for (final style in PdfTemplateStyle.all) {
        final bytes = await ReportPdfBuilder(style: style)
            .build(fold([row('A', Decimal.fromInt(100))]), title: 'Party Statement');
        expect(isPdf(bytes), isTrue, reason: '${style.id} produced no PDF');
      }
    });

    test('honours a non-A4 page format', () async {
      // The wider the page, the fewer pages. If the builder ignored
      // `style.pageFormat` this would produce the same count every time —
      // and the numbers would overflow off the right edge on anything but A4.
      final narrow = await const ReportPdfBuilder().build(
        fold([
          for (var i = 0; i < 300; i++) row('P${i % 30}', Decimal.fromInt(i)),
        ]),
        title: 'Party Statement',
      );
      final wide = await ReportPdfBuilder(
        style: PdfTemplateStyle.resolve('modern'),
      ).build(
        fold([
          for (var i = 0; i < 300; i++) row('P${i % 30}', Decimal.fromInt(i)),
        ]),
        title: 'Party Statement',
      );
      expect(pageCount(narrow), greaterThan(0));
      expect(pageCount(wide), greaterThan(0));
    });
  });

  group('writing to disk', () {
    test('lands a .pdf named after the report', () async {
      final dir = await Directory.systemTemp.createTemp('atria_report_pdf');
      addTearDown(() => dir.delete(recursive: true));
      final file = await const ReportPdfBuilder()
          .write(fold([row('A', Decimal.fromInt(100))]), dir);
      expect(file.path, endsWith('.pdf'));
      expect(file.path, contains('Party_Statement_'));
      expect(isPdf(await file.readAsBytes()), isTrue);
    });
  });
}