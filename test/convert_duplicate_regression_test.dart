import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/ledger_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Convert and Duplicate copy the same rows; they differ entirely in what
/// happens to the **original**. These four bugs all came from sharing one code
/// path between the two, and all of them were silent or total:
///
///  1. Convert carried the source's **line row ids** into a new document.
///     `sales_invoice_items.id` is the sole primary key and `save` inserts lines
///     with a plain `.insert`, so that is `UNIQUE constraint failed` — the whole
///     transaction rolls back and converting a quotation failed **every time**.
///  2. Duplicate went down the convert path, so copying an already-issued
///     invoice stamped `convertedToInvoiceId` on the original and flipped its
///     status to Converted.
///  3. `_ensureCategoryAccount` read *active* accounts to pick a free code,
///     while `uq_accounts_code` is on `(firmId, code)` regardless of
///     `isActive`. Archiving an expense account therefore wedged
///     `ensureChart()` — and with it the Trial Balance, the Balance Sheet and
///     `cashBankBalancesProvider` — with a UNIQUE violation.
///  4. `_book` posted party opening balances with no `asOf` bound and while
///     filtering `isDeleted`, so a past-dated trial balance booked parties that
///     did not exist yet, and binning a customer dropped both halves of their
///     opening from the books while their statement kept it.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    firmId = (await db.firmRepository.create(name: 'Apex Traders')).id;
  });

  tearDown(() => db.close());

  group('converting a document', () {
    test('conversion is atomic and a stale second editor cannot create another invoice', () async {
      final sales = db.salesRepositoryFor(firmId);
      SalesDraft draft(String id, String type) => SalesDraft(
        id: id,
        number: id,
        docType: type,
        invoiceDate: DateTime(2026, 10, 9),
        lines: [
          SalesLineDraft(
            id: 'line-$id',
            name: 'Camera',
            quantity: Decimal.one,
            unit: 'pcs',
            rate: Decimal.fromInt(1000),
            gstRate: 0,
          ),
        ],
      );
      await sales.save(draft('source', 'quotation'));
      await sales.convertToInvoice(
        draft('first', 'invoice'),
        sourceId: 'source',
      );
      expect((await sales.getById('source'))!.convertedToInvoiceId, 'first');
      await expectLater(
        sales.convertToInvoice(draft('second', 'invoice'), sourceId: 'source'),
        throwsStateError,
      );
      expect(await sales.getById('second'), isNull);
      expect(await sales.itemsFor('second'), isEmpty);
      await expectLater(
        sales.convertToInvoice(
          draft('missing', 'invoice'),
          sourceId: 'not-found',
        ),
        throwsStateError,
      );
      expect(await sales.getById('missing'), isNull);
    });
    test('a quotation converts without colliding with its own line rows', () async {
      final sales = db.salesRepositoryFor(firmId);
      await sales.save(
        SalesDraft(
          id: 'q1',
          number: 'QT-1',
          docType: 'quotation',
          invoiceDate: DateTime(2026, 9, 20),
          lines: [
            SalesLineDraft(
              id: 'line-1',
              name: 'Primer',
              quantity: Decimal.fromInt(2),
              unit: 'ltr',
              rate: Decimal.parse('250'),
              gstRate: 18,
            ),
          ],
        ),
      );

      // What the editor does on a convert: read the source's lines, then save a
      // NEW document carrying them. Reusing `line-1` throws here.
      final sourceLines = await sales.itemsFor('q1');
      await sales.save(
        SalesDraft(
          id: 'inv-1',
          number: 'INV-1',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 26),
          lines: [
            for (final l in sourceLines)
              SalesLineDraft(
                id: 'inv-line-${l.id}', // minted, not reused
                name: l.name,
                quantity: Decimal.parse(l.quantity.toString()),
                unit: l.unit,
                rate: Decimal.parse(l.rate.toStringAsFixed(2)),
                gstRate: l.gstRate,
              ),
          ],
        ),
      );

      expect(await sales.itemsFor('inv-1'), hasLength(1));
      expect(
        await sales.itemsFor('q1'),
        hasLength(1),
        reason: 'the quotation keeps its own line rows',
      );
    });

    test('marking a source converted does not touch the copy', () async {
      final sales = db.salesRepositoryFor(firmId);
      for (final d in [
        SalesDraft(
          id: 'q2',
          number: 'QT-2',
          docType: 'quotation',
          invoiceDate: DateTime(2026, 9, 20),
          lines: [
            SalesLineDraft(
              id: 'ql2',
              name: 'Primer',
              quantity: Decimal.one,
              unit: 'ltr',
              rate: Decimal.parse('250'),
              gstRate: 18,
            ),
          ],
        ),
        SalesDraft(
          id: 'inv2',
          number: 'INV-2',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 9, 26),
          lines: [
            SalesLineDraft(
              id: 'il2',
              name: 'Primer',
              quantity: Decimal.one,
              unit: 'ltr',
              rate: Decimal.parse('250'),
              gstRate: 18,
            ),
          ],
        ),
      ]) {
        await sales.save(d);
      }

      await sales.markConverted('q2', invoiceId: 'inv2');

      expect((await sales.getById('q2'))!.convertedToInvoiceId, 'inv2');
      expect(
        (await sales.getById('inv2'))!.convertedToInvoiceId,
        isNull,
        reason: 'the invoice is the thing that exists; nothing converted it',
      );
    });
  });

  group('the account cache', () {
    test('archiving an expense account does not wedge ensureChart', () async {
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();

      // Record an expense, which auto-creates its category account.
      await db
          .expenseRepositoryFor(firmId)
          .create(
            type: 'expense',
            number: 'EXP-1',
            category: 'rent',
            amount: 12000,
            date: DateTime(2026, 9, 1),
            mode: 'cash',
          );
      await ledger.ensureChart();

      final rent = (await ledger.allAccounts()).firstWhere(
        (a) => a.name.toLowerCase() == 'rent',
      );
      await ledger.setAccountActive(rent.id, false);

      // The archive must not have freed the code. `ensureChart` runs at the top
      // of trialBalance, so a throw here takes the Trial Balance down too.
      await ledger.ensureChart();
      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));

      final after = await ledger.allAccounts(includeInactive: true);
      expect(
        after.where((a) => a.code == rent.code),
        hasLength(1),
        reason: 'the code is still owned by the archived account',
      );
      expect(tb.isBalanced, isTrue);
    });
  });

  group('party openings in the ledger', () {
    Future<void> addParty({
      required String id,
      required String name,
      required double opening,
      required DateTime createdAt,
    }) async {
      await db
          .into(db.parties)
          .insert(
            PartiesCompanion.insert(
              id: id,
              firmId: firmId,
              name: name,
              type: 'customer',
              openingBalance: Value(opening),
              createdAt: Value(createdAt),
            ),
          );
    }

    /// Zero when the account carries no row at all — a trial balance for a date
    /// before anything happened legitimately has no debtors line.
    double closingFor(TrialBalance tb, String code) {
      for (final r in tb.rows) {
        if (r.account.code == code) return r.closing;
      }
      return 0;
    }

    test('a party created after the period is not in that period', () async {
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      await addParty(
        id: 'pt-new',
        name: 'Late Customer',
        opening: 50000,
        createdAt: DateTime(2026, 9, 9),
      );

      // The opening did not exist on 31 March, so debtors must not carry it.
      final asOfMarch = await ledger.trialBalance(asOf: DateTime(2026, 3, 31));
      expect(closingFor(asOfMarch, LedgerCodes.debtors), 0);

      final now = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(closingFor(now, LedgerCodes.debtors), 50000);
      expect(now.isBalanced, isTrue);
    });

    test('a binned party keeps their opening in the books', () async {
      final ledger = db.ledgerRepositoryFor(firmId);
      await ledger.ensureChart();
      await addParty(
        id: 'pt-binned',
        name: 'Binned Customer',
        opening: 40000,
        createdAt: DateTime(2026, 1, 5),
      );

      await (db.update(db.parties)..where((t) => t.id.equals('pt-binned')))
          .write(const PartiesCompanion(isDeleted: Value(true)));

      final tb = await ledger.trialBalance(asOf: DateTime(2026, 9, 30));
      expect(
        closingFor(tb, LedgerCodes.debtors),
        40000,
        reason:
            'the recycle bin is a UI state, not an accounting one — '
            'the statement still shows this party owing ₹40,000',
      );
      expect(tb.isBalanced, isTrue);
    });
  });
}
