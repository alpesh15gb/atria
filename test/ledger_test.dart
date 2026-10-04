import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the double-entry side of the app.
///
/// The reports that existed before this were computed straight off documents,
/// which answers "how much did I sell" but cannot answer "what do I owe" and
/// has nowhere to put an entry that is not a document. Worse, a document-side
/// report can be wrong in a way nobody notices, because nothing checks that it
/// adds up. The point of every test here is the same: whatever was posted, the
/// trial balance and the balance sheet must agree to the paisa.
void main() {
  late AppDatabase db;
  late String firmId;
  late LedgerRepository ledger;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    ledger = db.ledgerRepositoryFor(firmId);
    await ledger.ensureChart();
  });

  tearDown(() => db.close());

  Future<AccountEntity> account(String code) async =>
      (await ledger.byCode(code))!;

  Future<double> closing(String code) async {
    final tb = await ledger.trialBalance(asOf: DateTime(2027, 3, 31));
    for (final row in tb.rows) {
      if (row.account.code == code) return row.closing;
    }
    return 0;
  }

  /// One intra-state invoice: 2 x 500 at 18%, so 1000 taxable + 90 + 90.
  Future<void> invoice({
    String number = 'INV-1',
    String docType = 'invoice',
    double shipping = 0,
    double tcsRate = 0,
  }) async {
    await db.salesRepositoryFor(firmId).save(SalesDraft(
      id: 'sale-$number',
      number: number,
      docType: docType,
      invoiceDate: DateTime(2026, 9, 10),
      status: 'confirmed',
      partyName: 'Ravi Stores',
      shippingCharge: shipping == 0 ? null : Decimal.parse('$shipping'),
      tcsRate: tcsRate == 0 ? null : Decimal.parse('$tcsRate'),
      lines: [
        SalesLineDraft(
          id: 'l1-$number',
          name: 'Surf Excel 1kg',
          quantity: Decimal.fromInt(2),
          unit: 'pcs',
          rate: Decimal.fromInt(500),
          gstRate: 18,
        ),
      ],
    ));
  }

  Future<PurchaseBillEntity> bill({double tdsRate = 0}) async =>
      db.purchaseRepositoryFor(firmId).save(PurchaseDraft(
        id: 'bill-1',
        number: 'BILL-1',
        docType: 'bill',
        billDate: DateTime(2026, 9, 12),
        partyName: 'Metro Distributors',
        tdsRate: tdsRate == 0 ? null : Decimal.parse('$tdsRate'),
        lines: [
          PurchaseLineDraft(
            id: 'pl1',
            name: 'Cadbury Dairy Milk',
            quantity: Decimal.fromInt(10),
            unit: 'pcs',
            rate: Decimal.fromInt(100),
            gstRate: 18,
          ),
        ],
      ));

  group('chart of accounts', () {
    test('seeds the standard chart once', () async {
      final first = await ledger.ensureChart();
      expect(first, 0, reason: 'already seeded in setUp');
      final accounts = await ledger.allAccounts();
      expect(accounts.length, greaterThanOrEqualTo(kSeedChart.length));
      expect(accounts.map((a) => a.code).toSet().length, accounts.length);
    });

    test('a new account gets the next free code in its range', () async {
      final account = await ledger.createAccount(
        name: 'HDFC Current A/c 4412',
        type: 'asset',
        groupName: 'Cash & bank',
      );
      expect(account.code, '1400');
      expect(account.type, 'asset');
    });

    test('refuses a duplicate code', () async {
      await expectLater(
        ledger.createAccount(
            name: 'Duplicate cash', type: 'asset', code: LedgerCodes.cash),
        throwsA(isA<StateError>()),
      );
    });

    test('a system account cannot be archived or deleted', () async {
      final cash = await account(LedgerCodes.cash);
      await expectLater(
        ledger.setAccountActive(cash.id, false),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        ledger.deleteAccount(cash.id),
        throwsA(isA<StateError>()),
      );
    });

    test('an account used by a voucher can be archived but not deleted',
        () async {
      final custom = await ledger.createAccount(
        name: 'Vehicle loans',
        type: 'liability',
      );
      await ledger.createJournal(
        date: DateTime(2026, 9, 1),
        narration: 'Loan taken from the bank',
        lines: [
          JournalLineDraft(accountId: (await account(LedgerCodes.bank)).id,
              debit: 250000),
          JournalLineDraft(accountId: custom.id, credit: 250000),
        ],
      );
      await expectLater(
        ledger.deleteAccount(custom.id),
        throwsA(isA<StateError>()),
      );
      await ledger.setAccountActive(custom.id, false);
      final all = await ledger.allAccounts();
      expect(all.any((a) => a.id == custom.id), isFalse);
      final withArchived = await ledger.allAccounts(includeInactive: true);
      expect(withArchived.any((a) => a.id == custom.id), isTrue);
    });
  });

  group('journal vouchers', () {
    test('an unbalanced voucher is refused, and nothing is written', () async {
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      await expectLater(
        ledger.createJournal(
          date: DateTime(2026, 9, 1),
          narration: 'Capital introduced',
          lines: [
            JournalLineDraft(accountId: cash.id, debit: 50000),
            JournalLineDraft(accountId: capital.id, credit: 49999),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(await ledger.journalCount(), 0);
    });

    test('a line cannot be a debit and a credit at once', () async {
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      await expectLater(
        ledger.createJournal(
          date: DateTime(2026, 9, 1),
          narration: 'Nonsense',
          lines: [
            JournalLineDraft(accountId: cash.id, debit: 100, credit: 100),
            JournalLineDraft(accountId: capital.id, credit: 100),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a one-line voucher is refused', () async {
      final cash = await account(LedgerCodes.cash);
      await expectLater(
        ledger.createJournal(
          date: DateTime(2026, 9, 1),
          narration: 'Half an entry',
          lines: [JournalLineDraft(accountId: cash.id, debit: 100)],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('posts to both accounts and numbers the voucher', () async {
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      final entry = await ledger.createJournal(
        date: DateTime(2026, 9, 1),
        narration: 'Capital introduced by the proprietor',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 100000),
          JournalLineDraft(accountId: capital.id, credit: 100000),
        ],
      );
      expect(entry.number, 'JV/0001');
      expect(await closing(LedgerCodes.cash), 100000);
      expect(await closing(LedgerCodes.capital), -100000);

      final second = await ledger.createJournal(
        date: DateTime(2026, 9, 2),
        narration: 'Depreciation for September',
        lines: [
          JournalLineDraft(accountId: capital.id, debit: 5000),
          JournalLineDraft(accountId: cash.id, credit: 5000),
        ],
      );
      expect(second.number, 'JV/0002');
    });

    test('a binned voucher leaves the books and can be restored', () async {
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      final entry = await ledger.createJournal(
        date: DateTime(2026, 9, 1),
        narration: 'Capital introduced',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 100000),
          JournalLineDraft(accountId: capital.id, credit: 100000),
        ],
      );
      await ledger.deleteJournal(entry.id);
      expect(await closing(LedgerCodes.cash), 0);
      expect(await ledger.journalCount(), 0);
      expect(await ledger.journalCount(includeDeleted: true), 1);

      await ledger.restoreJournal(entry.id);
      expect(await closing(LedgerCodes.cash), 100000);

      // Deleting does not renumber the next voucher: two books must never show
      // two different vouchers under the same number.
      final next = await ledger.createJournal(
        date: DateTime(2026, 9, 3),
        narration: 'Something else',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 1),
          JournalLineDraft(accountId: capital.id, credit: 1),
        ],
      );
      expect(next.number, 'JV/0002');
    });

    test('editing a voucher replaces its lines rather than adding to them',
        () async {
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      final entry = await ledger.createJournal(
        date: DateTime(2026, 9, 1),
        narration: 'Capital introduced',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 100000),
          JournalLineDraft(accountId: capital.id, credit: 100000),
        ],
      );
      await ledger.updateJournal(
        entry.id,
        date: DateTime(2026, 9, 1),
        narration: 'Capital introduced (corrected)',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 75000),
          JournalLineDraft(accountId: capital.id, credit: 75000),
        ],
      );
      expect(await closing(LedgerCodes.cash), 75000);
      final lines = await ledger.journalLinesOf(entry.id);
      expect(lines.length, 2);
      expect((await ledger.journalById(entry.id))!.narration,
          'Capital introduced (corrected)');
    });
  });

  group('posting the documents', () {
    test('an invoice credits sales and output tax and debits the customer',
        () async {
      await invoice();
      expect(await closing(LedgerCodes.sales), -1000);
      expect(await closing(LedgerCodes.outputGst), -180);
      expect(await closing(LedgerCodes.debtors), 1180);

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue, reason: 'difference ${tb.difference}');
      expect(tb.totalDebit, 1180);
      expect(tb.totalCredit, 1180);
    });

    test('shipping is revenue, not taxable value', () async {
      await invoice(shipping: 50);
      expect(await closing(LedgerCodes.sales), -1050);
      // GST is charged on the goods, not on the freight.
      expect(await closing(LedgerCodes.outputGst), -180);
      expect(await closing(LedgerCodes.debtors), 1230);
    });

    test('TCS collected becomes a liability, not income', () async {
      await invoice(tcsRate: 0.1);
      expect(await closing(LedgerCodes.sales), -1000);
      expect(await closing(LedgerCodes.tcsPayable), -1);
      expect(await closing(LedgerCodes.debtors), 1181);

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue);
    });

    test('a credit note reverses into sales returns', () async {
      await invoice();
      await invoice(number: 'CN-1', docType: 'credit_note');
      expect(await closing(LedgerCodes.sales), -1000);
      expect(await closing(LedgerCodes.salesReturns), 1000);
      expect(await closing(LedgerCodes.debtors), 0);
      expect(await closing(LedgerCodes.outputGst), 0);

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue);
    });

    test('a cancelled document is not posted', () async {
      final saved = await db.salesRepositoryFor(firmId).save(SalesDraft(
        id: 'sale-cancelled',
        number: 'INV-9',
        docType: 'invoice',
        invoiceDate: DateTime(2026, 9, 11),
        status: 'cancelled',
        lines: [
          SalesLineDraft(
            id: 'l1',
            name: 'Surf Excel 1kg',
            quantity: Decimal.fromInt(1),
            unit: 'pcs',
            rate: Decimal.fromInt(500),
            gstRate: 18,
          ),
        ],
      ));
      expect(saved.status, 'cancelled');
      expect(await closing(LedgerCodes.sales), 0);
    });

    test('a bill with TDS crediting a payable keeps the books balanced',
        () async {
      final saved = await bill(tdsRate: 2);
      // 10 x 100 = 1000 taxable, 180 GST, TDS 2% of the taxable value.
      expect(saved.tds, 20);
      expect(saved.grandTotal, 1160);
      expect(await closing(LedgerCodes.purchases), 1000);
      expect(await closing(LedgerCodes.inputGst), 180);
      expect(await closing(LedgerCodes.tdsPayable), -20);
      expect(await closing(LedgerCodes.creditors), -1160);

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue, reason: 'difference ${tb.difference}');
    });

    test('a receipt moves money from the customer to cash', () async {
      await invoice();
      await db.paymentRepositoryFor(firmId).create(
            type: 'payment_in',
            number: 'RCP-1',
            partyName: 'Ravi Stores',
            amount: 1180,
            date: DateTime(2026, 9, 20),
            mode: 'cash',
          );
      expect(await closing(LedgerCodes.cash), 1180);
      expect(await closing(LedgerCodes.debtors), 0);
    });

    test('an uncleared cheque sits in cheques in hand, then reaches the bank',
        () async {
      final payments = db.paymentRepositoryFor(firmId);
      final cheque = await payments.create(
        type: 'payment_in',
        number: 'RCP-2',
        amount: 5000,
        date: DateTime(2026, 9, 21),
        mode: 'cheque',
        reference: '004512',
      );
      expect(await closing(LedgerCodes.chequesInHand), 5000);
      expect(await closing(LedgerCodes.bank), 0);

      // The banking step is what moves the money, so the ledger follows it.
      await payments.markChequeDeposited(cheque.id);
      expect(await closing(LedgerCodes.chequesInHand), 5000);

      await payments.markChequeCleared(cheque.id, date: DateTime(2026, 9, 25));
      expect(await closing(LedgerCodes.chequesInHand), 0);
      expect(await closing(LedgerCodes.bank), 5000);
    });

    test('an expense with GST splits into a cost and input credit', () async {
      await db.expenseRepositoryFor(firmId).create(
            type: 'expense',
            number: 'EXP-1',
            category: 'rent',
            amount: 11800,
            date: DateTime(2026, 9, 5),
            mode: 'bank_transfer',
            gstAmount: 1800,
          );
      final rent = await ledger.accountForCategory('rent');
      expect(await closing(rent.code), 10000);
      expect(await closing(LedgerCodes.inputGst), 1800);
      expect(await closing(LedgerCodes.bank), -11800);

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue);
      // The GST paid on an expense is claimable, and the old GST summary never
      // saw it because it only looked at purchase bills.
      expect(
        await ledger.inputTaxFromExpenses(to: DateTime(2026, 9, 30)),
        1800,
      );
    });

    test('income other than sales credits its own account', () async {
      await db.expenseRepositoryFor(firmId).create(
            type: 'income',
            number: 'INC-1',
            category: 'commission',
            amount: 5000,
            date: DateTime(2026, 9, 6),
            mode: 'cash',
          );
      final commission = await ledger.accountForCategory('commission');
      expect(await closing(commission.code), -5000);
      expect(await closing(LedgerCodes.cash), 5000);
    });

    test('quotations and orders are not transactions', () async {
      await db.salesRepositoryFor(firmId).save(SalesDraft(
        id: 'quote-1',
        number: 'QTN-1',
        docType: 'quotation',
        invoiceDate: DateTime(2026, 9, 7),
        status: 'confirmed',
        lines: [
          SalesLineDraft(
            id: 'l1',
            name: 'Surf Excel 1kg',
            quantity: Decimal.fromInt(1),
            unit: 'pcs',
            rate: Decimal.fromInt(999),
            gstRate: 18,
          ),
        ],
      ));
      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.rows, isEmpty);
    });
  });

  group('reports', () {
    test('period slicing carries earlier movements into the opening balance',
        () async {
      await invoice();
      final tb = await ledger.trialBalance(
        asOf: DateTime(2026, 9, 30),
        from: DateTime(2026, 9, 15),
      );
      final sales = tb.rows.firstWhere((r) => r.account.code == LedgerCodes.sales);
      expect(sales.opening, -1000);
      expect(sales.credit, 0);
      expect(sales.closing, -1000);
      expect(tb.isBalanced, isTrue);
    });

    test('the balance sheet balances and carries the profit into equity',
        () async {
      await invoice();
      await bill();
      final sheet = await ledger.balanceSheet(asOf: DateTime(2026, 9, 30));

      // Sales 1000 credit, purchases 1000 debit: no profit yet, and the GST
      // leaves 180 payable to the government.
      expect(sheet.netProfit, 0);
      expect(sheet.totalAssets,
          closeTo(1180 + 180, 0.01)); // debtors + input credit
      expect(sheet.totalLiabilities,
          closeTo(1180 + 180, 0.01)); // creditors + output tax
      expect(sheet.isBalanced, isTrue,
          reason: 'difference ${sheet.difference}');
    });

    test('profit appears on the balance sheet without a year-end close',
        () async {
      await invoice(shipping: 250);
      // Sales 1250, output tax 180, debtors 1430: profit 1250.
      final sheet = await ledger.balanceSheet(asOf: DateTime(2026, 9, 30));
      expect(sheet.netProfit, closeTo(1250, 0.01));
      expect(sheet.isBalanced, isTrue);
      expect(sheet.totalEquity, closeTo(1250, 0.01));
    });

    test('a loss reduces equity rather than breaking the sheet', () async {
      await bill();
      final sheet = await ledger.balanceSheet(asOf: DateTime(2026, 9, 30));
      expect(sheet.netProfit, closeTo(-1000, 0.01));
      expect(sheet.isBalanced, isTrue);
    });

    test('owner drawings subtract from equity and keep the balance sheet in balance',
        () async {
      await ledger.ensureChart();
      final capital = await account(LedgerCodes.capital);
      final drawings = await account(LedgerCodes.drawings);
      final cash = await account(LedgerCodes.cash);

      // Capital injection ₹100,000 (Dr Cash, Cr Capital)
      await ledger.createJournal(
        narration: 'Capital introduced',
        date: DateTime(2026, 9, 1),
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 100000),
          JournalLineDraft(accountId: capital.id, credit: 100000),
        ],
      );

      // Drawings ₹20,000 (Dr Drawings, Cr Cash)
      await ledger.createJournal(
        narration: 'Drawings by owner',
        date: DateTime(2026, 9, 15),
        lines: [
          JournalLineDraft(accountId: drawings.id, debit: 20000),
          JournalLineDraft(accountId: cash.id, credit: 20000),
        ],
      );

      final sheet = await ledger.balanceSheet(asOf: DateTime(2026, 9, 30));
      // Assets: Cash 80,000
      expect(sheet.totalAssets, closeTo(80000, 0.01));
      // Equity: Capital 100,000 - Drawings 20,000 = 80,000
      expect(sheet.totalEquity, closeTo(80000, 0.01));
      expect(sheet.isBalanced, isTrue, reason: 'diff: ${sheet.difference}');
    });

    test('an account ledger shows a running balance from its opening',
        () async {
      await invoice();
      await db.paymentRepositoryFor(firmId).create(
            type: 'payment_in',
            number: 'RCP-3',
            amount: 400,
            date: DateTime(2026, 9, 20),
            mode: 'cash',
          );
      final debtors = await account(LedgerCodes.debtors);
      final ledgerReport = await ledger.accountLedger(
        debtors.id,
        asOf: DateTime(2026, 9, 30),
      );
      expect(ledgerReport.opening, 0);
      expect(ledgerReport.rows.length, 2);
      expect(ledgerReport.rows.first.debit, 1180);
      expect(ledgerReport.rows.last.credit, 400);
      expect(ledgerReport.closing, 780);
      expect(ledgerReport.totalDebit, 1180);
      expect(ledgerReport.totalCredit, 400);
      // The Balance column is a *running* balance. The row that receives 400
      // has to show the balance after it (780), not 400 — a column of
      // per-row figures disagrees with the closing balance printed under it,
      // which is the first thing an accountant checks a ledger for.
      expect(ledgerReport.rows.first.balance, 1180);
      expect(ledgerReport.rows.last.balance, 780);
      expect(ledgerReport.rows.last.balance, ledgerReport.closing);
    });

    test('an account ledger carries in everything before the period', () async {
      await invoice();
      final debtors = await account(LedgerCodes.debtors);
      final report = await ledger.accountLedger(
        debtors.id,
        from: DateTime(2026, 9, 15),
        asOf: DateTime(2026, 9, 30),
      );
      expect(report.opening, 1180);
      expect(report.rows, isEmpty);
      expect(report.closing, 1180);
    });

    test('a manual voucher and the documents agree in one trial balance',
        () async {
      await invoice();
      final cash = await account(LedgerCodes.cash);
      final capital = await account(LedgerCodes.capital);
      await ledger.createJournal(
        date: DateTime(2026, 9, 2),
        narration: 'Capital introduced',
        lines: [
          JournalLineDraft(accountId: cash.id, debit: 50000),
          JournalLineDraft(accountId: capital.id, credit: 50000),
        ],
      );
      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(tb.isBalanced, isTrue);
      expect(tb.totalClosingDebit, closeTo(51180, 0.01));
      expect(await closing(LedgerCodes.cash), 50000);
    });
  });
}
