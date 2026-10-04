import 'dart:io';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/vyapar_backup.dart';
import 'package:atria/core/services/vyapar_import.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Swipe book pulled out of the **web app** — no API key, just the session
/// token that is already in the user's browser — has to land in Atria exactly
/// the way a Partner-API export does, because both write the same `.vyb` and go
/// through the same reader and importer.
///
/// The fixture is generated from `tools/sample_swipe_web_cache/` (canned
/// Swipe web-API responses, shaped from the live endpoints) with:
///
///     python tools/swipe_web_to_vyb.py \
///       --from-json tools/sample_swipe_web_cache \
///       --from 01-04-2026 --to 31-03-2027 --docs invoice,purchase \
///       --out test/fixtures/swipe_web_sample.vyb \
///       --firm-name "Active IT Solutions" --firm-gstin 36CZFPM0045M2Z7
///
/// It holds two invoices (one settled by a standalone Net Banking receipt, one
/// paid on the document with UPI), a supplier bill part-paid in cash, two
/// expenses written as Vyapar journal entries, three catalog items, and a
/// cancelled invoice that must be skipped.
///
/// Two things are being pinned down here at once: that the web-API shapes are
/// mapped onto the `.vyb` correctly, and that Vyapar's journal-entry expenses
/// are read back out as Atria expenses instead of silently disappearing.
void main() {
  const fixture = 'test/fixtures/swipe_web_sample.vyb';

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
    // Two payment transactions plus the UPI receipt recorded on INV-2026-002.
    expect(preview.counts.payments, 3);
    // Both expenses are decodable journal entries, so the dry run counts them.
    expect(preview.counts.expenses, 2);

    final result = await service.run(bytes);
    return (db, result, snapshot);
  }

  test('a Swipe web export imports as a full set of books', () async {
    final (db, result, _) = await importFixture();

    expect(result.counts.saleInvoices, 2);
    expect(result.counts.purchaseBills, 1);
    expect(result.counts.payments, 3);
    expect(result.counts.parties, 3);
    expect(result.counts.items, 3);
    expect(result.counts.expenses, 2);

    final firm = await db.firmRepository.getById(result.firmId);
    expect(firm!.name, 'Active IT Solutions');
    expect(firm.gstin, '36CZFPM0045M2Z7');
    expect(firm.stateCode, '36');

    await db.close();
  });

  test('invoices keep their lines, GST and Swipe numbers', () async {
    final (db, result, _) = await importFixture();
    final sales = db.salesRepositoryFor(result.firmId);
    final invoices = await sales.list(docType: 'invoice');

    expect(invoices.map((invoice) => invoice.number), containsAll(<String>[
      'INV-2026-001',
      'INV-2026-002',
    ]));
    // The cancelled invoice is not a sale, so it is nowhere in the books.
    expect(invoices, hasLength(2));

    final first =
        invoices.firstWhere((invoice) => invoice.number == 'INV-2026-001');
    // 2 x ₹1,000 at 18%: a Telangana firm billing a Telangana customer.
    expect(first.grandTotal, 2360);
    expect(first.cgst, 180);
    expect(first.sgst, 180);
    expect(first.igst, 0);
    expect(first.isInterState, isFalse);
    expect(first.placeOfSupply, '36');

    final lines = await sales.itemsFor(first.id);
    expect(lines, hasLength(1));
    expect(lines.single.name, 'Canon NPG90 Toner');
    expect(lines.single.quantity.toDouble(), 2);
    // `price` is the taxable rate even though Swipe also sends one with tax in.
    expect(lines.single.rate.toDouble(), 1000);
    expect(lines.single.hsn, '84439959');

    await db.close();
  });

  test('payments in and out link back to the document they settle', () async {
    final (db, result, _) = await importFixture();
    final payments = await db.paymentRepositoryFor(result.firmId).list(limit: 50);

    expect(payments, hasLength(3));
    final incoming = payments.firstWhere(
      (payment) => payment.type == 'payment_in' && payment.amount == 2360,
    );
    expect(incoming.partyName, 'Keystone Infra Pvt Ltd');
    expect(incoming.mode, 'bank_transfer');

    final outgoing =
        payments.firstWhere((payment) => payment.type == 'payment_out');
    expect(outgoing.amount, 5000);
    expect(outgoing.mode, 'cash');

    // The UPI receipt came from the document's own payment modes.
    final upi = payments.firstWhere((payment) => payment.amount == 1180);
    expect(upi.type, 'payment_in');
    expect(upi.mode, 'upi');

    // Neither figure may be counted twice: the standalone receipt settled
    // INV-2026-001 in full, and the cash payment left ₹4,440 on the bill.
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

    final keystone =
        parties.firstWhere((party) => party.name == 'Keystone Infra Pvt Ltd');
    expect(keystone.type, 'customer');
    expect(keystone.gstin, '36AACCK6531F1ZP');
    expect(keystone.gstType, 'registered');

    expect(
      parties
          .firstWhere(
              (party) => party.name == 'I-HEAP ELECTRONICS PVT LTD')
          .type,
      'supplier',
    );

    await db.close();
  });

  test('expenses come back as expenses, not as purchases or journal noise',
      () async {
    final (db, result, _) = await importFixture();
    final expenses = await db.expenseRepositoryFor(result.firmId).list();

    expect(expenses, hasLength(2));
    expect(expenses.every((expense) => expense.type == 'expense'), isTrue);

    final rent = expenses.firstWhere((expense) => expense.category == 'Rent');
    expect(rent.amount, 15000);
    expect(rent.mode, 'cash');
    // The vendor rides along in the journal entry's description.
    expect(rent.notes, contains('Srinivas Rao'));

    final internet =
        expenses.firstWhere((expense) => expense.category == 'Internet');
    expect(internet.amount, 1180);
    expect(internet.mode, 'bank_transfer');
    // The list row carried no category, so this one came from the detail call.
    expect(internet.notes, contains('Airtel'));

    // Expenses are money out, so they must not have become purchases.
    final bills =
        await db.purchaseRepositoryFor(result.firmId).list(docType: 'bill');
    expect(bills, hasLength(1));

    await db.close();
  });

  test('Swipe expense categories are available to post against', () async {
    final (db, result, _) = await importFixture();
    final expenseCategories = (await db
            .itemRepositoryFor(result.firmId)
            .categories(kind: 'expense'))
        .map((category) => category.name)
        .toSet();
    expect(expenseCategories, containsAll(<String>['Rent', 'Internet']));
    // Swipe's "indirect income" heads are not expenses and are left out.
    expect(expenseCategories, isNot(contains('Dividend')));

    await db.close();
  });
}
