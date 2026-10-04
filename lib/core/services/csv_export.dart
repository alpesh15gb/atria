import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/app_database.dart';
import '../utils/formatters.dart';

/// The single place that decides where Atria writes an export.
///
/// `getApplicationDocumentsDirectory()` is right on Windows — it is the user's
/// visible `Documents` folder, so `Documents\atria\...` is something a person
/// can open, mail, or copy onto a pen drive without the app's help.
///
/// On **Android** the same call returns `/data/user/0/<pkg>/app_flutter`:
/// app-private, invisible to every file manager, unreachable by the GST
/// portal's Returns Offline Tool on a desktop, and shareable only through an
/// explicit share intent. A shopkeeper who exports GSTR-3B there has produced
/// a file they cannot get off the phone. Android therefore writes into the
/// app's directory on **shared** storage
/// (`/storage/emulated/0/Android/data/<pkg>/files`), which a file manager can
/// browse and `share_plus` can hand to any other app. No storage permission
/// is needed for either directory — app-scoped external storage is granted
/// implicitly, and nothing outside `Android/data` would be without
/// `MANAGE_EXTERNAL_STORAGE`, which a bookkeeping app should not ask for.
///
/// This only fixes *where* the bytes land. Every export site must still offer
/// Open **and** Share afterwards (see `backup_restore_screen.dart`): on
/// Android the share sheet is what actually gets the file to the portal tool,
/// and a path printed as the primary confirmation means nothing to a user
/// holding a phone.
///
/// Overridable so tests can point at a temp directory instead of the platform
/// channel (which has no handler under flutter_test).
Future<Directory> exportRootDirectory() async {
  final override = CsvExport._baseDirectoryOverride;
  if (override != null) return override;
  if (Platform.isAndroid) {
    try {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    } on Object {
      // No external volume mounted, or the provider is unavailable. The
      // app-private directory still accepts writes — Share is then the only
      // way out, which is why every export offers it.
    }
  }
  return getApplicationDocumentsDirectory();
}

/// A filename-safe, minute-resolution timestamp: `2026-10-03T14-32`.
///
/// Second resolution still collides when a user exports two periods of the
/// same party back to back, which is exactly what a CA does.
String exportTimestamp([DateTime? now]) =>
    (now ?? DateTime.now()).toIso8601String().replaceAll(':', '-').substring(0, 16);

/// Minimal CSV export for accountants: every list a Vyapar user would hand
/// to their CA, written as RFC-4180 CSV (quotes doubled, newlines inside
/// quoted fields, UTF-8 BOM so Excel opens it with the right encoding).
class CsvExport {
  /// Where files land. Overridable so tests can point at a temp directory
  /// instead of the platform channel (which has no handler under flutter_test).
  CsvExport(this.db, this.firmId, {Future<Directory>? baseDirectory});

  final AppDatabase db;
  final String firmId;

  static Future<Directory>? _baseDirectoryOverride;

  /// Sets the root directory used by [outputDir] (and by every other export).
  /// Call before exporting in tests; pass null to restore the platform default.
  static void setBaseDirectory(Future<Directory>? directory) {
    _baseDirectoryOverride = directory;
  }

  static Future<Directory> outputDir() => exportRootDirectory();

  static String esc(Object? value) {
    final s = value?.toString() ?? '';
    final needsQuote =
        s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');
    final doubled = s.replaceAll('"', '""');
    return needsQuote ? '"$doubled"' : doubled;
  }

  static String row(List<Object?> cells) => cells.map(esc).join(',');

  /// CSV amounts stay plain (no ₹ or grouping) so spreadsheet formulas work.
  String _money(num? v) =>
      v == null ? '' : v.toDouble().toStringAsFixed(2);

  Future<File> parties() async {
    final rows = await (db.select(db.parties)
          ..where((t) =>
              t.firmId.equals(firmId) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
    final buf = StringBuffer()
      ..writeln(row([
        'Name', 'Type', 'GSTIN', 'GST Type', 'Phone', 'Email', 'City',
        'State Code', 'Opening Balance', 'Opening Type', 'Notes',
      ]));
    for (final r in rows) {
      buf.writeln(row([
        r.name, r.type, r.gstin, r.gstType, r.phone, r.email, r.city,
        r.stateCode, _money(r.openingBalance), r.openingBalanceType, r.notes,
      ]));
    }
    return _write('parties', buf);
  }

  Future<File> items() async {
    final rows = await (db.select(db.items)
          ..where((t) =>
              t.firmId.equals(firmId) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm(expression: t.name)]))
        .get();
    final buf = StringBuffer()
      ..writeln(row([
        'Name', 'SKU', 'HSN/SAC', 'Unit', 'Sale Price', 'Purchase Price',
        'MRP', 'GST %', 'Cess %', 'Is Service', 'Stock Type', 'Current Stock',
        'Low Stock Alert', 'Barcode',
      ]));
    for (final r in rows) {
      buf.writeln(row([
        r.name, r.sku, r.hsn, r.unit, _money(r.salePrice),
        _money(r.purchasePrice), _money(r.mrp), r.gstRate, r.cessRate,
        r.isService ? 'yes' : 'no', r.stockType, r.currentStock,
        r.lowStockAlert, r.barcode,
      ]));
    }
    return _write('items', buf);
  }

  Future<File> sales() async {
    final rows = await (db.select(db.salesInvoices)
          ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.invoiceDate)]))
        .get();
    final buf = StringBuffer()
      ..writeln(row([
        'Date', 'Number', 'Type', 'Party', 'Party GSTIN', 'Taxable',
        'CGST', 'SGST', 'IGST', 'Cess', 'Round Off', 'Grand Total',
        'Paid', 'Balance', 'Payment Status', 'Status',
      ]));
    for (final r in rows) {
      buf.writeln(row([
        Formatters.date(r.invoiceDate), r.number, r.docType, r.partyName,
        r.partyGstin, _money(r.taxableValue), _money(r.cgst), _money(r.sgst),
        _money(r.igst), _money(r.cess), _money(r.roundOff),
        _money(r.grandTotal), _money(r.paidAmount), _money(r.balanceDue),
        r.paymentStatus, r.status,
      ]));
    }
    return _write('sales', buf);
  }

  Future<File> purchases() async {
    final rows = await (db.select(db.purchaseBills)
          ..where((t) => t.firmId.equals(firmId) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.billDate)]))
        .get();
    final buf = StringBuffer()
      ..writeln(row([
        'Date', 'Number', 'Type', 'Supplier', 'Supplier GSTIN',
        'Supplier Invoice No', 'Taxable', 'CGST', 'SGST', 'IGST',
        'Grand Total', 'Paid', 'Balance', 'Status',
      ]));
    for (final r in rows) {
      buf.writeln(row([
        Formatters.date(r.billDate), r.number, r.docType, r.partyName,
        r.partyGstin, r.supplierInvoiceNumber, _money(r.taxableValue),
        _money(r.cgst), _money(r.sgst), _money(r.igst), _money(r.grandTotal),
        _money(r.paidAmount), _money(r.balanceDue), r.status,
      ]));
    }
    return _write('purchases', buf);
  }

  Future<File> expenses() async {
    final rows = await (db.select(db.expenses)
          ..where((t) =>
              t.firmId.equals(firmId) & t.isDeleted.equals(false))
          ..orderBy([(t) => OrderingTerm.desc(t.date)]))
        .get();
    final buf = StringBuffer()
      ..writeln(row([
        'Date', 'Number', 'Type', 'Category', 'Amount', 'GST', 'Mode',
        'Vendor', 'Reference', 'Notes',
      ]));
    for (final r in rows) {
      buf.writeln(row([
        Formatters.date(r.date), r.number, r.type, r.category,
        _money(r.amount), _money(r.gstAmount), r.mode, r.vendorName,
        r.reference, r.notes,
      ]));
    }
    return _write('expenses', buf);
  }

  Future<File> _write(String name, StringBuffer buf) async {
    final dir = await outputDir();
    final outDir = Directory(p.join(dir.path, 'atria', 'exports'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final stamp = exportTimestamp();
    final file = File(p.join(outDir.path, '${name}_$stamp.csv'));
    // BOM so Windows Excel detects UTF-8 (party names are not ASCII).
    return file.writeAsString('\uFEFF${buf.toString()}', flush: true);
  }
}
