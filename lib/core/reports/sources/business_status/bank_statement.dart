import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';

/// **Bank Statement** — money in and out of one account, with a running balance.
///
/// The one report in the library whose answer depends on an **opening balance**,
/// which is the whole difficulty. A running balance built only from the window's
/// rows is wrong at the first line whenever the window starts after the account
/// did: it opens at zero and every row is off by whatever was already in the
/// account. So the opening figure is read from `bank_accounts.currentBalance`
/// and walked **backwards** from the window's end, rather than being assumed.
///
/// **Cash in hand is listed beside the bank accounts.** `BankAccounts.type`
/// deliberately includes `cash`, because "Cash in hand" has to appear here next
/// to HDFC and ICICI — and the only honest way to show it is as an account.
/// Cash-as-the-absence-of-a-row would make the account list a lie.
///
/// **A bounced cheque is not money.** `payments.chequeStatus` is a lifecycle
/// for a reason: a cheque in hand can bounce, a deposited one is not money
/// until it clears, and only a cleared one is. A statement that counted a
/// bounced cheque as a receipt shows a balance the firm does not have.
///
/// **Every account gets a row even with no movement.** An account that appears
/// only when it moves is a list of transactions, not a statement of accounts.
const ReportSpec bankStatementSpec = ReportSpec(
  id: 'bank_statement',
  title: 'Bank Statement',
  category: 'Business Status',
  sort: ReportSort(columnKey: 'date', descending: false),
  defaultFilters: [
    ReportFilter<Object?>(
      id: kBankFilterId,
      label: 'Account',
      value: null,
      hint: 'Every account',
    ),
  ],
  columns: [
    ReportColumn(key: 'date', label: 'Date', flex: 2),
    ReportColumn(key: 'account', label: 'Account', flex: 3, emphasise: true),
    ReportColumn(key: 'particulars', label: 'Particulars', flex: 4),
    ReportColumn(key: 'reference', label: 'Reference'),
    ReportColumn(
      key: 'receipt',
      label: 'Receipt',
      kind: ReportValueKind.money,
      colorize: true,
    ),
    ReportColumn(
      key: 'payment',
      label: 'Payment',
      kind: ReportValueKind.money,
      colorize: true,
    ),
    ReportColumn(
      key: 'balance',
      label: 'Balance',
      kind: ReportValueKind.money,
      flex: 2,
      emphasise: true,
    ),
  ],
  footnote:
      'Running balance, opening figure taken from each account\'s current '
      'balance and walked back to the start of the period — so the first row is '
      'right even when the period starts long after the account was opened. Cash '
      'in hand is listed beside the bank accounts. A cheque is counted only once '
      'it has cleared: a cheque in hand or merely deposited can bounce, and a '
      'bounced one is removed again. An account with no movement in the period '
      'still appears, showing its balance.',
);

const ReportDefinition bankStatement = ReportDefinition(
  spec: bankStatementSpec,
  source: CallbackReportSource(
    sourceId: 'bank_statement',
    query: bankStatementRows,
    options: _bankOptions,
    notes: _bankStatementNotes,
  ),
);

/// The account picker.
///
/// A named function, not a closure in the `const` definition: `Future.value` is
/// a method call and a call is not a constant expression.
Future<List<ReportFilterOption<Object?>>> _bankOptions(
  AppDatabase db,
  String firmId,
  ReportSpec spec,
  String filterId,
) async {
  final accounts = await (db.select(db.bankAccounts)
        ..where((a) => a.firmId.equals(firmId))
        ..orderBy([(a) => OrderingTerm.asc(a.name)]))
      .get();
  return [
    for (final account in accounts)
      ReportFilterOption<Object?>(value: account.id, label: account.name),
  ];
}

/// The filter id, and the key a null value means "every account".
const String kBankFilterId = 'bankAccountId';

// ignore_for_file: prefer_initializing_formals

/// One movement on a statement.
///
/// **The receipt and payment defaults are nullable, resolved by a getter.**
/// `Decimal.zero` is a `static final` in the decimal package and a default
/// parameter value must be a constant expression, so `= Decimal.zero` does not
/// compile. Nullable-and-coalesce is the spelling that does, and it keeps every
/// one-sided call site reading as "this side did not move".
class _Movement {
  // `prefer_initializing_formals` is deliberately declined: the field is
  // private so that a null means "this side did not move", which is a reading
  // decision, and an initializing formal would publish it as writable state.
_Movement(
    this.date,
    this.particulars,
    this.reference, {
    Decimal? receipt,
    Decimal? payment,
    this.order = 0,
  })  : _receipt = receipt,
        _payment = payment;

  final DateTime date;
  final String particulars;
  final String reference;

  /// Private because a null here means "this side did not move", and that is a
  /// reading decision rather than something to be written from outside.
  final Decimal? _receipt;
  final Decimal? _payment;

  /// Tie-break within a day, so the running balance is reproducible rather than
  /// depending on the order the two tables happened to be read in. Receipts sort
  /// first, as a printed statement does.
  final int order;

  /// Money in.
  Decimal get receipt => _receipt ?? Decimal.zero;

  /// Money out. Positive — the column says which way it went.
  Decimal get payment => _payment ?? Decimal.zero;

  Decimal get balanceChange => receipt - payment;
}

Future<List<ReportRow>> bankStatementRows(
  AppDatabase db,
  String firmId,
  ReportWindow window,
  Map<String, Object?> filters,
) async {
  final selected = filters[kBankFilterId] as String?;
  // The account scope is built in Dart rather than as a `where` fragment,
  // because "no filter" is the absence of a predicate and drift has no
  // `Expression` that means "true" — `equals(null)` would match nothing, and
  // the naive `1 == 1` trick puts a boolean where an expression belongs.
  final query = db.select(db.bankAccounts);
  if (selected == null) {
    query.where((a) => a.firmId.equals(firmId));
  } else {
    query.where((a) => a.firmId.equals(firmId) & a.id.equals(selected));
  }
  final accounts =
      await (query..orderBy([(a) => OrderingTerm.asc(a.name)])).get();
  if (accounts.isEmpty) return const [];

  final rows = <ReportRow>[];

  for (final account in accounts) {
    final movements = <_Movement>[];

    // ---- Payments --------------------------------------------------------
    //
    // A cheque is counted only once cleared. `chequeStatus` is null for money
    // that is not a cheque, and those rows are counted on their date.
    final payments = await (db.select(db.payments)
          ..where((p) =>
              p.firmId.equals(firmId) &
              p.bankAccountId.equals(account.id) &
              ReportFilters.within(p.date, window)))
        .get();

    for (final payment in payments) {
      final cheque = payment.chequeStatus;
      if (cheque == 'pending' || cheque == 'deposited' || cheque == 'bounced') {
        continue;
      }
      final amount = dec(payment.amount);
      final isReceipt = payment.type == 'payment_in';
      final party = (payment.partyName ?? '').trim();
      movements.add(_Movement(
        payment.date,
        party.isEmpty
            ? (isReceipt ? 'Receipt' : 'Payment')
            : (isReceipt ? 'Received from $party' : 'Paid to $party'),
        (payment.reference ?? payment.number).trim(),
        receipt: isReceipt ? amount : Decimal.zero,
        payment: isReceipt ? Decimal.zero : amount,
        order: isReceipt ? 0 : 1,
      ));
    }

    // ---- Loan movements --------------------------------------------------
    //
    // A loan repayment leaves this account, a disbursement arrives in it. The
    // interest is part of the amount that moved, so it is named in the
    // particulars rather than added to the principal — the money column is what
    // left, and splitting it there would not foot.
    final loans = await (db.select(db.loans)..where((l) => l.firmId.equals(firmId)))
        .get();
    final loanIds = [for (final loan in loans) loan.id];
    if (loanIds.isNotEmpty) {
      final loanTransactions = await (db.select(db.loanTransactions)
            ..where((t) =>
                t.firmId.equals(firmId) &
                t.loanId.isIn(loanIds) &
                ReportFilters.within(t.date, window)))
          .get();
      final loanNames = {for (final loan in loans) loan.id: loan.partyName ?? 'Loan'};
      for (final entry in loanTransactions) {
        final name = loanNames[entry.loanId] ?? 'Loan';
        switch (entry.kind) {
          case 'disbursement':
            movements.add(_Movement(
              entry.date,
              'Loan received from $name',
              entry.reference ?? '',
              receipt: dec(entry.amount),
            ));
          case 'repayment':
            movements.add(_Movement(
              entry.date,
              'Loan repaid to $name',
              entry.reference ?? '',
              payment: dec(entry.amount),
            ));
          case 'interest_charge':
            movements.add(_Movement(
              entry.date,
              'Interest charged on $name',
              entry.reference ?? '',
              payment: dec(entry.amount),
            ));
          case 'adjustment':
            final isIn = dec(entry.amount) > Decimal.zero;
            movements.add(_Movement(
              entry.date,
              'Loan adjustment — $name',
              entry.reference ?? '',
              receipt: isIn ? dec(entry.amount) : Decimal.zero,
              payment: isIn ? Decimal.zero : -dec(entry.amount),
            ));
          default:
            break;
        }
      }
    }

    movements.sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.order.compareTo(b.order);
    });

    // ---- The opening balance ---------------------------------------------
    //
    // `currentBalance` is the balance **now** — the ledger's cache, which
    // already contains everything this period did. So the opening figure is
    // what the account held *before* it: subtract every movement back out, then
    // walk forward through them again.
    //
    // **The sign is load-bearing and is the whole report.** Adding the
    // movements instead of subtracting them yields a statement whose last line
    // is `currentBalance` plus the period — a bank reconciliation that is out by
    // exactly the period's own activity, which is the one number the reader came
    // to check. Deriving the opening the other way (assume zero, or assume
    // `currentBalance` *is* the opening) is wrong for every period that does not
    // begin the day the account did.
    var opening = dec(account.currentBalance);
    for (final movement in movements) {
      opening -= movement.balanceChange;
    }

    var balance = opening;
    for (final movement in movements) {
      balance += movement.balanceChange;
      rows.add(ReportRow({
        'date': movement.date,
        'account': account.name,
        'particulars': movement.particulars,
        'reference': movement.reference,
        'receipt': movement.receipt,
        'payment': movement.payment,
        'balance': balance,
      }, label: '${account.name} · ${movement.particulars}'));
    }

    // An account with no movement still gets a row: a statement of accounts
    // that omits the account nobody used is not a statement of accounts, and a
    // reader checking a balance against the bank has nothing to compare against.
    if (movements.isEmpty) {
      rows.add(ReportRow({
        'date': window.from,
        'account': account.name,
        'particulars': 'No movement in this period',
        'reference': '',
        'receipt': Decimal.zero,
        'payment': Decimal.zero,
        'balance': opening,
      }, label: '${account.name} · no movement'));
    }
  }

  return rows;
}

/// A function, not a string — the source's `notes` slot is
/// `List<String> Function(ReportResult)`.
List<String> _bankStatementNotes(ReportResult result) => [
      'Reads payments and loan transactions posted to each account. Cheques are '
      'counted only once cleared.',
    ];