import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/vyapar_backup.dart';
import 'package:atria/core/services/vyapar_import.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Swipe book, converted by `tools/swipe_to_vyb.py` into our `.vyb` backup
/// format, has to import through the same reader and importer a real Vyapar
/// backup does — that is the whole point of the converter: no second importer,
/// no second set of rules for GST, stock or party balances.
///
/// The fixture is generated from `tools/sample_swipe_cache/` (the cached Swipe
/// Partner API responses) with:
///
///     python tools/swipe_to_vyb.py --from-json tools/sample_swipe_cache \
///       --from 01-04-2026 --to 31-03-2027 --docs invoice,purchase \
///       --out test/fixtures/swipe_sample.vyb \
///       --firm-name "Active IT Solutions" --firm-gstin 36CZFPM0045M2Z7
///
/// It holds two invoices (one settled by a standalone payment, one paid on the
/// document itself), a purchase bill part-paid by a cash payment out, three
/// catalog items, a cancelled invoice that must be skipped, and two expenses.
///
/// This test is the contract between the script and the app: if the mapping
/// drifts — a wrong `txn_type`, a doubled balance, a lost line, a payment that
/// no longer links — it fails here rather than in the user's books.
void main() {
  const fixture = 'test/fixtures/swipe_sample.vyb';

  Future<(AppDatabase, VyaparImportResult, VyaparSnapshot)> importFixture() async {
    final db = AppDatabase.test(NativeDatabase.memory());
    final bytes = File(fixture).readAsBytesSync();
    final snapshot = await VyaparBackupReader.read(bytes);
    final service = VyaparImportService(db);
    final preview = await service.preview(bytes);

    // The dry run has to see the same book the import writes.
    expect(preview.firmName, 'Active IT Solutions');
    expect(preview.counts.saleInvoices, 2);
    expect(preview.counts.purchaseBills, 1);
    expect(preview.counts.items, 3);
    // Two recorded payments plus the one recorded on the invoice itself.
    expect(preview.counts.payments, 3);

    final result = await service.run(bytes);
    return (db, result, snapshot);
  }

  test('a Swipe export imports as a full set of books', () async {
    final (db, result, _) = await importFixture();
    final firmId = result.firmId;

    expect(result.counts.saleInvoices, 2);
    expect(result.counts.purchaseBills, 1);
    expect(result.counts.payments, 3);
    expect(result.counts.parties, 3);
    expect(result.counts.items, 3);

    final firm = await db.firmRepository.getById(firmId);
    expect(firm!.name, 'Active IT Solutions');
    expect(firm.gstin, '36CZFPM0045M2Z7');
    expect(firm.stateCode, '36');

    await db.close();
  });

  test('invoices keep their lines, GST and Swipe numbers', () async {
    final (db, result, _) = await importFixture();
    final invoices =
        await db.salesRepositoryFor(result.firmId).list(docType: 'invoice');
    expect(invoices.map((invoice) => invoice.number), containsAll(<String>[
      'INV-2026-001',
      'INV-2026-002',
    ]));

    final first =
        invoices.firstWhere((invoice) => invoice.number == 'INV-2026-001');
    // 2 x ₹1,000 at 18%: a Telangana firm billing a Telangana customer.
    expect(first.grandTotal, 2360);
    expect(first.cgst, 180);
    expect(first.sgst, 180);
    expect(first.igst, 0);
    expect(first.isInterState, isFalse);
    expect(first.placeOfSupply, '36');

    final lines =
        await db.salesRepositoryFor(result.firmId).itemsFor(first.id);
    expect(lines, hasLength(1));
    expect(lines.single.name, 'Canon NPG90 Toner');
    expect(lines.single.quantity.toDouble(), 2);

    await db.close();
  });

  test('payments in and out link back to the document they settle', () async {
    final (db, result, _) = await importFixture();
    final payments =
        await db.paymentRepositoryFor(result.firmId).list(limit: 50);

    expect(payments, hasLength(3));
    final incoming = payments.firstWhere(
      (payment) => payment.type == 'payment_in' && payment.amount == 2360,
    );
    expect(incoming.partyName, 'M/s Keystone Infra Pvt Ltd');

    final outgoing =
        payments.firstWhere((payment) => payment.type == 'payment_out');
    expect(outgoing.amount, 5000);
    expect(outgoing.mode, 'cash');

    // The invoice that was paid through Swipe's own payment modes came across
    // too, as a UPI receipt against INV-2026-002.
    final upi = payments.firstWhere((payment) => payment.amount == 1180);
    expect(upi.type, 'payment_in');
    expect(upi.mode, 'upi');

    // The standalone receipt settled INV-2026-001 in full; the cash payment out
    // left ₹4,440 on the supplier bill. Neither figure may be counted twice.
    final invoices =
        await db.salesRepositoryFor(result.firmId).list(docType: 'invoice');
    final settled =
        invoices.firstWhere((invoice) => invoice.number == 'INV-2026-001');
    expect(settled.paidAmount, 2360);
    expect(settled.balanceDue, 0);
    expect(settled.paymentStatus, 'paid');

    final bills =
        await db.purchaseRepositoryFor(result.firmId).list(docType: 'bill');
    expect(bills, hasLength(1));
    expect(bills.single.number, 'SUP-001');
    expect(bills.single.paidAmount, 5000);
    expect(bills.single.balanceDue, 4440);

    await db.close();
  });

  test('whoever billed us is a supplier, whoever was invoiced a customer',
      () async {
    final (db, result, _) = await importFixture();
    final parties = await db.partyRepositoryFor(result.firmId).all();

    expect(
      parties.firstWhere((party) => party.name.startsWith('M/s Keystone')).type,
      'customer',
    );
    expect(
      parties
          .firstWhere((party) => party.name == 'I-HEAP ELECTRONICS PVT LTD')
          .type,
      'supplier',
    );
    final keystone =
        parties.firstWhere((party) => party.name.startsWith('M/s Keystone'));
    expect(keystone.gstin, '36AACCK6531F1ZP');
    expect(keystone.gstType, 'registered');

    await db.close();
  });
}
