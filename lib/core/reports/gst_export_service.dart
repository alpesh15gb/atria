import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:path/path.dart' as p;

import '../services/csv_export.dart';
import 'gst_return_builder.dart';
import 'gstr1_report.dart';

/// Writes GST return files to `<exports>/atria/gst/<gstin>/<period>/`:
///  * `gstr1_<gstin>_<fp>.json` — upload-ready for the GST portal's Returns
///    Offline Tool (v1.1 schema);
///  * `gstr1_<section>.csv` — spreadsheet-readable worksheets per GSTR-1 table;
///  * `gstr3b_...json/csv` — the 3B summary tables.
/// Excel opens these CSVs with the UTF-8 BOM + comma separators cleanly, so a
/// true .xlsx writer is not required for a file the user opens in Excel; the
/// buttons say "JSON + CSV" for exactly this reason.
///
/// On Android the destination is the app's shared-storage directory rather
/// than the app-private one — see `exportRootDirectory`. A return the user
/// cannot reach is a return they cannot file.
///
/// One month of a fiscal-year summary.
///
/// A fiscal-year view is not a portal upload — GSTR-1 and 3B are filed month
/// by month — so this is deliberately a *working paper*: what each month of the
/// year came to, in one sheet, for the accountant who reconciles the year.
class FiscalYearGstRow {
  /// Every amount is required: `Decimal.zero` is not a compile-time constant,
  /// and a defaulted column here would quietly print a blank month.
  const FiscalYearGstRow({
    required this.period,
    required this.taxable,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
    required this.itc,
    required this.netPayable,
    required this.zeroRated,
    required this.nilRated,
  });

  /// Filing period, MM-YYYY.
  final String period;
  final Decimal taxable;
  final Decimal igst;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal cess;
  final Decimal itc;
  final Decimal netPayable;
  final Decimal zeroRated;
  final Decimal nilRated;
}

class GstExportService {
  GstExportService();

  Future<Directory> exportGstr1(Gstr1Report report) async {
    final dir = await _periodDir(report.firmGstin, report.fp);
    final jsonFile = File(p.join(dir.path,
        'gstr1_${report.firmGstin}_${report.fp}.json'));
    await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true);

    await _writeCsv(p.join(dir.path, 'gstr1_b2b.csv'), _b2bCsv(report));
    await _writeCsv(p.join(dir.path, 'gstr1_b2cl.csv'), _b2clCsv(report));
    await _writeCsv(p.join(dir.path, 'gstr1_b2cs.csv'), _b2csCsv(report));
    await _writeCsv(p.join(dir.path, 'gstr1_cdnr.csv'), _cdnrCsv(report));
    await _writeCsv(p.join(dir.path, 'gstr1_cdnur.csv'), _cdnurCsv(report));
    await _writeCsv(p.join(dir.path, 'gstr1_hsn.csv'), _hsnCsv(report));
    return dir;
  }

  Future<Directory> exportGstr3b(Gstr3bReport report,
      {String gstin = ''}) async {
    final dir = await _periodDir(gstin, report.fp);
    final jsonFile =
        File(p.join(dir.path, 'gstr3b_${report.fp}.json'));
    await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true);

    final rows = <List<Object?>>[
      ['Table', 'Particulars', 'Taxable Value', 'IGST', 'CGST', 'SGST', 'Cess'],
      ['3.1(a)', 'Outward taxable supplies',
          _n(report.outwardTaxable), _n(report.outwardIgst),
          _n(report.outwardCgst), _n(report.outwardSgst),
          _n(report.outwardCess)],
      ['3.1(b)', 'Zero-rated (exports/SEZ)', _n(report.zeroRated), 0, 0, 0, 0],
      ['3.1(c)', 'Nil-rated / exempt', _n(report.nilRated), 0, 0, 0, 0],
      ['3.1(d)', 'Inward liable to reverse charge', 0,
          _n(report.reverseChargeTax), 0, 0, 0],
      ['4(A5)', 'All other ITC', '', _n(report.itcAllOther), '', '', ''],
      ['4(B)', 'ITC reversed', '', _n(report.itcReversed), '', '', ''],
      ['4(C)', 'Net ITC available', '', _n(report.netItc), '', '', ''],
      ['5', 'Nil-rated inward + non-GST inward',
          _n(report.inwardNilRated), '', '', '', ''],
      ['Net', 'Net tax payable', '', _n(report.netPayable), '', '', ''],
    ];
    await _writeCsv(p.join(dir.path, 'gstr3b_summary.csv'), rows);
    return dir;
  }

  Future<Directory> exportReconciliation(
      Gstr2aReconciliation rec, String gstin, String fp) async {
    final dir = await _periodDir(gstin, fp);
    // The totals row has to land under its OWN heading. It used to be
    // ['Totals', '', booksTotalTax, portalTotalTax] against a six-column
    // header, so the books *tax* printed under "Books Taxable", the portal
    // *tax* under "Books Tax", and both taxable columns were left blank —
    // the one row a CA checks first was the one row nobody could read.
    // The taxable totals aren't carried on the report, so they are summed
    // from the rows above; summing them keeps the sheet self-consistent.
    var booksTaxable = Decimal.zero;
    var portalTaxable = Decimal.zero;
    for (final r in rec.rows) {
      booksTaxable += _d(r.booksTaxable);
      portalTaxable += _d(r.portalTaxable);
    }
    final rows = <List<Object?>>[
      ['Invoice No', 'Status', 'Books Taxable', 'Books Tax',
          'Portal Taxable', 'Portal Tax'],
      for (final r in rec.rows)
        [
          r.invoiceNumber,
          r.status,
          r.booksTaxable ?? '',
          r.booksTax ?? '',
          r.portalTaxable ?? '',
          r.portalTax ?? '',
        ],
      [],
      [
        'Totals',
        '',
        _n(booksTaxable),
        _n(_d(rec.booksTotalTax)),
        _n(portalTaxable),
        _n(_d(rec.portalTotalTax)),
      ],
    ];
    await _writeCsv(p.join(dir.path, 'gstr2a_reconciliation.csv'), rows);
    return dir;
  }

  /// One month's totals for the fiscal-year summary.
  Future<Directory> exportFiscalYear({
    required String gstin,
    required String fyLabel,
    required List<FiscalYearGstRow> months,
  }) async {
    final dir = await _periodDir(gstin, 'FY-$fyLabel');
    final rows = <List<Object?>>[
      ['Period', 'Taxable', 'IGST', 'CGST', 'SGST', 'Cess', 'ITC',
          'Net payable', 'Zero-rated', 'Nil-rated'],
      for (final m in months)
        [
          m.period,
          _n(m.taxable),
          _n(m.igst),
          _n(m.cgst),
          _n(m.sgst),
          _n(m.cess),
          _n(m.itc),
          _n(m.netPayable),
          _n(m.zeroRated),
          _n(m.nilRated),
        ],
      [],
      [
        'Total',
        _n(_sum(months, (m) => m.taxable)),
        _n(_sum(months, (m) => m.igst)),
        _n(_sum(months, (m) => m.cgst)),
        _n(_sum(months, (m) => m.sgst)),
        _n(_sum(months, (m) => m.cess)),
        _n(_sum(months, (m) => m.itc)),
        _n(_sum(months, (m) => m.netPayable)),
        _n(_sum(months, (m) => m.zeroRated)),
        _n(_sum(months, (m) => m.nilRated)),
      ],
    ];
    await _writeCsv(
        p.join(dir.path, 'fy_${fyLabel}_gst_summary.csv'), rows);
    return dir;
  }

  Decimal _sum(
    List<FiscalYearGstRow> rows,
    Decimal Function(FiscalYearGstRow) pick,
  ) {
    var total = Decimal.zero;
    for (final row in rows) {
      total += pick(row);
    }
    return total;
  }

  // ---- CSV builders -------------------------------------------------------

  List<List<Object?>> _b2bCsv(Gstr1Report r) => [
        ['Customer GSTIN', 'Invoice No', 'Date', 'POS', 'Invoice Value',
            'Rate', 'Taxable', 'IGST', 'CGST', 'SGST', 'Cess'],
        for (final g in r.b2b)
          for (final inv in g.invoices)
            for (final it in inv.itms)
              [
                g.ctin, inv.inum, inv.idt, inv.pos, _n(inv.val), it.rate,
                _n(it.taxableValue), _n(it.igst), _n(it.cgst),
                _n(it.sgst), _n(it.cess),
              ],
      ];

  List<List<Object?>> _b2csCsv(Gstr1Report r) => [
        ['Supply Type', 'POS', 'Rate', 'Taxable', 'IGST', 'CGST', 'SGST',
            'Cess'],
        for (final g in r.b2cs)
          [
            g.supplyType, g.pos, g.rate, _n(g.taxableValue), _n(g.igst),
            _n(g.cgst), _n(g.sgst), _n(g.cess),
          ],
      ];

  List<List<Object?>> _b2clCsv(Gstr1Report r) => [
        ['POS', 'Invoice No', 'Date', 'Invoice Value', 'Rate', 'Taxable',
            'IGST', 'CGST', 'SGST', 'Cess'],
        for (final g in r.b2cl)
          for (final inv in g.invoices)
            for (final it in inv.itms)
              [
                g.pos, inv.inum, inv.idt, _n(inv.val), it.rate,
                _n(it.taxableValue), _n(it.igst), _n(it.cgst),
                _n(it.sgst), _n(it.cess),
              ],
      ];

  List<List<Object?>> _cdnrCsv(Gstr1Report r) => [
        ['Customer GSTIN', 'Note No', 'Date', 'Note Value', 'Type', 'POS',
            'Rate', 'Taxable', 'IGST', 'CGST', 'SGST', 'Cess'],
        for (final g in r.cdnr)
          for (final n in g.notes)
            for (final it in n.itms)
              [
                g.ctin, n.ntNum, n.ntDt, _n(n.val), n.ntty, n.pos, it.rate,
                _n(it.taxableValue), _n(it.igst), _n(it.cgst),
                _n(it.sgst), _n(it.cess),
              ],
      ];

  List<List<Object?>> _cdnurCsv(Gstr1Report r) => [
        ['Note No', 'Date', 'Note Value', 'Type', 'POS', 'Supply Type',
            'Taxable', 'IGST', 'CGST', 'SGST', 'Cess'],
        for (final n in r.cdnur)
          [
            n.ntNum, n.ntDt, _n(n.val), n.ntty, n.pos, n.supplyType,
            _n(n.taxableValue), _n(n.igst), _n(n.cgst), _n(n.sgst),
            _n(n.cess),
          ],
      ];

  List<List<Object?>> _hsnCsv(Gstr1Report r) => [
        ['HSN/SAC', 'Description', 'UQC', 'Qty', 'Total Value', 'Taxable',
            'IGST', 'CGST', 'SGST', 'Cess'],
        for (final h in r.hsn)
          [
            h.hsn, h.description, h.uqc, _n(h.quantity), _n(h.totalValue),
            _n(h.taxableValue), _n(h.igst), _n(h.cgst), _n(h.sgst),
            _n(h.cess),
          ],
      ];

  Object _n(Decimal d) => double.tryParse(d.toStringAsFixed(2)) ?? 0;

  /// A nullable money column off the reconciliation, as an exact [Decimal].
  /// These arrive as `double`s from the database, so they are pinned to the
  /// reported 2dp before any arithmetic — a total that disagrees with the sum
  /// of its own rows by a paisa is worse than no total at all.
  Decimal _d(double? v) =>
      v == null ? Decimal.zero : Decimal.parse(v.toStringAsFixed(2));

  /// Period folder keyed by firm GSTIN then filing period — two firms
  /// filing the same month must not overwrite each other's returns.
  Future<Directory> _periodDir(String gstin, String fp) async {
    final root = await exportRootDirectory();
    final safeGstin = gstin.trim().isEmpty ? 'NOGSTIN' : gstin.trim();
    final dir = Directory(p.join(root.path, 'atria', 'gst', safeGstin, fp));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _writeCsv(String path, List<List<Object?>> rows) async {
    final sb = StringBuffer();
    // UTF-8 BOM so Excel decodes ₹ and Devanagari correctly.
    sb.write('\uFEFF');
    for (final row in rows) {
      sb.writeln([
        for (final cell in row)
          '"${'$cell'.replaceAll('"', '""')}"',
      ].join(','));
    }
    await File(path).writeAsString(sb.toString(), flush: true);
  }
}
