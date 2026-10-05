import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/sources/business_status/bank_statement.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// **Bank Statement** — the one report whose answer depends on an opening
/// balance.
///
/// The fixtures are built so that an opening balance assumed to be zero
/// produces a **wrong number on every row** rather than a missing row, because
/// that is the failure this report actually has: a period that starts long after
/// the account did, with money already in it.
///
/// The other claims worth a test are that cash in hand appears beside the bank
/// accounts, that an uncleared cheque is not money, and that an account with no
/// movement still appears.
void main() {
  late AppDatabase db;
  late String firmId;

  /// A window that starts well after the account was opened, so anything
  /// already in the account at 1 April is invisible inside it.
  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(
      name: 'Apex Traders',
      stateCode: '29',
    ))
        .id;
  });

  tearDown(() => db.close());

  /// An account whose `currentBalance` is [balance] **after** everything the
  /// period did.
  ///
  /// That is what the column holds: a cache of the balance from the payment and
  /// journal ledger, so it already includes the period's movements. The report
  /// therefore walks *back* from it to find the opening figure — a fixture that
  /// set it to the opening would be asserting the report adds the period's
  /// movements on top of money that already contains them, which is the bug
  /// this report has to avoid rather than have.
  Future<String> account(
    String name, {
    String type = 'bank',
    double balance = 0,
  }) async {
    final id = 'acc-${name.toLowerCase().replaceAll(' ', '-')}';
    await db.into(db.bankAccounts).insert(BankAccountsCompanion.insert(
      id: id,
      firmId: firmId,
      name: name,
      type: Value(type),
      currentBalance: Value(balance),
    ));
    return id;
  }

  /// A payment posted to [accountId].
  ///
  /// Written straight to the table: `PaymentRepository.create` takes the
  /// free-text `bankAccount` and does not set the `bankAccountId` the report
  /// keys on, and a fixture that went through the repository would silently
  /// produce an account with no movements.
  Future<void> payment({
    required String accountId,
    required String type,
    required double amount,
    required DateTime date,
    String? partyName,
    String reference = '',
    String? chequeStatus,
  }) async {
    await db.into(db.payments).insert(PaymentsCompanion.insert(
      id: 'pay-$accountId-$date-${type.hashCode.abs()}',
      firmId: firmId,
      type: type,
      number: 'P${date.day}${type == 'payment_in' ? 'R' : 'P'}',
      amount: amount,
      date: date,
      partyName: Value(partyName),
      reference: Value(reference),
      bankAccountId: Value(accountId),
      chequeStatus: Value(chequeStatus),
    ));
  }

  Future<List<ReportRow>> rowsFor({String? accountId}) =>
      bankStatement.source.build(
        db,
        firmId,
        window,
        accountId == null ? const {} : {kBankFilterId: accountId},
      );

  Decimal value(ReportRow row, String key) =>
      row.number(bankStatement.spec.columns.firstWhere((c) => c.key == key));

  String text(ReportRow row, String key) =>
      row.text(bankStatement.spec.columns.firstWhere((c) => c.key == key));

  group('opening balance', () {
    test('the first row is right when the account already held money',
        () async {
      // The defect this whole report turns on. `currentBalance` is 15,000 — what
      // the account holds *now*, the opening 10,000 plus this receipt. A
      // statement that walked forward from that figure would print 20,000, and
      // one that opened at zero would print 5,000.
      final id = await account('HDFC main', balance: 15000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
      );

      final rows = await rowsFor();
      expect(rows, hasLength(1));
      expect(value(rows.single, 'balance'), Decimal.fromInt(15000));
    });

    test('a payment out is measured from the same opening', () async {
      final id = await account('HDFC main', balance: 7500);
      await payment(
        accountId: id,
        type: 'payment_out',
        amount: 2500,
        date: DateTime(2026, 5, 2),
        partyName: 'Cement Traders',
      );

      expect(value((await rowsFor()).single, 'balance'), Decimal.fromInt(7500));
    });

    test('the balance walks forward through the whole period', () async {
      // 1,000 opening, +2,000, -500, +700 = 3,200 now.
      final id = await account('HDFC main', balance: 3200);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 2000,
        date: DateTime(2026, 4, 10),
        partyName: 'Ramu',
      );
      await payment(
        accountId: id,
        type: 'payment_out',
        amount: 500,
        date: DateTime(2026, 5, 11),
        partyName: 'Rent',
      );
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 700,
        date: DateTime(2026, 6, 12),
        partyName: 'Sita',
      );

      final rows = await rowsFor();
      expect(rows, hasLength(3));
      // 1,000 opening, +2,000, -500, +700.
      expect(value(rows[0], 'balance'), Decimal.fromInt(3000));
      expect(value(rows[1], 'balance'), Decimal.fromInt(2500));
      expect(value(rows[2], 'balance'), Decimal.fromInt(3200));
    });

    test('the last balance is the account\'s own current balance', () async {
      // The invariant that makes the opening derivation correct rather than
      // merely plausible: whatever moved in the period is already inside
      // `currentBalance`, so walking back from it must reproduce the opening.
      final id = await account('HDFC main', balance: 15000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
      );

      final rows = await rowsFor();
      expect(value(rows.last, 'balance'), Decimal.fromInt(15000));
    });

    test('a payment before the window is not in the statement', () async {
      final id = await account('HDFC main', balance: 100100);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 99999,
        date: DateTime(2026, 1, 5),
        partyName: 'Last year',
      );
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 100,
        date: DateTime(2026, 5, 5),
        partyName: 'This year',
      );

      final rows = await rowsFor();
      expect(rows, hasLength(1));
      expect(text(rows.single, 'particulars'), contains('This year'));
    });
  });

  group('cash is an account', () {
    test('cash in hand is listed beside the bank accounts', () async {
      // `BankAccounts.type` includes `cash` for exactly this: the only honest
      // way to show it in a statement of accounts is as an account.
      final cash = await account('Cash in hand', type: 'cash', balance: 2500);
      await payment(
        accountId: cash,
        type: 'payment_in',
        amount: 500,
        date: DateTime(2026, 5, 3),
        partyName: 'Counter sale',
      );
      await account('HDFC main', balance: 0);

      final rows = await rowsFor();
      final accounts = rows.map((r) => text(r, 'account')).toSet();
      expect(accounts, containsAll(['Cash in hand', 'HDFC main']));
    });

    test('an account with no movement still appears, with its balance',
        () async {
      // A statement of accounts that omits the account nobody used is not a
      // statement of accounts, and there is nothing to check a balance against.
      await account('HDFC main', balance: 0);
      await account('ICICI savings', balance: 42000);

      final rows = await rowsFor();
      expect(rows, hasLength(2));
      final untouched =
          rows.firstWhere((r) => text(r, 'account') == 'ICICI savings');
      expect(value(untouched, 'balance'), Decimal.fromInt(42000));
      expect(value(untouched, 'receipt'), Decimal.zero);
      expect(value(untouched, 'payment'), Decimal.zero);
    });
  });

  group('cheques', () {
    test('a cheque in hand is not money yet', () async {
      // It can bounce, and a statement that counts it shows a balance the firm
      // does not have.
      final id = await account('HDFC main', balance: 1000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
        chequeStatus: 'pending',
      );

      final rows = await rowsFor();
      // Only the "no movement" row, at the account's balance.
      expect(rows, hasLength(1));
      expect(value(rows.single, 'balance'), Decimal.fromInt(1000));
    });

    test('a deposited cheque is still not money until it clears', () async {
      final id = await account('HDFC main', balance: 1000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
        chequeStatus: 'deposited',
      );

      expect(value((await rowsFor()).single, 'balance'), Decimal.fromInt(1000));
    });

    test('a bounced cheque is removed again', () async {
      final id = await account('HDFC main', balance: 1000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
        chequeStatus: 'bounced',
      );

      expect(value((await rowsFor()).single, 'balance'), Decimal.fromInt(1000));
    });

    test('a cleared cheque is counted', () async {
      // Cleared, so counted: 1,000 before it, 5,000 now.
      final id = await account('HDFC main', balance: 6000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Buildmart',
        chequeStatus: 'cleared',
      );

      final rows = await rowsFor();
      expect(rows, hasLength(1));
      expect(value(rows.single, 'receipt'), Decimal.fromInt(5000));
      expect(value(rows.single, 'balance'), Decimal.fromInt(6000));
    });

    test('a cash payment has no cheque status and is counted', () async {
      // `chequeStatus` is null for money that is not a cheque, and treating null
      // as "not cleared" would drop every cash receipt from the bank.
      final id = await account('HDFC main', balance: 5000);
      await payment(
        accountId: id,
        type: 'payment_in',
        amount: 5000,
        date: DateTime(2026, 5, 2),
        partyName: 'Counter sale',
      );

      final rows = await rowsFor();
      expect(rows, hasLength(1));
      expect(value(rows.single, 'balance'), Decimal.fromInt(5000));
    });
  });

  group('the account filter', () {
    test('narrows to one account', () async {
      final hdfc = await account('HDFC main', balance: 0);
      await account('ICICI savings', balance: 0);
      await payment(
        accountId: hdfc,
        type: 'payment_in',
        amount: 100,
        date: DateTime(2026, 5, 2),
      );

      final rows = await rowsFor(accountId: hdfc);
      expect(
        rows.map((r) => text(r, 'account')).toSet(),
        {'HDFC main'},
      );
    });
  });

  test('the report is registered with an account filter', () {
    expect(
      ReportCatalogue.byId('bank_statement')!.spec.hasFilters,
      isTrue,
      reason: 'a statement of every account at once is not a statement',
    );
  });
}