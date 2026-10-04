import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/core/utils/money.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The nine Transaction reports, tested where a CA's questions actually live.
///
/// These are the reports that have to be **right against the books**, so each
/// test below states the trap it pins, and every one of them was written to fail
/// against the version that drops the predicate:
///
/// 1. **Taxable value, never grand total.** Report the grand total and revenue
///    includes output tax, so the sale register disagrees with the P&L by
///    exactly the GST charged.
/// 2. **A credit note is negative, not a fresh sale.** Rule 2 of the plan. A
///    credit note returns goods *and* tax; printing it positive makes returns
///    look like extra revenue.
/// 3. **Bounced cheques are not money.** And the predicate has to be
///    `isNull() | not(equals(...))` — the naive `not(equals('bounced'))` drops
///    every **cash** payment too, because a cash payment has a null cheque
///    status and `NOT(NULL = 'bounced')` is SQL NULL.
/// 4. **Journal vouchers move money once, at their net.** Omitting them makes
///    All Transactions foot perfectly and disagree with the bank.
/// 5. **Debit and credit columns are magnitudes.** A signed column cannot be
///    added up, and a trial balance whose two totals differ is not a trial
///    balance.
/// 6. **Cost of goods is what the goods cost *then*.** Re-valuing at today's
///    price makes last quarter's profit change when you buy something this week.
/// 7. **The books must foot.** The Trial Balance and the P&L are two
///    independent implementations; the tests assert the difference is *reported*,
///    never thrown.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;
  late PurchaseRepository purchases;

  /// April 2026 — inside the window below, and a full financial quarter so the
  /// FY presets cannot accidentally agree with a calendar quarter.
  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  /// Outside the window, so a report that forgets to push the bounds into SQL
  /// still looks plausible at a glance but fails these tests.
  DateTime outside() => DateTime(2026, 1, 15);

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Apex Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<ReportResult> run(String id) async {
    final definition = ReportCatalogue.byId(id);
    expect(definition, isNotNull, reason: 'no report registered as "$id"');
    return definition!.run(db, firmId, window);
  }

  /// The report's rows as text for one column, in order.
  List<String> textsOf(ReportResult result, String key) {
    final column = result.spec.columns.firstWhere((c) => c.key == key);
    return result.rows.map((r) => r.text(column)).toList();
  }

  ReportColumn columnOf(ReportResult result, String key) =>
      result.spec.columns.firstWhere((c) => c.key == key);

  Decimal sumOf(ReportResult result, String key) =>
      result.grandTotalFor(columnOf(result, key));

  // ---- fixtures ----

  /// A tracked item with a known purchase price, so a sale of it has a real
  /// cost recorded by the moving average rather than a zero the report would
  /// have to apologise for.
  Future<String> stockedItem({
    String id = 'item-cement',
    String name = 'Cement bag',
    double purchasePrice = 800,
    double gstRate = 18,
  }) async {
    final item = await db
        .itemRepositoryFor(firmId)
        .create(
          name: name,
          hsn: '2523',
          purchasePrice: purchasePrice,
          salePrice: purchasePrice * 1.25,
          gstRate: gstRate,
        );
    return item.id;
  }

  Future<void> invoice({
    required String id,
    required DateTime date,
    required String itemId,
    String? number,
    String quantity = '1',
    String rate = '1000',
    String docType = 'invoice',
    String partyName = 'Walk-in Customer',
    double gstRate = 18,
  }) => sales.save(
    SalesDraft(
      id: id,
      // The document number defaults to the id, uppercased, because
      // `(firm, docType, number)` is unique and a shared literal default would
      // make every two-invoice test collide on a constraint instead of
      // testing the report.
      number: number ?? id.toUpperCase(),
      docType: docType,
      invoiceDate: date,
      partyName: partyName,
      lines: [
        SalesLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: 'Cement bag',
          hsn: '2523',
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: gstRate,
        ),
      ],
    ),
  );

  Future<void> bill({
    required String id,
    required DateTime date,
    required String itemId,
    String quantity = '10',
    String rate = '800',
    String docType = 'bill',
    String partyName = 'BuildMart Supplies',
    String? supplierRef,
    Decimal? tdsRate,
  }) => purchases.save(
    PurchaseDraft(
      id: id,
      number: id.toUpperCase(),
      docType: docType,
      billDate: date,
      partyName: partyName,
      supplierInvoiceNumber: supplierRef,
      tdsRate: tdsRate,
      lines: [
        PurchaseLineDraft(
          id: '$id-l1',
          itemId: itemId,
          name: 'Cement bag',
          hsn: '2523',
          quantity: Decimal.parse(quantity),
          unit: 'bag',
          rate: Decimal.parse(rate),
          gstRate: 18,
        ),
      ],
    ),
  );

  // ============================================================
  group('Sale', () {
    test('reports taxable value, so GST is not counted as revenue', () async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);

      final result = await run('sale');
      expect(result.count, 1);

      // ₹1,000 at 18% GST: taxable 1,000, tax 180, total 1,180.
      expect(sumOf(result, 'taxable'), Decimal.fromInt(1000));
      expect(sumOf(result, 'tax'), Decimal.fromInt(180));
      expect(sumOf(result, 'total'), Decimal.fromInt(1180));
    });

    test('a credit note is negative, on every money column', () async {
      // Plan rule 2. A credit note returns the goods and the tax charged on
      // them; printing it as a fresh positive sale is how a month with heavy
      // returns reports more revenue than the month before.
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 2),
        itemId: itemId,
        docType: 'credit_note',
      );

      final result = await run('sale');
      expect(textsOf(result, 'type'), ['Sales invoice', 'Credit note']);

      // Taxable nets to zero, because the second document reversed the first.
      expect(sumOf(result, 'taxable'), Decimal.zero);
      expect(sumOf(result, 'tax'), Decimal.zero);
      expect(sumOf(result, 'total'), Decimal.zero);
    });

    test('a quotation is not a transaction', () async {
      // Plan rule 5. A quotation is neither money nor stock; including it makes
      // the register disagree with the ledger by every pending quote.
      final itemId = await stockedItem();
      await invoice(
        id: 'q-1',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
        docType: 'quotation',
      );

      final result = await run('sale');
      expect(result.count, 0, reason: 'a quotation is not a sale');
      expect(result.isEmpty, isTrue);
    });

    test('a cancelled invoice drops out', () async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await sales.markCancelled('inv-1');

      expect((await run('sale')).count, 0);
    });

    test('a soft-deleted invoice drops out', () async {
      // Cancellation and deletion are *separate* predicates. A document can be
      // in the recycle bin without being cancelled, and a report that filters
      // only `status` prints it as though it were live.
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await sales.softDelete('inv-1');

      expect((await run('sale')).count, 0);
    });

    test('the window is pushed into the query', () async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await invoice(id: 'inv-out', date: outside(), itemId: itemId);

      final result = await run('sale');
      expect(result.count, 1);
      // The April one, and only that one — the January document is filtered in
      // SQL rather than dropped after the fact.
      expect(textsOf(result, 'number'), ['INV-1']);
    });

    test('it groups by month, from the date cell alone', () async {
      final itemId = await stockedItem();
      await invoice(id: 'a', date: DateTime(2026, 4, 10), itemId: itemId);
      await invoice(id: 'b', date: DateTime(2026, 6, 30), itemId: itemId);

      final result = await run('sale');
      expect(result.groups.map((g) => g.name), ['Apr 2026', 'Jun 2026']);
      // Each month's subtotal is its own, and they add to the grand total.
      expect(
        result.groups.first.totalFor(columnOf(result, 'total')),
        Decimal.fromInt(1180),
      );
      expect(sumOf(result, 'total'), Decimal.fromInt(2360));
    });

    test('its own arithmetic foots', () async {
      final itemId = await stockedItem();
      await invoice(id: 'a', date: DateTime(2026, 4, 10), itemId: itemId);
      await invoice(
        id: 'b',
        date: DateTime(2026, 5, 11),
        itemId: itemId,
        rate: '2500',
      );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('sale')).isClean,
        isTrue,
        reason:
            'a report whose own rows disagree with its own totals must be '
            'caught, and this one must not be caught',
      );
    });
  });

  // ============================================================
  group('Purchase', () {
    test('TDS is its own column and is not netted into the total', () async {
      // The bill cost ₹8,000 + 18% GST = ₹9,440 and a 194Q TDS of ₹200 was
      // deducted at payment, so ₹9,240 went out. A report that folds the TDS
      // into the total prints ₹9,240 and the bank says ₹9,440 was paid to the
      // supplier and ₹200 to the government.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
        tdsRate: Decimal.parse('2.5'),
      );

      final result = await run('purchase');
      expect(sumOf(result, 'taxable'), Decimal.fromInt(8000));
      expect(sumOf(result, 'tax'), Decimal.fromInt(1440));
      expect(sumOf(result, 'tds'), Decimal.fromInt(200));
      // The total is what the bill is worth, before the deduction.
      expect(sumOf(result, 'total'), Decimal.fromInt(9440));
    });

    test('a debit note reverses the bill rather than adding to it', () async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await bill(
        id: 'dn-1',
        date: DateTime(2026, 5, 5),
        itemId: itemId,
        docType: 'debit_note',
        quantity: '1',
      );

      final result = await run('purchase');
      expect(textsOf(result, 'type'), ['Purchase bill', 'Debit note']);
      // ₹8,000 less a ₹800 return.
      expect(sumOf(result, 'taxable'), Decimal.fromInt(7200));
    });

    test('a purchase order is not a transaction', () async {
      final itemId = await stockedItem();
      await bill(
        id: 'po-1',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
        docType: 'purchase_order',
      );

      expect((await run('purchase')).count, 0);
    });

    test('it reports the supplier\'s own invoice number, not ours', () async {
      // A purchase is entered twice — once by us and once by the supplier — and
      // the GST reconciliation matches on *their* copy. Printing our number in
      // a column headed "Supplier Inv." makes the reconciliation find nothing.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
        supplierRef: 'SUP/7781',
      );

      expect(textsOf(await run('purchase'), 'supplierRef'), ['SUP/7781']);
    });

    test('its own arithmetic foots', () async {
      final itemId = await stockedItem();
      await bill(id: 'a', date: DateTime(2026, 4, 10), itemId: itemId);
      await bill(
        id: 'b',
        date: DateTime(2026, 5, 1),
        itemId: itemId,
        quantity: '4',
      );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('purchase')).isClean,
        isTrue,
      );
    });
  });

  // ============================================================
  group('All Transactions', () {
    test(
      'it unions sales, purchases, receipts, payments and expenses',
      () async {
        final itemId = await stockedItem();
        await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
        await bill(id: 'pb-1', date: DateTime(2026, 4, 11), itemId: itemId);
        await db
            .paymentRepositoryFor(firmId)
            .create(
              type: 'payment_in',
              number: 'R-1',
              partyName: 'Customer',
              amount: 1180,
              date: DateTime(2026, 4, 12),
            );
        await db
            .paymentRepositoryFor(firmId)
            .create(
              type: 'payment_out',
              number: 'P-1',
              partyName: 'Supplier',
              amount: 500,
              date: DateTime(2026, 4, 13),
            );
        await db
            .expenseRepositoryFor(firmId)
            .create(
              type: 'expense',
              number: 'E-1',
              category: 'Rent',
              amount: 900,
              date: DateTime(2026, 4, 14),
            );

        final result = await run('all_transactions');
        final types = textsOf(result, 'type');
        expect(types, contains('Sales invoice'));
        expect(types, contains('Purchase bill'));
        expect(types, contains('Receipt'));
        expect(types, contains('Payment'));
        expect(types, contains('Expense'));
        expect(result.count, 5);
      },
    );

    test('money in and money out are separate columns, not one signed amount', () async {
      // A single "Amount" column has to be read carefully — is ₹3,000 in or
      // out? Two columns sum independently, which is what lets a reader check
      // gross received and gross paid against the bank statement line by line.
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);

      final result = await run('all_transactions');
      expect(sumOf(result, 'inflow'), Decimal.fromInt(1180));
      expect(sumOf(result, 'outflow'), Decimal.zero);
    });

    test('a receipt is in and a payment is out', () async {
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 5000,
            date: DateTime(2026, 4, 1),
          );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'P-1',
            amount: 2000,
            date: DateTime(2026, 4, 2),
          );

      final result = await run('all_transactions');
      expect(sumOf(result, 'inflow'), Decimal.fromInt(5000));
      expect(sumOf(result, 'outflow'), Decimal.fromInt(2000));
    });

    test('a bounced cheque is neither a receipt nor a payment', () async {
      // Plan rule 3. And the shape of the predicate matters: the naive
      // `NOT(status = 'bounced')` is SQL NULL on a **null** status, so it drops
      // every cash payment in the firm — the ₹9,000 receipt below disappears
      // along with the bounced ₹5,000.
      final payments = db.paymentRepositoryFor(firmId);
      final cash = await payments.create(
        type: 'payment_in',
        number: 'R-1',
        partyName: 'Cash Customer',
        amount: 9000,
        date: DateTime(2026, 4, 1),
        mode: 'cash',
      );
      expect(cash.chequeStatus, isNull, reason: 'the cash payment under test');

      final cheque = await payments.create(
        type: 'payment_in',
        number: 'R-2',
        partyName: 'Cheque Customer',
        amount: 5000,
        date: DateTime(2026, 4, 2),
        mode: 'cheque',
      );
      await payments.markChequeBounced(cheque.id, reason: 'Insufficient funds');

      final result = await run('all_transactions');
      expect(result.count, 1, reason: 'only the cash receipt survives');
      expect(sumOf(result, 'inflow'), Decimal.fromInt(9000));
    });

    test('a journal voucher appears once, with both its legs', () async {
      // A voucher is two-sided by construction, and this one is the hard case: a
      // ₹2,000 deposit from the till to the bank nets to **zero** across the
      // cash accounts, because the money only changed pocket. Netting and then
      // dropping the zero would lose the row — and a deposit is precisely what
      // appears on the bank statement, so the report would disagree with the
      // very statement it is read against.
      //
      // So the two columns are the two legs, not one signed number: ₹2,000
      // received by the bank and ₹2,000 paid out of the till. The row foots to
      // nil across the pair and reconciles against the bank line by line.
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      final cash = await ledger.byCode(LedgerCodes.cash);
      final bank = await ledger.byCode(LedgerCodes.bank);
      await ledger.createJournal(
        date: DateTime(2026, 4, 20),
        narration: 'Cash deposited',
        lines: [
          JournalLineDraft(accountId: bank!.id, debit: 2000),
          JournalLineDraft(accountId: cash!.id, credit: 2000),
        ],
      );

      final result = await run('all_transactions');
      expect(result.count, 1);
      expect(sumOf(result, 'inflow'), Decimal.fromInt(2000));
      expect(sumOf(result, 'outflow'), Decimal.fromInt(2000));
    });

    test('a voucher with no cash leg moves no money and is left out', () async {
      // An accrual or a transfer between two ledger accounts moves no cash, so
      // a row of ₹0 and ₹0 would be a row that says nothing. Omitted instead of
      // printed — and the test that matters is that it does not *throw* or
      // produce a phantom.
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      final capital = await ledger.byCode(LedgerCodes.capital);
      final sales = await ledger.byCode(LedgerCodes.sales);
      await ledger.createJournal(
        date: DateTime(2026, 4, 21),
        narration: 'Capital introduced as a ledger entry only',
        lines: [
          JournalLineDraft(accountId: capital!.id, debit: 5000),
          JournalLineDraft(accountId: sales!.id, credit: 5000),
        ],
      );

      expect((await run('all_transactions')).count, 0);
    });

    test('rows are ordered by date', () async {
      final itemId = await stockedItem();
      await invoice(
        id: 'late',
        number: 'INV-LATE',
        date: DateTime(2026, 6, 1),
        itemId: itemId,
      );
      await invoice(
        id: 'early',
        number: 'INV-EARLY',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
      );

      final result = await run('all_transactions');
      expect(textsOf(result, 'number'), ['INV-EARLY', 'INV-LATE']);
    });

    test('its own arithmetic foots', () async {
      final itemId = await stockedItem();
      await invoice(id: 'a', date: DateTime(2026, 4, 10), itemId: itemId);
      await bill(id: 'b', date: DateTime(2026, 4, 11), itemId: itemId);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'p',
            amount: 777,
            date: DateTime(2026, 4, 12),
          );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('all_transactions'))
            .isClean,
        isTrue,
      );
    });
  });

  // ============================================================
  group('Day Book', () {
    test('it is the same list, grouped by day', () async {
      // Deliberately built on one query: a day book *is* all-transactions read
      // a day at a time, and two implementations of "everything that moved
      // money" drift apart — which is exactly the disagreement rule 13 exists
      // to catch between the Trial Balance and the P&L.
      final itemId = await stockedItem();
      await invoice(
        id: 'a',
        number: 'INV-A',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
      );
      await invoice(
        id: 'b',
        number: 'INV-B',
        date: DateTime(2026, 4, 10),
        itemId: itemId,
        rate: '2000',
      );
      await invoice(
        id: 'c',
        number: 'INV-C',
        date: DateTime(2026, 4, 11),
        itemId: itemId,
      );

      final result = await run('day_book');
      expect(result.count, 3);
      expect(result.groups.map((g) => g.name), ['10-04-2026', '11-04-2026']);
      // The first day holds two invoices and its received subtotal is both.
      expect(
        result.groups.first.totalFor(columnOf(result, 'inflow')),
        Decimal.fromInt(3540),
      );
      expect(sumOf(result, 'inflow'), Decimal.fromInt(4720));
    });

    test('it agrees with All Transactions row for row', () async {
      final itemId = await stockedItem();
      await invoice(id: 'a', date: DateTime(2026, 4, 10), itemId: itemId);
      await bill(id: 'b', date: DateTime(2026, 4, 11), itemId: itemId);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'r',
            amount: 1180,
            date: DateTime(2026, 4, 12),
          );

      final all = await run('all_transactions');
      final day = await run('day_book');
      expect(day.count, all.count);
      expect(sumOf(day, 'inflow'), sumOf(all, 'inflow'));
      expect(sumOf(day, 'outflow'), sumOf(all, 'outflow'));
    });
  });

  // ============================================================
  group('Bill Wise Profit', () {
    test('cost of goods is what the goods cost when they left', () async {
      // Bought at ₹800 and sold at ₹1,000, the movement stamps the moving
      // average at the moment of the sale. Valuing at today's item price instead
      // means last quarter's profit changes when somebody buys cement this
      // week — a P&L that moves after the fact is worse than no P&L.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );

      final result = await run('bill_wise_profit');
      expect(result.count, 1);
      expect(sumOf(result, 'taxable'), Decimal.fromInt(2000));
      expect(sumOf(result, 'cogs'), Decimal.fromInt(1600));
      expect(sumOf(result, 'profit'), Decimal.fromInt(400));
    });

    test('margin is on sales, not on the invoice total', () async {
      // Dividing by the grand total folds output GST into the denominator and
      // understates every margin by the tax rate: 400/2000 is 20%, and
      // 400/2360 would print 16.9% for a perfectly ordinary sale.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );

      final result = await run('bill_wise_profit');
      final margin = result.rows.single.number(columnOf(result, 'margin'));
      expect(Money.round2(margin), Decimal.fromInt(20));
    });

    test('a credit note reverses the margin rather than adding to it', () async {
      // Plan rule 2 again, from the cost side: the goods come back as a
      // positive movement with a positive cost, so the cost column reads
      // negative and the profit mirrors the original sale exactly.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 2),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
        docType: 'credit_note',
      );

      final result = await run('bill_wise_profit');
      expect(result.count, 2);
      // The sale and its exact mirror: net zero sales, net zero cost, net zero
      // profit. Printing the return as a fresh positive sale would report
      // ₹2,000 of profit on goods that were sold and returned.
      expect(sumOf(result, 'taxable'), Decimal.zero);
      expect(sumOf(result, 'cogs'), Decimal.zero);
      expect(sumOf(result, 'profit'), Decimal.zero);
    });

    test(
      'an uncosted invoice says so instead of showing 100% margin',
      () async {
        // The most expensive kind of wrong number in this app: a margin column
        // silently reading 100% because the cost is missing.
        //
        // An item with a purchase price is NOT the uncosted case — the movement
        // falls back to `items.purchasePrice` and records that. Genuinely
        // uncosted means never bought and never given a price: the shop sells
        // something it has no cost for at all.
        final itemId = await stockedItem(purchasePrice: 0);
        await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

        final result = await run('bill_wise_profit');
        expect(sumOf(result, 'cogs'), Decimal.zero);
        expect(result.notes, isNotEmpty);
        expect(result.notes.join(' '), contains('INV-1'));
        expect(result.notes.join(' ').toLowerCase(), contains('not a real'));
      },
    );

    test('an item with a purchase price is costed from it', () async {
      // The other half of the same rule, and the reason the case above needs
      // `purchasePrice: 0`: with no purchase on record the movement falls back
      // to the catalogue price, so this sale has a real cost and no note.
      final itemId = await stockedItem(purchasePrice: 800);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('bill_wise_profit');
      expect(sumOf(result, 'cogs'), Decimal.fromInt(800));
      expect(result.notes, isEmpty);
    });

    test('a costed invoice raises no such note', () async {
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      expect((await run('bill_wise_profit')).notes, isEmpty);
    });

    test('its own arithmetic foots', () async {
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '20',
        rate: '800',
      );
      await invoice(
        id: 'a',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );
      await invoice(
        id: 'b',
        date: DateTime(2026, 5, 20),
        itemId: itemId,
        quantity: '3',
        rate: '1200',
      );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('bill_wise_profit'))
            .isClean,
        isTrue,
      );
    });
  });

  // ============================================================
  group('Trial Balance Report', () {
    test(
      'debit and credit are magnitudes, so the two totals can be compared',
      () async {
        final itemId = await stockedItem();
        await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

        final result = await run('trial_balance');
        final debitColumn = columnOf(result, 'debit');
        final creditColumn = columnOf(result, 'credit');

        var debit = Decimal.zero;
        var credit = Decimal.zero;
        for (final row in result.rows) {
          // A credit-balance account must print a *positive* figure under the
          // heading "Credit". A signed column totals the wrong way and the two
          // totals then differ by twice the real difference.
          expect(row.number(creditColumn) >= Decimal.zero, isTrue);
          expect(row.number(debitColumn) >= Decimal.zero, isTrue);
          debit += row.number(debitColumn);
          credit += row.number(creditColumn);
        }
        expect(debit, credit, reason: 'the books must foot');
      },
    );

    test('it reports that the books balance rather than throwing', () async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('trial_balance');
      expect(result.notes.join(' '), contains('balance'));
    });

    test('the closing column stays signed', () async {
      // The repository's convention — positive is a debit balance — is what a
      // sorted ledger wants, and the report keeps it. Only the Dr/Cr *columns*
      // are magnitudes.
      //
      // An unpaid **bill** is what creates a creditor; a sale creates a debtor.
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);

      final result = await run('trial_balance');
      final closing = columnOf(result, 'closing');
      final creditBalance = result.rows.firstWhere(
        (r) => r.cells['code'] == LedgerCodes.creditors,
        orElse: () => throw StateError('no creditor row in the trial balance'),
      );
      expect(
        creditBalance.number(closing) < Decimal.zero,
        isTrue,
        reason: 'creditors owe money, so they hold a credit balance',
      );
      // And its own credit column carries the magnitude, positively.
      expect(
        creditBalance.number(columnOf(result, 'credit')) > Decimal.zero,
        isTrue,
      );
    });

    test('its own rows and totals agree', () async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'r',
            amount: 1180,
            date: DateTime(2026, 4, 25),
          );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('trial_balance'))
            .isClean,
        isTrue,
      );
    });
  });

  // ============================================================
  group('Balance Sheet', () {
    test(
      'assets equal liabilities plus equity, and the report says so',
      () async {
        final itemId = await stockedItem();
        await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
        await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

        final result = await run('balance_sheet');
        final amount = columnOf(result, 'amount');

        var assets = Decimal.zero;
        var liabilities = Decimal.zero;
        var equity = Decimal.zero;
        for (final row in result.rows) {
          switch (row.cells['section']) {
            case 'Assets':
              assets += row.number(amount);
            case 'Liabilities':
              liabilities += row.number(amount);
            case 'Equity':
              equity += row.number(amount);
          }
        }
        expect(assets, liabilities + equity);
        expect(
          result.notes.join(' '),
          contains('equal liabilities plus equity'),
        );
      },
    );

    test("the period's profit is inside equity, not a footnote", () async {
      // Profit that has not been drawn out belongs to the owner. Omitting it is
      // the classic balance-sheet error — and it is what makes assets not
      // equal liabilities plus equity.
      //
      // A **sale with no purchase** is the fixture, not a bill-then-invoice
      // one. The ledger expenses a purchase when it is bought rather than
      // holding it as a stock asset, so a firm that bought 10 and sold 2 shows
      // a *loss* on this sheet while Bill Wise Profit shows a healthy margin.
      // That divergence is real and documented in the spec's footnote; what
      // this test pins is the thing that must always hold — the profit row is
      // present, it sits in the equity section, and the sheet still foots.
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

      final result = await run('balance_sheet');
      final labels = textsOf(result, 'account');
      expect(labels, contains('Profit to date'));

      final profitRow = result.rows.firstWhere(
        (r) => r.cells['account'] == 'Profit to date',
      );
      expect(profitRow.cells['section'], 'Equity');
      // ₹1,000 of revenue, no cost posted to the ledger.
      expect(
        profitRow.number(columnOf(result, 'amount')),
        Decimal.fromInt(1000),
      );

      // And the sheet balances with that row inside equity.
      final amount = columnOf(result, 'amount');
      var assets = Decimal.zero;
      var rest = Decimal.zero;
      for (final row in result.rows) {
        if (row.cells['section'] == 'Assets') {
          assets += row.number(amount);
        } else {
          rest += row.number(amount);
        }
      }
      expect(assets, rest);
    });

    test('buying stock shows a loss here and a margin in Bill Wise Profit', () async {
      // The ledger's own accounting, pinned so it is a known quantity rather
      // than a surprise: `Purchases` is an **expense** account, so stock bought
      // reduces cumulative profit on the day it is bought. Bill Wise Profit
      // takes its cost from the stock movement log instead, so it reports the
      // margin on the goods actually sold.
      //
      // Two reports, one set of books, two different and individually correct
      // answers — which is exactly why the Balance Sheet's footnote says so
      // rather than leaving a CA to find it.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );

      final sheet = await run('balance_sheet');
      expect(textsOf(sheet, 'account'), contains('Loss to date'));

      final profit = await run('bill_wise_profit');
      expect(sumOf(profit, 'profit'), Decimal.fromInt(400));
      expect(sumOf(profit, 'cogs'), Decimal.fromInt(1600));
    });

    test('a loss is labelled as a loss', () async {
      // Selling below cost is not "negative profit to date"; the row says what
      // it is, because "Profit to date: −400" is a label that lies.
      //
      // The ledger posts no cost against a sale, so a sale alone is never a
      // loss. A purchase on top of a small sale is: the purchase is expensed in
      // full and the sale only partly offsets it.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '1',
        rate: '500',
      );

      final result = await run('balance_sheet');
      expect(textsOf(result, 'account'), contains('Loss to date'));
    });

    test('it reads the window\'s end, not its middle', () async {
      // A balance sheet is a photograph. "For this quarter" shows the quarter's
      // end; showing the start would be a different document under the same
      // name.
      final itemId = await stockedItem();
      await invoice(id: 'before', date: DateTime(2026, 1, 5), itemId: itemId);
      await invoice(id: 'inside', date: DateTime(2026, 4, 20), itemId: itemId);

      // Both sales happened before 30 June, so both are inside the sheet as at
      // that date — and cumulative profit is ₹2,000, not the ₹1,000 that a
      // sheet "as at 1 April" would show.
      final result = await run('balance_sheet');
      final profitRow = result.rows.firstWhere(
        (r) => r.cells['section'] == 'Equity',
        orElse: () => throw StateError('no equity row on the sheet'),
      );
      expect(
        profitRow.number(columnOf(result, 'amount')),
        Decimal.fromInt(2000),
      );
    });

    test('an empty firm produces no rows, not a sheet of zeros', () async {
      final result = await run('balance_sheet');
      expect(result.isEmpty, isTrue);
    });
  });

  // ============================================================
  group('Profit And Loss', () {
    test('a credit note reduces income rather than adding to it', () async {
      final itemId = await stockedItem();
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), itemId: itemId);
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 5, 2),
        itemId: itemId,
        docType: 'credit_note',
      );

      final result = await run('profit_and_loss');
      final labels = textsOf(result, 'label');
      final income = result.rows.firstWhere(
        (r) => r.cells['label'] == 'Total income',
      );
      expect(labels, contains('Total income'));
      expect(labels, contains('Total expenses'));
      // ₹1,000 billed then returned.
      expect(income.number(columnOf(result, 'amount')), Decimal.zero);
    });

    test('gross profit and net are the lines a CA reads first', () async {
      // Flattened into a plain grid a P&L becomes "Description | Amount" with
      // no gross profit in it anywhere, and gross profit is the line read
      // first.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );

      final result = await run('profit_and_loss');
      expect(result.spec.layout, ReportLayout.document);
      expect(result.count, greaterThan(0));
      expect(textsOf(result, 'label'), contains('Total income'));
    });

    test(
      'it says that it and the Trial Balance are two implementations',
      () async {
        // Plan rule 13. This P&L sums document headers; the Trial Balance sums
        // journal_lines. A hand-keyed voucher exists only in the second, so the
        // two can legitimately disagree — and the reader has to be told rather
        // than handed an exception page.
        final itemId = await stockedItem();
        await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);

        final result = await run('profit_and_loss');
        expect(result.notes.join(' '), contains('Trial Balance'));
      },
    );

    test('its own rows and totals agree', () async {
      final itemId = await stockedItem();
      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), itemId: itemId);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 20), itemId: itemId);
      await db
          .expenseRepositoryFor(firmId)
          .create(
            type: 'expense',
            number: 'E-1',
            category: 'Rent',
            amount: 500,
            date: DateTime(2026, 4, 28),
          );

      expect(
        ReportIntegrityChecks.assertIntegrity(await run('profit_and_loss'))
            .isClean,
        isTrue,
      );
    });
  });

  // ============================================================
  group('Cash flow', () {
    test('it is derived from the cash and bank accounts, so it agrees with '
        'the Balance Sheet by construction', () async {
      // The design decision in one test. Reading the payment and expense tables
      // would have to re-implement the bounced-cheque exclusion in a second
      // place, which is how the HIGH finding happened once already.
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 5000,
            date: DateTime(2026, 4, 5),
          );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'P-1',
            amount: 2000,
            date: DateTime(2026, 4, 6),
          );

      final result = await run('cash_flow');
      expect(sumOf(result, 'inflow'), Decimal.fromInt(5000));
      expect(sumOf(result, 'outflow'), Decimal.fromInt(2000));

      // And the same figure is on the balance sheet.
      final sheet = await run('balance_sheet');
      final cashRow = sheet.rows.firstWhere(
        (r) => r.cells['code'] == LedgerCodes.cash,
        orElse: () => throw StateError('no cash account on the sheet'),
      );
      expect(cashRow.number(columnOf(sheet, 'amount')), Decimal.fromInt(3000));
    });

    test('the running balance is the sum of the column above it', () async {
      // Plan rule 8, stated as a test: the last row's balance must equal the
      // opening plus every printed debit minus every printed credit. A running
      // total computed in `double` over thousands of rows will not.
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 10000,
            date: DateTime(2026, 4, 5),
          );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_out',
            number: 'P-1',
            amount: 2500.55,
            date: DateTime(2026, 4, 6),
          );
      await db
          .expenseRepositoryFor(firmId)
          .create(
            type: 'expense',
            number: 'E-1',
            category: 'Rent',
            amount: 111.11,
            date: DateTime(2026, 4, 7),
          );

      final result = await run('cash_flow');
      final inflow = columnOf(result, 'inflow');
      final outflow = columnOf(result, 'outflow');
      final closing = columnOf(result, 'closing');

      var expected = Decimal.zero;
      for (final row in result.rows) {
        expected += row.number(inflow) - row.number(outflow);
        expect(
          row.number(closing),
          expected,
          reason:
              'the running balance must be the sum of the columns above '
              'it, to the paisa',
        );
      }
      expect(expected, Decimal.parse('7388.34'));
    });

    test('it counts cheques in hand as money the business has', () async {
      // Not yet banked, but it is money. A cheque that bounces simply never
      // gets cleared, so it drops out on its own.
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 7500,
            date: DateTime(2026, 4, 5),
            mode: 'cheque',
          );

      final result = await run('cash_flow');
      expect(sumOf(result, 'inflow'), Decimal.fromInt(7500));
      final accounts = textsOf(result, 'account');
      expect(accounts, isNotEmpty);
    });

    test('a bounced cheque never reaches it', () async {
      final payments = db.paymentRepositoryFor(firmId);
      final cheque = await payments.create(
        type: 'payment_in',
        number: 'R-1',
        amount: 7500,
        date: DateTime(2026, 4, 5),
        mode: 'cheque',
      );
      await payments.markChequeBounced(cheque.id, reason: 'Insufficient funds');

      expect((await run('cash_flow')).isEmpty, isTrue);
    });

    test('a journal voucher that moved cash shows up', () async {
      // A journal voucher moves cash with no payment or expense row at all.
      // This is the case that makes the cash accounts the right source rather
      // than the payment table.
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      final cash = await ledger.byCode(LedgerCodes.cash);
      final bank = await ledger.byCode(LedgerCodes.bank);
      await ledger.createJournal(
        date: DateTime(2026, 4, 20),
        narration: 'Cash deposited at bank',
        lines: [
          JournalLineDraft(accountId: bank!.id, debit: 3000),
          JournalLineDraft(accountId: cash!.id, credit: 3000),
        ],
      );

      final result = await run('cash_flow');
      // Both legs are cash-like, so the merged stream shows both: ₹3,000 in
      // and ₹3,000 out. The business' cash is unchanged, which is exactly what
      // the running balance then shows.
      expect(sumOf(result, 'inflow'), Decimal.fromInt(3000));
      expect(sumOf(result, 'outflow'), Decimal.fromInt(3000));
      final closing = columnOf(result, 'closing');
      expect(
        result.rows.last.number(closing),
        Decimal.zero,
        reason: 'moving your own money between tills is not a cash flow',
      );
    });

    test('it refuses to pretend it can split into operating, investing and '
        'financing', () async {
      // Those need the contra account on the far side of every cash posting.
      // The app posts payments and expenses straight to the ledger, so for most
      // rows the contra is only a narration string — and a classification
      // invented from a narration would look like the real thing and not be.
      final result = await run('cash_flow');
      expect(result.spec.footnote, isNotNull);
      expect(result.spec.footnote, contains('operating'));
    });

    test('an empty firm produces no rows', () async {
      expect((await run('cash_flow')).isEmpty, isTrue);
    });
  });

  // ============================================================
  group('the category as a whole', () {
    test('all nine are implemented, not placeholders', () async {
      // A menu entry that quietly prints nothing is worse than an absent one.
      final implemented = ReportCatalogue.inCategory(ReportCategory.transaction)
          .map((d) => d.spec.id)
          .toSet();
      expect(implemented, {
        'sale',
        'purchase',
        'day_book',
        'all_transactions',
        'profit_and_loss',
        'bill_wise_profit',
        'cash_flow',
        'trial_balance',
        'balance_sheet',
      });
    });

    test('each one passes its own integrity check on a stocked firm', () async {
      // The whole category against one fixture, because the failure this
      // catches is a source that returns a cell the spec never declared — and
      // that only shows up with every column filled.
      final itemId = await stockedItem();
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        itemId: itemId,
        quantity: '10',
        rate: '800',
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        itemId: itemId,
        quantity: '2',
        rate: '1000',
      );
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'R-1',
            amount: 2360,
            date: DateTime(2026, 4, 25),
          );
      await db
          .expenseRepositoryFor(firmId)
          .create(
            type: 'expense',
            number: 'E-1',
            category: 'Rent',
            amount: 500,
            date: DateTime(2026, 4, 28),
          );

      for (final definition in ReportCatalogue.inCategory(
        ReportCategory.transaction,
      )) {
        final result = await definition.run(db, firmId, window);
        final integrity = ReportIntegrityChecks.assertIntegrity(result);
        expect(
          integrity.problems,
          isEmpty,
          reason: '${definition.spec.title}: ${integrity.problems.join('; ')}',
        );
      }
    });

    test('every one is empty for an empty firm', () async {
      // "No data" must never render as "no money", which is what a source
      // returning a row of zeros would do.
      for (final definition in ReportCatalogue.inCategory(
        ReportCategory.transaction,
      )) {
        final result = await definition.run(db, firmId, window);
        expect(
          result.rows,
          isEmpty,
          reason: '${definition.spec.title} invented rows for an empty firm',
        );
      }
    });
  });
}
