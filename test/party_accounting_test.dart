import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late String firmId;
  late PartyRepository partyRepo;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Books Enterprise',
      stateCode: '24',
      gstin: '24AABCA1234A1Z5',
    );
    firmId = firm.id;
    partyRepo = db.partyRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  test('PartyRepository.outstandingFor includes credit notes and unlinked payments',
      () async {
    // 1. Create a customer with ₹5,000 opening balance (Dr)
    final party = await partyRepo.create(
      name: 'Ramesh Stores',
      type: 'customer',
      openingBalance: 5000,
      openingBalanceType: 'dr',
    );

    // Initial outstanding should equal opening balance ₹5,000
    expect(await partyRepo.outstandingFor(party.id), 5000.0);

    // 2. Customer pays ₹5,000 via unlinked payment (e.g. clearing opening balance)
    await db.paymentRepositoryFor(firmId).create(
          type: 'payment_in',
          number: 'PAY-OPENING',
          partyId: party.id,
          partyName: party.name,
          amount: 5000,
          date: DateTime(2026, 4, 2),
        );

    // Outstanding should now be ₹0!
    expect(await partyRepo.outstandingFor(party.id), 0.0);

    // 3. Issue sales invoice for ₹10,000
    final sales = db.salesRepositoryFor(firmId);
    final inv = await sales.save(SalesDraft(
      id: 'inv-1',
      number: 'INV-001',
      docType: 'invoice',
      partyId: party.id,
      partyName: party.name,
      invoiceDate: DateTime(2026, 4, 10),
      lines: [
        SalesLineDraft(
          id: 'sl-1',
          name: 'Goods',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('10000'),
          gstRate: 0,
        ),
      ],
    ));

    // Outstanding should now be ₹10,000
    expect(await partyRepo.outstandingFor(party.id), 10000.0);

    // 4. Issue a credit note for ₹2,000 (goods returned)
    await sales.save(SalesDraft(
      id: 'cn-1',
      number: 'CN-001',
      docType: 'credit_note',
      partyId: party.id,
      partyName: party.name,
      invoiceDate: DateTime(2026, 4, 15),
      lines: [
        SalesLineDraft(
          id: 'cnl-1',
          name: 'Goods Returned',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('2000'),
          gstRate: 0,
        ),
      ],
    ));

    // Outstanding should now be ₹8,000 (10,000 invoice - 2,000 credit note)
    expect(await partyRepo.outstandingFor(party.id), 8000.0);

    // 5. Pay ₹3,000 linked to the invoice
    await db.paymentRepositoryFor(firmId).create(
          type: 'payment_in',
          number: 'PAY-INV',
          partyId: party.id,
          partyName: party.name,
          amount: 3000,
          date: DateTime(2026, 4, 20),
          linkedInvoiceId: inv.id,
          onLinked: (id, amt) => sales.applyPayment(invoiceId: id, amount: amt),
        );

    // Outstanding should now be ₹5,000 (8,000 - 3,000)
    expect(await partyRepo.outstandingFor(party.id), 5000.0);

    // 6. Record a cheque payment of ₹2,000 that bounces
    final bouncedPay = await db.paymentRepositoryFor(firmId).create(
          type: 'payment_in',
          number: 'CHQ-BOUNCE',
          partyId: party.id,
          partyName: party.name,
          amount: 2000,
          date: DateTime(2026, 4, 22),
          mode: 'cheque',
        );
    await db.paymentRepositoryFor(firmId).markChequeBounced(
          bouncedPay.id,
          reason: 'Insufficient funds',
          date: DateTime(2026, 4, 25),
        );

    // Bounced cheque must NOT reduce outstanding; should still be ₹5,000
    expect(await partyRepo.outstandingFor(party.id), 5000.0);
  });

  test('ReportRepository.partyStatement includes credit/debit notes and ignores bounced cheques',
      () async {
    final party = await partyRepo.create(
      name: 'Surat Traders',
      type: 'customer',
      openingBalance: 1000,
      openingBalanceType: 'dr',
    );

    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
      id: 'inv-surat',
      number: 'INV-10',
      docType: 'invoice',
      partyId: party.id,
      partyName: party.name,
      invoiceDate: DateTime(2026, 5, 2),
      lines: [
        SalesLineDraft(
          id: 'sl-surat',
          name: 'Fabric',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('5000'),
          gstRate: 0,
        ),
      ],
    ));

    await sales.save(SalesDraft(
      id: 'cn-surat',
      number: 'CN-10',
      docType: 'credit_note',
      partyId: party.id,
      partyName: party.name,
      invoiceDate: DateTime(2026, 5, 10),
      lines: [
        SalesLineDraft(
          id: 'cnl-surat',
          name: 'Fabric Return',
          quantity: Decimal.one,
          unit: 'pcs',
          rate: Decimal.parse('1500'),
          gstRate: 0,
        ),
      ],
    ));

    // Bounced payment
    final bouncedPay = await db.paymentRepositoryFor(firmId).create(
          type: 'payment_in',
          number: 'CHQ-55',
          partyId: party.id,
          partyName: party.name,
          amount: 2000,
          date: DateTime(2026, 5, 12),
          mode: 'cheque',
        );
    await db.paymentRepositoryFor(firmId).markChequeBounced(
          bouncedPay.id,
          reason: 'Signature mismatch',
          date: DateTime(2026, 5, 14),
        );

    final statement = await db.reportRepositoryFor(firmId).partyStatement(
      partyId: party.id,
      from: DateTime(2026, 5, 1),
      to: DateTime(2026, 5, 31, 23, 59, 59),
    );

    // Opening 1000 + Invoice 5000 - Credit Note 1500 = Closing 4500
    expect(statement.closing, Decimal.parse('4500.00'));
    // Lines should contain Opening Balance, Invoice, Credit Note (and NOT the bounced cheque)
    final descriptions = statement.lines.map((l) => l.particulars).toList();
    expect(descriptions, contains(contains('Credit Note CN-10')));
    expect(descriptions, isNot(contains(contains('CHQ-55'))));
  });
}
