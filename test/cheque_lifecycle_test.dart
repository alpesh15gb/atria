import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cheque is money *promised*, and the app used to have no way to say what
/// happened to one: `reference` and `clearanceDate` were stored, a "Cheques to
/// deposit" figure was drawn from them, and nothing could ever move a cheque out
/// of that bucket.
///
/// The rule this pins down: a cheque in hand settles an invoice optimistically
/// (the reading every Indian billing app uses), and a **bounce reverses it** —
/// the money never arrived, so the invoice must go back to unpaid instead of
/// sitting there marked Paid against a returned cheque.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(
      name: 'Shri Balaji Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<void> invoice() async {
    await sales.save(SalesDraft(
      id: 'inv-1',
      number: 'INV-1',
      docType: 'invoice',
      invoiceDate: DateTime(2026, 9, 1),
      status: 'confirmed',
      lines: [
        SalesLineDraft(
          id: 'l1',
          name: 'Cement bag',
          quantity: Decimal.fromInt(10),
          unit: 'bag',
          rate: Decimal.fromInt(1000),
          gstRate: 0,
        ),
      ],
    ));
  }

  /// Records a cheque receipt that settles the invoice, the way the payments
  /// screen does.
  Future<PaymentEntity> chequeReceipt({String? reference}) async {
    await invoice();
    final payments = db.paymentRepositoryFor(firmId);
    final payment = await payments.create(
      type: 'payment_in',
      number: 'RCPT-1',
      amount: 10000,
      date: DateTime(2026, 9, 2),
      mode: 'cheque',
      reference: reference ?? '004512',
      linkedInvoiceId: 'inv-1',
    );
    await sales.applyPayment(
      invoiceId: 'inv-1',
      amount: 10000,
      date: DateTime(2026, 9, 2),
    );
    return payment;
  }

  test('a cheque starts in hand, and settles the document it links', () async {
    final payment = await chequeReceipt();
    expect(payment.chequeStatus, 'pending');
    expect((await sales.getById('inv-1'))!.paymentStatus, 'paid');

    final waiting = await db
        .paymentRepositoryFor(firmId)
        .watchUnclearedCheques()
        .first;
    expect(waiting.map((p) => p.id), contains(payment.id));
  });

  test('depositing does not move the money', () async {
    final payment = await chequeReceipt();
    await db.paymentRepositoryFor(firmId).markChequeDeposited(payment.id);

    final updated = (await db.paymentRepositoryFor(firmId).getById(payment.id))!;
    expect(updated.chequeStatus, 'deposited');
    expect(updated.depositedAt, isNotNull);
    // Still not cleared, so still in the bucket that needs working through.
    final waiting = await db
        .paymentRepositoryFor(firmId)
        .watchUnclearedCheques()
        .first;
    expect(waiting.map((p) => p.id), contains(payment.id));
  });

  test('clearing records when the bank cleared it and leaves the bucket',
      () async {
    final payment = await chequeReceipt();
    final when = DateTime(2026, 9, 5);
    await db
        .paymentRepositoryFor(firmId)
        .markChequeCleared(payment.id, date: when);

    final updated = (await db.paymentRepositoryFor(firmId).getById(payment.id))!;
    expect(updated.chequeStatus, 'cleared');
    expect(updated.clearanceDate, when);
    expect(
      await db.paymentRepositoryFor(firmId).watchUnclearedCheques().first,
      isEmpty,
    );
    expect((await sales.getById('inv-1'))!.paymentStatus, 'paid');
  });

  test('a bounce releases the invoice and keeps the reason', () async {
    final payment = await chequeReceipt();
    await db
        .paymentRepositoryFor(firmId)
        .markChequeBounced(payment.id, reason: 'Insufficient funds');

    final updated = (await db.paymentRepositoryFor(firmId).getById(payment.id))!;
    expect(updated.chequeStatus, 'bounced');
    expect(updated.bounceReason, 'Insufficient funds');
    expect(updated.bouncedAt, isNotNull);

    // The whole point: the document is not paid any more.
    final doc = (await sales.getById('inv-1'))!;
    expect(doc.paymentStatus, 'unpaid');
    expect(doc.balanceDue, closeTo(10000, 0.001));
    expect(doc.paidAmount, 0);

    // And a bounced cheque is not "still to deposit" either.
    expect(
      await db.paymentRepositoryFor(firmId).watchUnclearedCheques().first,
      isEmpty,
    );
    expect(
      (await db.paymentRepositoryFor(firmId).watchBouncedCheques().first)
          .map((p) => p.id),
      contains(payment.id),
    );
  });

  test('re-depositing a returned cheque puts the settlement back', () async {
    final payment = await chequeReceipt();
    final payments = db.paymentRepositoryFor(firmId);
    await payments.markChequeBounced(payment.id, reason: 'Funds not clear');
    expect((await sales.getById('inv-1'))!.paymentStatus, 'unpaid');

    await payments.markChequeDeposited(payment.id);
    final updated = (await payments.getById(payment.id))!;
    expect(updated.chequeStatus, 'deposited');
    // The old reason described a bounce that has been dealt with; leaving it
    // would keep a reversal in the row for ever.
    expect(updated.bounceReason, null);
    expect((await sales.getById('inv-1'))!.paymentStatus, 'paid');
  });

  test('cash has no cheque state to move', () async {
    await invoice();
    final payments = db.paymentRepositoryFor(firmId);
    final cash = await payments.create(
      type: 'payment_in',
      number: 'RCPT-2',
      amount: 500,
      date: DateTime(2026, 9, 2),
      mode: 'cash',
    );

    expect(cash.chequeStatus, null);
    await expectLater(
      payments.markChequeDeposited(cash.id),
      throwsA(isA<StateError>()),
    );
  });

  test('a cheque dated inside a locked period is refused', () async {
    final payment = await chequeReceipt();
    final settings = db.settingsRepository;
    await settings.set(
      'books_locked_upto',
      DateTime(2026, 9, 30).toIso8601String(),
      firmId: firmId,
    );

    await expectLater(
      db.paymentRepositoryFor(firmId).markChequeCleared(
            payment.id,
            date: DateTime(2026, 9, 5),
          ),
      throwsA(isA<Exception>()),
    );
  });
}
