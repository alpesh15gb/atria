import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import 'transaction_common.dart';

/// Every movement of money in the window, in one chronological list.
///
/// Five sources unioned — sales, purchases, receipts, payments, expenses —
/// plus hand-keyed journal vouchers, because a voucher that moved cash is a
/// transaction even though no document says so. **Omitting the journal lines is
/// the version of this report that is quietly wrong**: it foots perfectly and
/// it disagrees with the bank by whatever the owner keyed.
///
/// **Why it prints two money columns rather than one signed amount.** A single
/// `Amount` column has to be read carefully — is the ₹3,000 an inflow or an
/// outflow? Two columns, each summing on its own, give a gross received and a
/// gross paid that can be compared against the bank statement line by line,
/// which is what a shopkeeper checks. The net is the difference, and printing it
/// would be a third column summing nothing meaningful.
///
/// **A bounced cheque is not an inflow.** [ReportFilters.notBounced] rather than
/// `not(equals('bounced'))`, because on a **null** status — every cash and bank
/// payment — `NOT(status = 'bounced')` is SQL NULL and would drop all of them.
/// That bug has been in this codebase before and cost a HIGH finding.
const ReportSpec allTransactionsSpec = ReportSpec(
  id: 'all_transactions',
  title: 'All Transactions',
  category: 'Transaction',
  groupBy: ReportGroupBy.month,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'number', label: 'No.', emphasise: true),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(key: 'reference', label: 'Reference', flex: 2, wideOnly: true),
    ReportColumn(key: 'inflow', label: 'Received', kind: ReportValueKind.money),
    ReportColumn(key: 'outflow', label: 'Paid', kind: ReportValueKind.money),
  ],
  footnote:
      'A hand-keyed journal voucher appears once: money debited into '
      'cash, bank or cheques in hand is Received and money credited out of them '
      'is Paid, so a deposit of cash into the bank shows as money in even '
      'though the business\'s cash did not grow. A voucher with no leg on a '
      'cash account — an accrual, or a transfer between two ledgers only — moves '
      'no money and is left out.',
);

const ReportDefinition allTransactions = ReportDefinition(
  spec: allTransactionsSpec,
  source: CallbackReportSource(
    sourceId: 'all_transactions',
    query: allTransactionRows,
  ),
);

/// **Day Book** — the same list, grouped by day.
///
/// Deliberately built on [allTransactionRows] rather than a second query. A day
/// book *is* the all-transactions list read one day at a time, and two
/// implementations of "everything that moved money" would drift — which is
/// exactly the disagreement plan rule 13 exists to catch between the Trial
/// Balance and the P&L.
const ReportSpec dayBookSpec = ReportSpec(
  id: 'day_book',
  title: 'Day Book',
  category: 'Transaction',
  groupBy: ReportGroupBy.date,
  sort: ReportSort(columnKey: 'date'),
  columns: [
    ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
    ReportColumn(key: 'type', label: 'Type', flex: 2),
    ReportColumn(key: 'number', label: 'No.', emphasise: true),
    ReportColumn(key: 'party', label: 'Party', flex: 3),
    ReportColumn(key: 'reference', label: 'Reference', flex: 2, wideOnly: true),
    ReportColumn(key: 'inflow', label: 'Received', kind: ReportValueKind.money),
    ReportColumn(key: 'outflow', label: 'Paid', kind: ReportValueKind.money),
  ],
  footnote:
      'Every receipt, payment, sale, purchase and journal entry in the '
      'period, grouped by day. Compare the Received and Paid totals against the '
      'bank statement.',
);

const ReportDefinition dayBook = ReportDefinition(
  spec: dayBookSpec,
  source: CallbackReportSource(sourceId: 'day_book', query: allTransactionRows),
);

/// The union of every table that moves money.
Future<List<ReportRow>> allTransactionRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final rows = <ReportRow>[];

  // 1. Sales documents. A credit note is an outflow: the goods come back and,
  //    on a prepaid sale, the money goes back out.
  final sales =
      await (db.select(db.salesInvoices)
            ..where((t) => liveSalesIn(window, firmId, db.salesInvoices))
            ..orderBy([(t) => OrderingTerm.asc(t.invoiceDate)]))
          .get();
  for (final doc in sales) {
    final total = _signed(dec(doc.grandTotal), doc.docType);
    rows.add(
      _money(
        date: doc.invoiceDate,
        type: docTypeLabel(doc.docType),
        number: doc.number,
        party: doc.partyName ?? '—',
        reference: doc.partyGstin ?? '',
        amount: total,
      ),
    );
  }

  // 2. Purchase documents, the other way round.
  final bills =
      await (db.select(db.purchaseBills)
            ..where((t) => livePurchasesIn(window, firmId, db.purchaseBills))
            ..orderBy([(t) => OrderingTerm.asc(t.billDate)]))
          .get();
  for (final bill in bills) {
    rows.add(
      _money(
        date: bill.billDate,
        type: docTypeLabel(bill.docType),
        number: bill.number,
        party: bill.partyName ?? '—',
        reference: bill.supplierInvoiceNumber ?? '',
        amount: _signed(dec(bill.grandTotal), bill.docType),
      ),
    );
  }

  // 3. Payments in and out. Bounced cheques never appear, in either direction:
  //    a cheque that came back is not a receipt, and the reversal is not a
  //    payment either.
  final payments =
      await (db.select(db.payments)
            ..where(
              (t) =>
                  t.firmId.equals(firmId) &
                  ReportFilters.notDeleted(t.isDeleted) &
                  ReportFilters.notBounced(t.chequeStatus) &
                  ReportFilters.within(t.date, window),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .get();
  for (final payment in payments) {
    final isIn = payment.type == 'payment_in';
    final amount = dec(payment.amount);
    rows.add(
      _money(
        date: payment.date,
        type: isIn ? 'Receipt' : 'Payment',
        number: payment.number,
        party: payment.partyName ?? '—',
        reference: _paymentReference(payment.mode, payment.reference),
        amount: isIn ? amount : -amount,
      ),
    );
  }

  // 4. Expenses and other income. These are cash movements with no document on
  //    the other side — the category is the only thing identifying them, so it
  //    goes in the Reference column where a cheque number would otherwise sit.
  final expenses =
      await (db.select(db.expenses)
            ..where(
              (t) =>
                  t.firmId.equals(firmId) &
                  ReportFilters.notDeleted(t.isDeleted) &
                  ReportFilters.within(t.date, window),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .get();
  for (final expense in expenses) {
    final isIncome = expense.type == 'income';
    final amount = dec(expense.amount);
    rows.add(
      _money(
        date: expense.date,
        type: isIncome ? 'Income' : 'Expense',
        number: expense.number,
        party: expense.vendorName ?? '—',
        reference: expense.category,
        amount: isIncome ? amount : -amount,
      ),
    );
  }

  // 5. Journal vouchers, at their net.
  final journals =
      await (db.select(db.journalEntries)
            ..where(
              (t) =>
                  t.firmId.equals(firmId) &
                  ReportFilters.notDeleted(t.isDeleted) &
                  ReportFilters.within(t.date, window),
            )
            ..orderBy([(t) => OrderingTerm.asc(t.date)]))
          .get();
  if (journals.isNotEmpty) {
    final ledger = db.ledgerRepositoryFor(firmId);
    await ledger.ensureChart();
    final cashAccounts = <String>{};
    for (final code in const [
      LedgerCodes.cash,
      LedgerCodes.bank,
      LedgerCodes.chequesInHand,
    ]) {
      final account = await ledger.byCode(code);
      if (account != null) cashAccounts.add(account.id);
    }
    final legs = await _cashLegsByVoucher(
      db,
      journals.map((e) => e.id).toList(),
      cashAccounts,
    );
    for (final journal in journals) {
      final leg = legs[journal.id];
      // A voucher with no leg on a cash account moves no money — an accrual, or
      // a transfer between two ledger accounts. It has no place in a list of
      // things that moved cash, so it is left out rather than printed as a row
      // of ₹0 and ₹0.
      if (leg == null) continue;
      rows.add(
        _legs(
          date: journal.date,
          type: 'Journal',
          number: journal.number,
          party: journal.narration,
          reference: journal.reference ?? '',
          inflow: leg.inflow,
          outflow: leg.outflow,
        ),
      );
    }
  }

  rows.sort((a, b) {
    final da = a.cells['date'] as DateTime;
    final db2 = b.cells['date'] as DateTime;
    final byDate = da.compareTo(db2);
    // Ties broken on the number so two invoices raised on the same minute keep
    // a stable order between runs. Without this the list shuffles on every
    // rebuild and a reader comparing it to yesterday's print cannot tell what
    // actually changed.
    return byDate != 0
        ? byDate
        : '${a.cells['number']}'.compareTo('${b.cells['number']}');
  });
  return rows;
}

/// Σ(debit) and Σ(credit) **on cash-like accounts** per voucher, in SQL.
///
/// The restriction to cash accounts is the whole correctness argument, and it
/// is not a refinement — it is what makes the numbers mean anything.
///
/// A voucher is two-sided by construction and the ledger rejects an unbalanced
/// one, so **Σ(debit) − Σ(credit) over the whole entry is always zero.** An
/// earlier version of this function summed the entry, found zero on every
/// voucher, and silently dropped all of them — which is precisely the bug the
/// footnote warns about, arriving through arithmetic instead of through an
/// omitted table.
///
/// **Debit and credit are kept apart rather than netted**, and that is the
/// second half of the same argument. Restricting to the cash accounts is not
/// enough on its own: a ₹2,000 deposit from the till to the bank still nets to
/// zero across them, because the money only changed pocket. Netting would drop
/// the voucher — and a deposit *does* appear on the bank statement, so dropping
/// it makes the report disagree with the very statement it is read against.
/// Splitting the legs puts ₹2,000 in Received and ₹2,000 in Paid, which foots
/// to nil across the row, reconciles against the bank statement line by line,
/// and is exactly what the owner saw happen.
///
/// A voucher whose only cash leg is one-sided — ₹5,000 of rent paid by voucher
/// is ₹5,000 out against an expense credit — falls out with no special-casing.
Future<Map<String, _CashLeg>> _cashLegsByVoucher(
  AppDatabase db,
  List<String> ids,
  Set<String> cashAccounts,
) async {
  final out = <String, _CashLeg>{};
  if (ids.isEmpty || cashAccounts.isEmpty) return out;
  // The query builder rather than `customSelect`, so the `IN (…)` expansion and
  // its variable chunking are drift's problem rather than ours: a quarter with
  // thousands of vouchers exceeds SQLite's raw `IN` variable cap.
  final debit = db.journalLines.debit.sum();
  final credit = db.journalLines.credit.sum();
  final query = db.selectOnly(db.journalLines)
    ..addColumns([db.journalLines.entryId, debit, credit])
    ..where(
      db.journalLines.entryId.isIn(ids) &
          db.journalLines.accountId.isIn(cashAccounts.toList()),
    )
    ..groupBy([db.journalLines.entryId]);
  for (final row in await query.get()) {
    final entryId = row.read(db.journalLines.entryId);
    if (entryId == null) continue;
    out[entryId] = _CashLeg(
      inflow: dec(row.read(debit) ?? 0),
      outflow: dec(row.read(credit) ?? 0),
    );
  }
  return out;
}

/// One voucher's cash-like legs. Both are magnitudes; neither is signed.
class _CashLeg {
  const _CashLeg({required this.inflow, required this.outflow});

  final Decimal inflow;
  final Decimal outflow;
}

/// One money movement, split across the two columns.
///
/// A negative amount is money going out. It is **not** clamped to zero and the
/// two columns are not derived from each other: a receipt of ₹0 (a fully
/// written-off bill) is a real row with nothing in it, and printing it as
/// absent would make a set of invoices look unpaid.
ReportRow _money({
  required DateTime date,
  required String type,
  required String number,
  required String party,
  required String reference,
  required Decimal amount,
}) => ReportRow({
  'date': date,
  'type': type,
  'number': number,
  'party': party,
  'reference': reference,
  'inflow': amount > Decimal.zero ? amount : Decimal.zero,
  'outflow': amount < Decimal.zero ? -amount : Decimal.zero,
}, label: number);

/// A journal voucher, which carries **both** a debit and a credit rather than
/// one signed amount.
///
/// Every other source in this file moves money one way, so `_money` can derive
/// the second column from the sign of the first. A voucher cannot: a deposit is
/// money received by the bank *and* money paid out of the till in the same
/// keystroke, and forcing it through a single signed number is what made the
/// voucher disappear.
ReportRow _legs({
  required DateTime date,
  required String type,
  required String number,
  required String party,
  required String reference,
  required Decimal inflow,
  required Decimal outflow,
}) => ReportRow({
  'date': date,
  'type': type,
  'number': number,
  'party': party,
  'reference': reference,
  'inflow': inflow < Decimal.zero ? -inflow : inflow,
  'outflow': outflow < Decimal.zero ? -outflow : outflow,
}, label: number);

String _paymentReference(String mode, String? reference) => [
  if (mode.isNotEmpty) _modeLabel(mode),
  if (reference != null && reference.isNotEmpty) reference,
].join(' · ');

String _modeLabel(String mode) => switch (mode) {
  'cash' => 'Cash',
  'upi' => 'UPI',
  'card' => 'Card',
  'bank' => 'Bank',
  'cheque' => 'Cheque',
  'neft' || 'rtgs' || 'netbanking' => mode.toUpperCase(),
  _ => mode,
};

Decimal _signed(Decimal value, String docType) =>
    signFor(docType) < 0 ? -value : value;
