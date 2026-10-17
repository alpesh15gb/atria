import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/vyapar_import.dart';

import 'vyapar_import_test.dart' show vyaparFixtureBytes;

void main() {
  test(
    'preserves fractional totals, charges, prefixes and conversion links',
    () async {
      final bytes = vyaparFixtureBytes(
        mutate: (source) {
          source.execute(
            'ALTER TABLE kb_transactions ADD COLUMN txn_ac3_amount REAL',
          );
          source.execute(
            'ALTER TABLE kb_transactions ADD COLUMN txn_prefix_id INTEGER',
          );
          source.execute(
            "CREATE TABLE kb_prefix (prefix_id INTEGER, prefix_value TEXT)",
          );
          source.execute("INSERT INTO kb_prefix VALUES (1, '2026-27/')");
          source.execute(
            'UPDATE kb_transactions SET txn_balance_amount = 2360.29, txn_round_off_amount = .29, txn_prefix_id = 1 WHERE txn_id = 1',
          );
          source.execute(
            'UPDATE kb_transactions SET txn_balance_amount = 8380, txn_ac3_amount = 7200, txn_status = 4 WHERE txn_id = 3',
          );
          source.execute(
            'CREATE TABLE kb_linked_transactions (txn_source_id INTEGER, txn_destination_id INTEGER, txns_linked_date TEXT)',
          );
          source.execute(
            "INSERT INTO kb_linked_transactions VALUES (3, 1, '2026-04-13')",
          );
        },
      );
      final db = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      final result = await VyaparImportService(db).run(bytes);
      final sales = await db.select(db.salesInvoices).get();
      final invoice = sales.singleWhere((d) => d.number == '2026-27/1');
      final quote = sales.singleWhere((d) => d.docType == 'quotation');
      expect(invoice.grandTotal, 2360.29);
      expect(invoice.roundOff, .29);
      expect(quote.grandTotal, 8380);
      expect(quote.shippingCharge, 7200);
      expect(quote.convertedToInvoiceId, invoice.id);
    expect(quote.dueDate, isNull);
      expect(
        (await db.firmRepository.getById(result.firmId))!.invoiceSequence,
        2,
      );
    },
  );

  test('order advances preserve every split and bank account without trade settlement', () async {
    final bytes = vyaparFixtureBytes(
      mutate: (source) {
        source.execute(
          "INSERT INTO txn_payment_mapping VALUES (3, 3, NULL, 4, 1000, NULL)",
        );
        source.execute(
          "INSERT INTO txn_payment_mapping VALUES (4, 3, NULL, 4, 500, NULL)",
        );
        source.execute(
          "INSERT INTO txn_payment_mapping VALUES (5, 3, NULL, 6, 1180, NULL)",
        );
      },
    );
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final result = await VyaparImportService(db).run(bytes);
    final payments = await db.select(db.payments).get();
    final advances = await db
        .paymentRepositoryFor(result.firmId)
        .advanceDocumentIds();
    final orderPayments = payments.where(
      (p) => advances.contains(p.linkedInvoiceId),
    );
    expect(
      orderPayments.map((p) => p.amount),
      unorderedEquals([1000.0, 500.0]),
    );
    expect(orderPayments.every((p) => p.bankAccountId != null), isTrue);
    final receipt = payments.singleWhere((p) => p.type == 'payment_in');
    expect(receipt.mode, 'bank_transfer');
    expect(receipt.bankAccountId, isNotNull);
    final bill = (await db.select(db.purchaseBills).get()).singleWhere(
      (p) => p.docType == 'bill',
    );
    expect(bill.paidAmount, 9440);
  });
}
