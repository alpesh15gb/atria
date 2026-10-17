import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../utils/money.dart';

double bankPaymentAmount(PaymentEntity payment) {
  if (payment.isDeleted) return 0;
  if ((payment.mode == 'cheque' || payment.chequeStatus != null) &&
      payment.chequeStatus != 'cleared') {
    return 0;
  }
  return payment.type == 'payment_in' ? payment.amount : -payment.amount;
}

DateTime bankPaymentDate(PaymentEntity payment) =>
    payment.mode == 'cheque' || payment.chequeStatus != null
    ? payment.clearanceDate ?? payment.date
    : payment.date;

/// Account balances are derived locally, including after a sync pull. Sending
/// cached totals between devices would lose concurrent receipts.
Future<void> rebuildBankBalances(AppDatabase db, String firmId) async {
  final accounts = await (db.select(
    db.bankAccounts,
  )..where((a) => a.firmId.equals(firmId))).get();
  final payments = await (db.select(
    db.payments,
  )..where((p) => p.firmId.equals(firmId))).get();
  for (final account in accounts) {
    var balance = Money.of(account.openingBalance);
    for (final payment in payments) {
      if (payment.bankAccountId == account.id) {
        balance += Money.of(bankPaymentAmount(payment));
      }
    }
    await (db.update(
      db.bankAccounts,
    )..where((a) => a.id.equals(account.id) & a.firmId.equals(firmId))).write(
      BankAccountsCompanion(
        currentBalance: Value(Money.round2(balance).toDouble()),
      ),
    );
  }
}
