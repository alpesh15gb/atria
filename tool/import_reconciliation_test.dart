import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/vyapar_import.dart';
import 'package:atria/core/services/vyapar_backup.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/window/report_window.dart';

void main() {
  test('reconcile current Vyapar backup without touching live books', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    try {
      final sourcePath = Platform.environment['VYAPAR_AUDIT_BACKUP'];
      if (sourcePath == null) {
        markTestSkipped('Set VYAPAR_AUDIT_BACKUP to a local backup path.');
        return;
      }
      Directory('build/import-audit').createSync(recursive: true);
      final source = File(sourcePath);
      final result = await VyaparImportService(db)
          .run(source.readAsBytesSync());
      final tables = <String, Object?>{};
      for (final table in [
        'firms',
        'parties',
        'items',
        'sales_invoices',
        'sales_invoice_items',
        'purchase_bills',
        'purchase_bill_items',
        'payments',
        'stock_movements',
        'bank_accounts',
        'journal_entries',
        'journal_lines',
      ]) {
        try {
          tables[table] = (await db.customSelect('SELECT * FROM $table').get())
              .map((r) => r.data)
              .toList();
        } catch (e) {
          tables[table] = '$e';
        }
      }
      final statements = <String, Object?>{};
      for (final p in await db.partyRepositoryFor(result.firmId).all()) {
        final st = await db
            .reportRepositoryFor(result.firmId)
            .partyStatement(partyId: p.id);
        statements[p.name] = {
          'opening': st.opening.toString(),
          'closing': st.closing.toString(),
        };
      }
      final reports = <String, Object?>{};
      for (final definition in ReportCatalogue.all) {
        try {
          final r = await definition.run(
            db,
            result.firmId,
            const ReportWindow(
              preset: ReportWindowPreset.allTime,
              from: null,
              to: null,
            ),
          );
          reports[definition.spec.id] = {
            'count': r.count,
            'totals': r.grandTotals.map((k, v) => MapEntry(k, v.toString())),
            'notes': r.notes,
            'rows': [
              for (final g in r.groups)
                for (final row in g.rows)
                  row.cells.map((k, v) => MapEntry(k, v?.toString())),
            ],
          };
        } catch (e) {
          reports[definition.spec.id] = {'error': '$e'};
        }
      }
      final october = <String, Object?>{};
      for (final definition in ReportCatalogue.all) {
        try {
          final r = await definition.run(
            db,
            result.firmId,
            ReportWindow(
              preset: ReportWindowPreset.custom,
              from: DateTime(2026, 10, 1),
              to: DateTime(2026, 10, 10, 23, 59, 59),
            ),
          );
          october[definition.spec.id] = {
            'count': r.count,
            'totals': r.grandTotals.map((k, v) => MapEntry(k, v.toString())),
            'rows': [
              for (final g in r.groups)
                for (final row in g.rows)
                  row.cells.map((k, v) => MapEntry(k, v?.toString())),
            ],
          };
        } catch (e) {
          october[definition.spec.id] = {'error': '$e'};
        }
      }
      File('build/import-audit/imported.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'source': source.path,
          'warnings': result.warnings,
          'placeholderReports': [
            for (final d in ReportCatalogue.all)
              if (d.source is PlaceholderReportSource) d.spec.id,
          ],
          'tables': tables,
          'reports': reports,
          'statements': statements,
          'october': october,
        }),
      );
      expect(result.counts.skipped, 0);
      final snapshot = await VyaparBackupReader.read(source.readAsBytesSync());
      final importedSales = await db.select(db.salesInvoices).get();
      final importedPurchases = await db.select(db.purchaseBills).get();
      for (final document in snapshot.documents) {
        if (document.kind == VyaparDocKind.paymentIn ||
            document.kind == VyaparDocKind.paymentOut) {
          continue;
        }
        final isPurchase =
            document.kind == VyaparDocKind.purchaseBill ||
            document.kind == VyaparDocKind.purchaseOrder;
        final expected = document.cashAmount + document.balanceAmount;
        final actual = isPurchase
            ? importedPurchases
                  .singleWhere((d) => d.number == document.number)
                  .grandTotal
            : importedSales
                  .singleWhere(
                    (d) =>
                        d.number == document.number &&
                        d.docType ==
                            (document.kind == VyaparDocKind.quotation
                                ? 'quotation'
                                : document.kind == VyaparDocKind.saleOrder
                                ? 'sales_order'
                                : document.kind == VyaparDocKind.deliveryNote
                                ? 'delivery_note'
                                : 'invoice'),
                  )
                  .grandTotal;
        expect(
          actual,
          closeTo(expected, .005),
          reason: '${document.kind.name} ${document.number}',
        );
      }
      if (source.uri.pathSegments.last ==
          '10-10-2026_03.39.15_Apex_Integrations_VypBackup.vyb') {
        final accounts = await db.select(db.bankAccounts).get();
        expect(
          accounts.singleWhere((a) => a.name == 'DCB BANK').currentBalance,
          closeTo(763805.26, .005),
        );
        expect(
          accounts.singleWhere((a) => a.name == 'Cash').currentBalance,
          closeTo(-20327.5, .005),
        );
        expect(
          importedSales.where((d) => d.convertedToInvoiceId != null),
          hasLength(7),
        );
        expect(await db.select(db.payments).get(), hasLength(23));
        for (final entry in statements.entries) {
          final closing = double.parse(
            (entry.value as Map)['closing'] as String,
          );
          expect(
            closing,
            entry.key == 'M/s Keystone Infra Pvt Ltd' ? 218868 : 0,
            reason: entry.key,
          );
        }
      }
    } finally {
      await db.close();
    }
  });
}
