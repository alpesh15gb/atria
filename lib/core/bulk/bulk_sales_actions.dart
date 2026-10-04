import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/app_database.dart';
import '../database/repositories/sales_repository.dart';
import '../services/csv_export.dart';
import '../services/invoice_pdf.dart';
import '../utils/file_names.dart';
import 'bulk_actions.dart';

/// The bulk actions available on a list of sales documents, with no widget in
/// sight.
///
/// The screens that call this are thin — a selection bar, a button, a snackbar.
/// Everything that decides *what actually happens* lives here so it can be
/// tested directly, which matters more than usual for delete: the difference
/// between "3 of 12 invoices were deleted" and "12 invoices were deleted" is
/// the difference between a recoverable mistake and a reconciliation problem.
class BulkSalesActions {
  BulkSalesActions({
    required this.sales,
    required this.firmId,
    required this.exportBaseDirectory,
  });

  final SalesRepository? sales;
  final String firmId;

  /// Overridable so tests can write into a temp directory — see
  /// `CsvExport.setBaseDirectory`, which this mirrors for the PDF path.
  final Future<Directory> Function() exportBaseDirectory;

  /// Soft-deletes each selected document, stopping short of none and failing on
  /// none: one locked period must not abandon the rest of the batch.
  ///
  /// Returns exactly what happened. The caller undoes [BulkDeleteOutcome
  /// .deletedIds] — never the ids it asked for — so the undo cannot claim to
  /// restore a row that was still live in the books.
  Future<BulkDeleteOutcome> delete(List<String> ids) async {
    final repo = sales;
    if (repo == null) {
      return BulkDeleteOutcome(
        requested: ids.length,
        deletedIds: const {},
        failures: {for (final id in ids) id: StateError('no firm selected')},
      );
    }
    return bulkSoftDelete(ids, repo.softDelete);
  }

  /// Puts documents back after [delete]. Reports what it could not restore.
  Future<BulkDeleteOutcome> undoDelete(Set<String> ids) async {
    final repo = sales;
    if (repo == null) {
      return BulkDeleteOutcome(
        requested: ids.length,
        deletedIds: const {},
        failures: {for (final id in ids) id: StateError('no firm selected')},
      );
    }
    return bulkRestore(ids, repo.restore);
  }

  /// A CSV holding only the selected documents.
  ///
  /// Routed through [CsvExport]'s own base-directory override rather than this
  /// class's, so it lands beside every other CSV the app writes.
  Future<File> csv(Set<String> ids) async {
    final repo = sales;
    if (repo == null) throw StateError('no firm selected');
    return CsvExport(repo.db, firmId).sales(ids: ids);
  }

  /// Builds one PDF per selected document, into `apexbooks/invoices/`.
  ///
  /// Returns the files that were written **keyed by document id**, so a document
  /// deleted from under the selection cannot silently shift every later name —
  /// the caller reports "12 selected, 11 printed" rather than naming a file
  /// that is not the invoice they ticked.
  Future<BulkPdfResult> pdfs(List<String> ids, FirmEntity firm) async {
    final repo = sales;
    if (repo == null) {
      return const BulkPdfResult(files: {}, failures: {});
    }

    final root = await exportBaseDirectory();
    final outDir = Directory(p.join(root.path, 'apexbooks', 'invoices'));
    if (!outDir.existsSync()) outDir.createSync(recursive: true);

    final files = <String, File>{};
    final failures = <String, Object>{};
    for (final id in ids) {
      try {
        final doc = await repo.getById(id);
        if (doc == null) {
          failures[id] = StateError('document is no longer in the books');
          continue;
        }
        final bytes = await InvoicePdf.forFirm(firm)
            .build(invoice: doc, items: await repo.itemsFor(id));
        final file = File(
          p.join(outDir.path, '${sanitizeFileName(doc.number)}.pdf'),
        );
        await file.writeAsBytes(bytes, flush: true);
        files[id] = file;
      } catch (error) {
        failures[id] = error;
      }
    }
    return BulkPdfResult(files: files, failures: failures);
  }
}

/// What a bulk PDF run produced.
class BulkPdfResult {
  const BulkPdfResult({required this.files, required this.failures});

  /// Document id -> the PDF written for it.
  final Map<String, File> files;

  /// Document id -> why it could not be printed.
  final Map<String, Object> failures;

  int get printed => files.length;

  int get failed => failures.length;

  bool get isCompleteSuccess => failures.isEmpty;
}

/// Writes several generated PDFs and hands them to the OS share sheet.
///
/// `share_plus` takes a list of paths, so this is what a bulk print ends with —
/// one share sheet, N documents, rather than N dialogs.
class BulkPdfShare {
  BulkPdfShare({required this.shareFiles});

  /// Injected so tests can assert on the paths without the platform channel.
  final Future<void> Function(List<String> paths, {String? subject}) shareFiles;

  Future<void> share(BulkPdfResult result, {String? subject}) async {
    if (result.files.isEmpty) return;
    await shareFiles(
      result.files.values.map((f) => f.path).toList(),
      subject: subject,
    );
  }
}
