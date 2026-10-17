import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/services/bank_reconciliation.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('CSV preserves quoted narration, signs and dates', () {
    final rows = parseBankCsv(
      'Date,Narration,Debit,Credit,UTR\r\n15/10/2026,"NEFT, Keystone",,1200,R1\r\n16-Oct-2026,KEY,500,,R2',
    );
    expect(rows[0].description, 'NEFT, Keystone');
    expect(rows[0].amount, 1200);
    expect(rows[1].amount, -500);
    expect(rows[1].date, DateTime(2026, 10, 16));
    expect(
      () => parseBankCsv('Date,Narration,Debit,Credit\n31/02/2026,KEY,,100'),
      throwsFormatException,
    );
    expect(
      () => parseBankCsv('Date,Narration,Debit,Credit\n15/10/2026,KEY,50,100'),
      throwsFormatException,
    );
  });
  test(
    'Key needs a confirmed alias; Keystone is a suggestion, not a posting',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      final r = BankReconciler(db, 'f');
      final doc = BankCandidate(
        id: 'i',
        number: 'INV-1',
        party: 'M/s Keystone Infra Pvt Ltd',
        partyId: 'p',
        balance: 1000,
        date: DateTime(2026, 10, 1),
        incoming: true,
      );
      final key = BankStatementRow(
        DateTime(2026, 10, 15),
        'NEFT KEY',
        1000,
        '',
      );
      expect(r.suggest(key, [doc]).single.reason, 'exact amount');
      expect(
        r.suggest(key, [doc], aliases: {'key': 'p'}).single.reason,
        contains('confirmed alias'),
      );
      final full = BankStatementRow(key.date, 'NEFT Keystone', 1000, '');
      expect(r.suggest(full, [doc]).single.reason, contains('name fragment'));
      expect(await db.select(db.payments).get(), isEmpty);
    },
  );
  test(
    'confirmed payment settles once and repeated import is idempotent',
    () async {
      final db = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db.close);
      final firm = (await db.firmRepository.create(name: 'Books')).id;
      final now = DateTime.now();
      await db
          .into(db.bankAccounts)
          .insert(
            BankAccountsCompanion.insert(
              id: 'bank',
              firmId: firm,
              name: 'Main bank',
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
      await db
          .salesRepositoryFor(firm)
          .save(
            SalesDraft(
              id: 'i',
              number: 'INV-1',
              docType: 'invoice',
              invoiceDate: DateTime(2026, 10, 1),
              lines: [
                SalesLineDraft(
                  id: 'l',
                  name: 'Camera',
                  quantity: Decimal.one,
                  unit: 'pcs',
                  rate: Decimal.fromInt(1000),
                  gstRate: 0,
                ),
              ],
            ),
          );
      final r = BankReconciler(db, firm);
      final doc = (await r.documents()).single;
      final row = BankStatementRow(
        DateTime(2026, 10, 15),
        'Keystone',
        1000,
        'R1',
      );
      expect(
        (await db.salesRepositoryFor(firm).getById('i'))!.balanceDue,
        1000,
      );
      expect(await r.confirm({row: doc}, 'bank'), 1);
      expect((await db.salesRepositoryFor(firm).getById('i'))!.balanceDue, 0);
      expect(await r.confirm({row: doc}, 'bank'), 0);
      expect(await db.select(db.payments).get(), hasLength(1));
    },
  );
  test('overpayment rejects atomically without changing balances', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(db.close);
    final firm = (await db.firmRepository.create(name: 'Books')).id;
    await db
        .salesRepositoryFor(firm)
        .save(
          SalesDraft(
            id: 'i',
            number: 'I',
            docType: 'invoice',
            invoiceDate: DateTime(2026, 10, 1),
            lines: [
              SalesLineDraft(
                id: 'l',
                name: 'Camera',
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 0,
              ),
            ],
          ),
        );
    final r = BankReconciler(db, firm),
        row = BankStatementRow(DateTime(2026, 10, 15), 'Key', 200, 'R2');
    await expectLater(
      r.confirm({row: (await r.documents()).single}, 'bank'),
      throwsStateError,
    );
    expect(await db.select(db.payments).get(), isEmpty);
  });
}
