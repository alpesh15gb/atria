import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'gst_return_builder.dart';
import 'gstr1_report.dart';

/// Writes GST return files to `<Documents>/atria/gst/<period>/`:
///  * `gstr1_<gstin>_<fp>.json` — upload-ready for the GST portal's Returns
///    Offline Tool (v1.1 schema);
///  * `gstr1_<section>.csv` — Excel-readable worksheets per GSTR-1 table;
///  * `gstr3b_...json/csv` — the 3B summary tables.
/// Excel opens CSVs with UTF-8 BOM + comma separators cleanly; a true .xlsx
/// writer is a heavier dependency and can come later without format churn.
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
      ['Totals', '', rec.booksTotalTax.toStringAsFixed(2),
          rec.portalTotalTax.toStringAsFixed(2)],
    ];
    await _writeCsv(p.join(dir.path, 'gstr2a_reconciliation.csv'), rows);
    return dir;
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

  /// Period folder keyed by firm GSTIN then filing period — two firms
  /// filing the same month must not overwrite each other's returns.
  Future<Directory> _periodDir(String gstin, String fp) async {
    final docs = await getApplicationDocumentsDirectory();
    final safeGstin = gstin.trim().isEmpty ? 'NOGSTIN' : gstin.trim();
    final dir = Directory(p.join(docs.path, 'atria', 'gst', safeGstin, fp));
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
