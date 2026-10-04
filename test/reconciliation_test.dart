import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two views of "what am I owed" have to agree, or the first question a
/// customer asks ("my statement says X, your books say Y") has no answer.
///
/// `PartyRepository.outstandingFor` builds the figure from the document tables
/// *plus the party's opening balance*. The ledger builds the Sundry Debtors
/// account from posted movements *plus the account's own opening balance*.
/// Those are two different opening-balance fields, and nothing copies one to
/// the other — so a party created with an opening balance is owed money the
/// ledger's Debtors account has never heard of.

void main() {
  late AppDatabase db;
  late String firmId;
  late PartyRepository partyRepo;
  late LedgerRepository ledgerRepo;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Books Enterprise',
      stateCode: '24',
      gstin: '24AABCA1234A1Z5',
    );
    firmId = firm.id;
    partyRepo = db.partyRepositoryFor(firmId);
    ledgerRepo = db.ledgerRepositoryFor(firmId);
    await ledgerRepo.ensureChart();
  });

  tearDown(() => db.close());

  test('a party opening balance reaches the Debtors ledger account', () async {
    // A customer carried in at ₹5,000 Dr, then invoiced ₹10,000.
    final party = await partyRepo.create(
      name: 'Ramesh Stores',
      type: 'customer',
      openingBalance: 5000,
      openingBalanceType: 'dr',
    );
    final sales = db.salesRepositoryFor(firmId);
    await sales.save(SalesDraft(
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
      applyRoundOff: false,
      sequence: 0,
    ));

    final outstanding = await partyRepo.outstandingFor(party.id);
    expect(outstanding, 15000.0,
        reason: 'opening 5,000 + invoice 10,000');

    final accounts = await ledgerRepo.allAccounts();
    final debtors = accounts.firstWhere((a) => a.code == LedgerCodes.debtors);
    final ledger = await ledgerRepo.accountLedger(
      debtors.id,
      asOf: DateTime(2026, 12, 31),
    );

    // The ledger's Debtors closing has to be the same ₹15,000. If the party's
    // opening balance never reaches the account, this reads 10,000 and the
    // trial balance is out by the opening from the day the books opened.
    expect(ledger.closing, 15000.0,
        reason: 'Sundry debtors must include party opening balances; '
            'otherwise the ledger and every party statement disagree by '
            'exactly the opening balance forever.');

    // An opening that posts only one side would break the trial balance —
    // the books would foot only because two errors cancelled. The contra is
    // capital, so `₹5,000 Dr debtors / ₹5,000 Cr capital` has to leave the
    // books balanced.
    final tb = await ledgerRepo.trialBalance(asOf: DateTime(2026, 12, 31));
    expect(tb.isBalanced, isTrue,
        reason: 'a party opening balance must post both sides');
  });

  test('a supplier opening balance reaches the Creditors ledger account', () async {
    final party = await partyRepo.create(
      name: 'Wholesale Supply Co',
      type: 'supplier',
      openingBalance: 8000,
      openingBalanceType: 'cr',
    );
    final accounts = await ledgerRepo.allAccounts();
    final creditors = accounts.firstWhere((a) => a.code == LedgerCodes.creditors);
    final ledger = await ledgerRepo.accountLedger(
      creditors.id,
      asOf: DateTime(2026, 12, 31),
    );

    // A credit opening is money *we* owe, so it lands on the credit side and
    // reads as a negative outstanding from `outstandingFor`'s point of view.
    expect(ledger.closing, -8000.0,
        reason: 'a credit opening is a liability, not a negative asset');
    expect(await partyRepo.outstandingFor(party.id), -8000.0);

    final tb = await ledgerRepo.trialBalance(asOf: DateTime(2026, 12, 31));
    expect(tb.isBalanced, isTrue);
  });
}
