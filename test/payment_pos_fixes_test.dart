import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/payment_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two silent invariants a payment edit and a cheque tap can both break.
///
/// **B23 — the mode edit.** `PaymentRepository.update` used to write
/// `chequeStatus` straight back from the row it was handed, whatever the new
/// mode was. So cheque→cash left a `pending` behind: the row counted as an
/// uncleared cheque AND as cash, and the cheque menu — gated on
/// `mode == 'cheque'` — could no longer reach it. cash→cheque left the status
/// null, so the new cheque never entered `watchUnclearedCheques()` and had no
/// deposit/clear/bounce lifecycle to act on. Both directions are silent and
/// both put the two lists (Cheques to deposit vs the payment list) out of step
/// with the books.
///
/// **B24 — the lifecycle.** The guard on the three `markCheque*` actions used
/// to be nothing but `mode == 'cheque'`, and the menu offered `clear` and
/// `bounce` from every state. So a settled cheque could be reversed by a second
/// tap: `cleared → bounced` re-opens an invoice whose money was already spent,
/// and `bounced → cleared` books money that never arrived *and* wipes the bounce
/// reason so the correction looks like it was never made.
void main() {
  late AppDatabase db;
  late String firmId;
  late PaymentRepository payments;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Apex Traders')).id;
    payments = db.paymentRepositoryFor(firmId);
  });

  tearDown(() => db.close());

  Future<PaymentEntity> receipt({
    required String mode,
    double amount = 5000,
    String number = 'R-1',
  }) => payments.create(
    type: 'payment_in',
    number: number,
    partyName: 'Ramesh Textiles',
    amount: amount,
    date: DateTime(2026, 9, 2),
    mode: mode,
  );

  // ---- B23: the mode decides whether there is a cheque lifecycle ----------

  test('cheque → cash drops the lifecycle, and the buckets agree again',
      () async {
    final cheque = await receipt(mode: 'cheque');
    expect(cheque.chequeStatus, 'pending');
    expect(
      (await payments.watchUnclearedCheques().first).map((p) => p.id),
      contains(cheque.id),
      reason: 'a cheque in hand is in the bucket the operator works through',
    );

    await payments.update(cheque.copyWith(mode: 'cash'));
    final now = (await payments.getById(cheque.id))!;

    expect(now.mode, 'cash');
    expect(now.chequeStatus, isNull,
        reason: 'a cash payment cannot be sitting in "Cheques to deposit"');
    expect(now.depositedAt, isNull);
    expect(now.bouncedAt, isNull);
    expect(now.bounceReason, isNull);
    expect(now.clearanceDate, isNull);
    expect(await payments.watchUnclearedCheques().first, isEmpty);
  });

  test('cash → cheque starts the lifecycle instead of orphaning the row',
      () async {
    final cash = await receipt(mode: 'cash');
    expect(cash.chequeStatus, isNull);

    await payments.update(cash.copyWith(mode: 'cheque'));
    final now = (await payments.getById(cash.id))!;

    expect(now.chequeStatus, 'pending',
        reason: 'without this the cheque never enters watchUnclearedCheques '
            'and nothing can ever deposit, clear or bounce it');
    expect(
      (await payments.watchUnclearedCheques().first).map((p) => p.id),
      contains(now.id),
    );
  });

  test('editing anything else keeps the cheque exactly where it had got to',
      () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeDeposited(cheque.id);
    final deposited = (await payments.getById(cheque.id))!;
    expect(deposited.chequeStatus, 'deposited');

    // Fixing a typo in the reference is not a lifecycle event.
    await payments.update(deposited.copyWith(reference: Value('004512')));
    final now = (await payments.getById(cheque.id))!;

    expect(now.chequeStatus, 'deposited');
    expect(now.depositedAt, deposited.depositedAt);
    expect(now.reference, '004512');
  });

  test('cheque → cash → cheque starts again rather than resuming a bounce',
      () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeBounced(cheque.id, reason: 'Insufficient funds');
    expect((await payments.getById(cheque.id))!.bounceReason,
        'Insufficient funds');

    await payments.update(cheque.copyWith(mode: 'cash'));
    await payments.update((await payments.getById(cheque.id))!.copyWith(
      mode: 'cheque',
    ));
    final now = (await payments.getById(cheque.id))!;

    expect(now.chequeStatus, 'pending');
    expect(now.bounceReason, isNull,
        reason: 'the bounce described a cheque this row no longer is; keeping '
            'it would leave a stale reversal on a live row');
    expect(now.bouncedAt, isNull);
  });

  // ---- B24: the transitions that are legal, and the ones that are not ----

  test('the legal transition table is what the lifecycle can actually do',
      () async {
    // Read straight off the public accessor the menu offers from.
    expect(PaymentRepository.legalChequeTransitionsFrom('pending'),
        {'pending', 'deposited', 'cleared', 'bounced'});
    expect(PaymentRepository.legalChequeTransitionsFrom('deposited'),
        {'deposited', 'cleared', 'bounced'});
    expect(PaymentRepository.legalChequeTransitionsFrom('cleared'), {'cleared'});
    expect(PaymentRepository.legalChequeTransitionsFrom('bounced'),
        {'deposited'});
    // A cheque row written before the status was seeded counts as in hand.
    expect(PaymentRepository.legalChequeTransitionsFrom(null),
        PaymentRepository.legalChequeTransitionsFrom('pending'));
  });

  test('a settled cheque cannot be bounced by a second tap', () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeCleared(cheque.id);

    await expectLater(
      payments.markChequeBounced(cheque.id, reason: 'Too late'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('already cleared'),
        ),
      ),
      reason: 'the money is in the bank and has been spent; a later reversal '
          'has to be an edit, not a lifecycle step',
    );

    final now = (await payments.getById(cheque.id))!;
    expect(now.chequeStatus, 'cleared',
        reason: 'a refused transition must leave the row untouched');
    expect(now.bounceReason, isNull);
  });

  test('a returned cheque cannot be cleared — that books money never received',
      () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeBounced(cheque.id, reason: 'Signature mismatch');

    await expectLater(
      payments.markChequeCleared(cheque.id),
      throwsA(isA<StateError>()),
    );
    final now = (await payments.getById(cheque.id))!;
    expect(now.chequeStatus, 'bounced');
    expect(now.bounceReason, 'Signature mismatch',
        reason: 'the second tap must not erase the reason for the first');
  });

  test('a returned cheque can only be deposited again, and that settles the '
      'document once more', () async {
    final sales = db.salesRepositoryFor(firmId);
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
    final cheque = await payments.create(
      type: 'payment_in',
      number: 'R-2',
      partyName: 'Ramesh Textiles',
      amount: 10000,
      date: DateTime(2026, 9, 2),
      mode: 'cheque',
      linkedInvoiceId: 'inv-1',
    );
    await sales.applyPayment(invoiceId: 'inv-1', amount: 10000);

    await payments.markChequeBounced(cheque.id, reason: 'Funds not clear');
    expect((await sales.getById('inv-1'))!.paymentStatus, 'unpaid');

    await payments.markChequeDeposited(cheque.id);
    expect((await payments.getById(cheque.id))!.chequeStatus, 'deposited');
    expect((await sales.getById('inv-1'))!.paymentStatus, 'paid');
  });

  test('a cleared cheque cannot be pushed back into the uncleared bucket',
      () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeCleared(cheque.id);

    await expectLater(
      payments.markChequeDeposited(cheque.id),
      throwsA(isA<StateError>()),
    );
    expect((await payments.getById(cheque.id))!.chequeStatus, 'cleared');
    expect(await payments.watchUnclearedCheques().first, isEmpty);
  });

  test('bouncing the same cheque twice is refused, not re-stamped', () async {
    final cheque = await receipt(mode: 'cheque');
    await payments.markChequeBounced(cheque.id, reason: 'Insufficient funds');

    await expectLater(
      payments.markChequeBounced(cheque.id, reason: 'Second attempt'),
      throwsA(isA<StateError>()),
    );
    expect((await payments.getById(cheque.id))!.bounceReason,
        'Insufficient funds');
  });

  test('money that is not a cheque has no lifecycle to move', () async {
    final cash = await receipt(mode: 'cash');
    for (final move in [
      () => payments.markChequeDeposited(cash.id),
      () => payments.markChequeCleared(cash.id),
      () => payments.markChequeBounced(cash.id, reason: 'x'),
    ]) {
      await expectLater(move(), throwsA(isA<StateError>()));
    }
  });
}