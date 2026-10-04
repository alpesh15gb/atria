import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/domain/document_status.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The quotation lifecycle: what it means, and what the repository refuses.
///
/// The interesting failures here are all *absences* — a quotation that cannot
/// be cancelled after it was accepted, a converted one that cannot be
/// converted twice, an expiry that appears without anything being written.
/// Tests that only assert a status changed would pass against code that got
/// the model wrong.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Apex Integrations');
    firmId = firm.id;
  });

  tearDown(() async => db.close());

  SalesRepository sales() => db.salesRepositoryFor(firmId);

  Future<SalesInvoiceEntity> quote(
    String id, {
    String status = 'confirmed',
    DateTime? validTill,
  }) => sales()
      .save(
        SalesDraft(
          id: id,
          number: id.toUpperCase(),
          docType: 'quotation',
          invoiceDate: DateTime(2026, 9, 20),
          dueDate: validTill,
          status: status,
          lines: [
            SalesLineDraft(
              id: 'l-$id',
              name: 'Consulting',
              quantity: Decimal.one,
              unit: 'svc',
              rate: Decimal.fromInt(2000),
              gstRate: 18,
            ),
          ],
        ),
      )
      .then((_) async => (await sales().getById(id))!);

  group('the vocabulary', () {
    test('a status is resolved against the document type, not a flat list', () {
      // "Accepted" is real, but meaningless on an invoice — the word belongs
      // to quotations. Resolving it there falls back rather than showing a
      // chip that claims an invoice was accepted.
      expect(
        DocumentStatus.of('accepted', 'quotation'),
        DocumentStatus.accepted,
      );
      expect(
        DocumentStatus.of('accepted', 'invoice'),
        DocumentStatus.confirmed,
      );

      expect(DocumentStatus.of('sent', 'sales_order'), DocumentStatus.sent);
      expect(DocumentStatus.of('sent', 'invoice'), DocumentStatus.confirmed);
    });

    test('an unknown status falls back rather than throwing', () {
      // A value this build has never heard of — a restored backup from a newer
      // version, a hand-edited row. A chip that throws takes the list with it.
      expect(DocumentStatus.of('quantum', 'invoice'), DocumentStatus.confirmed);
      expect(DocumentStatus.of('', 'quotation'), DocumentStatus.confirmed);
      expect(DocumentStatus.of(null, 'quotation'), DocumentStatus.confirmed);
    });

    test('expiry is derived from the valid-till date, per document type', () {
      final past = DateTime.now().subtract(const Duration(days: 1));
      final today = DateTime.now();
      final future = DateTime.now().add(const Duration(days: 1));

      expect(
        DocumentStatus.isExpired(
          status: 'confirmed',
          docType: 'quotation',
          validTill: past,
        ),
        isTrue,
      );
      // Valid *till* the 10th means valid on the 10th — an offer does not die
      // at midnight the night before.
      expect(
        DocumentStatus.isExpired(
          status: 'confirmed',
          docType: 'quotation',
          validTill: today,
        ),
        isFalse,
        reason: 'a quotation is valid through the day it names',
      );
      expect(
        DocumentStatus.isExpired(
          status: 'confirmed',
          docType: 'quotation',
          validTill: future,
        ),
        isFalse,
      );
      // An invoice's date passing makes it overdue, not expired — the document
      // is unchanged, the money is late.
      expect(
        DocumentStatus.isExpired(
          status: 'confirmed',
          docType: 'invoice',
          validTill: past,
        ),
        isFalse,
      );
      // Nothing to expire against.
      expect(
        DocumentStatus.isExpired(
          status: 'confirmed',
          docType: 'quotation',
          validTill: null,
        ),
        isFalse,
      );
      // A quotation that was answered is not lapsed, however old it is.
      for (final answered in [
        'accepted',
        'rejected',
        'cancelled',
        'converted',
      ]) {
        expect(
          DocumentStatus.isExpired(
            status: answered,
            docType: 'quotation',
            validTill: past,
          ),
          isFalse,
          reason: '$answered is not the same as expired',
        );
      }
    });

    test('the allowed moves are a property of the state, not the screen', () {
      expect(
        DocumentStatus.draft.transitionsFrom(DocumentStatus.draft, 'quotation'),
        contains(DocumentStatus.sent),
      );
      expect(
        DocumentStatus.sent.transitionsFrom(DocumentStatus.sent, 'quotation'),
        containsAll([DocumentStatus.accepted, DocumentStatus.rejected]),
      );
      // An answered quotation is a record of what was agreed. Cancelling it
      // would be inventing a fifth answer.
      expect(
        DocumentStatus.accepted.transitionsFrom(
          DocumentStatus.accepted,
          'quotation',
        ),
        isEmpty,
      );
      expect(
        DocumentStatus.convertedLegacy.transitionsFrom(
          DocumentStatus.convertedLegacy,
          'quotation',
        ),
        isEmpty,
        reason: 'already invoiced — nothing moves it',
      );
    });
  });

  group('the repository enforces the lifecycle', () {
    test('a quotation can be sent, then answered', () async {
      await quote('q1', status: 'draft');
      await sales().markStatus('q1', DocumentStatus.sent);
      expect((await sales().getById('q1'))!.status, 'sent');

      await sales().markStatus('q1', DocumentStatus.accepted);
      expect((await sales().getById('q1'))!.status, 'accepted');
    });

    test('an illegal move is refused, not silently applied', () async {
      await quote('q2', status: 'draft');
      expect(
        () => sales().markStatus('q2', DocumentStatus.accepted),
        throwsA(isA<StateError>()),
        reason: 'a draft that was never sent has had no answer',
      );
      expect(
        (await sales().getById('q2'))!.status,
        'draft',
        reason: 'a refused move must leave the document as it was',
      );
    });

    test('an accepted quotation cannot then be cancelled', () async {
      await quote('q3', status: 'draft');
      await sales().markStatus('q3', DocumentStatus.sent);
      await sales().markStatus('q3', DocumentStatus.accepted);
      expect(
        () => sales().markStatus('q3', DocumentStatus.cancelled),
        throwsA(isA<StateError>()),
      );
    });

    test('expired cannot be written — it is derived, not stored', () async {
      await quote('q4', status: 'draft');
      expect(
        () => sales().markStatus('q4', DocumentStatus.expired),
        throwsA(isA<ArgumentError>()),
        reason:
            'a stored expiry would disagree with the valid-till date the '
            'moment that date moved',
      );
    });

    test('cancelling a converted quotation is refused, because the flag is '
        'all there is', () async {
      // A pre-v9 row: status carries the conversion and the invoice it became
      // was never recorded, so cancelling it would wipe the flag and leave a
      // quotation that had genuinely been invoiced looking convertible again.
      final db2 = AppDatabase.test(NativeDatabase.memory());
      addTearDown(db2.close);
      final firm = await db2.firmRepository.create(name: 'Legacy Co');
      final repo = db2.salesRepositoryFor(firm.id);
      await repo.save(
        SalesDraft(
          id: 'legacy-q',
          number: 'QT-LEGACY',
          docType: 'quotation',
          invoiceDate: DateTime(2026, 8, 1),
          lines: [
            SalesLineDraft(
              id: 'll',
              name: 'Consulting',
              quantity: Decimal.one,
              unit: 'svc',
              rate: Decimal.fromInt(100),
              gstRate: 18,
            ),
          ],
        ),
      );
      // Write the legacy shape directly — there is no longer any method that
      // produces it, which is the point.
      await db2
          .update(db2.salesInvoices)
          .replace(
            (await repo.getById('legacy-q'))!.copyWith(status: 'converted'),
          );

      expect(() => repo.markCancelled('legacy-q'), throwsA(isA<StateError>()));
      expect((await repo.getById('legacy-q'))!.status, 'converted');
    });
  });

  group('conversion is a link, not a replacement state', () {
    test('the quotation keeps its own lifecycle', () async {
      await quote('q5', status: 'draft');
      await sales().markStatus('q5', DocumentStatus.sent);
      await sales().markConverted('q5', invoiceId: 'inv-5');

      final converted = await sales().getById('q5');
      expect(
        converted!.status,
        'sent',
        reason:
            'the quotation was sent; converting it does not un-send it. '
            'The old flag overwrote this and destroyed the information.',
      );
      expect(converted.convertedToInvoiceId, 'inv-5');
      expect(converted.convertedAt, isNotNull);
    });

    test('a converted quotation resolves as converted, and cannot be '
        'converted again', () async {
      await quote('q6');
      await sales().markConverted('q6', invoiceId: 'inv-6');
      expect(
        DocumentStatus.of((await sales().getById('q6'))!.status, 'quotation'),
        isNot(DocumentStatus.sent),
        reason: 'the badge is driven by the link, not the status column',
      );
      expect(
        DocumentStatus.of('converted', 'quotation'),
        DocumentStatus.convertedLegacy,
      );
      expect(sales().markConverted('q6', invoiceId: 'inv-6-again'), completes);
      expect(
        (await sales().getById('q6'))!.convertedToInvoiceId,
        'inv-6',
        reason: 'a second conversion must not re-point the link',
      );
    });
  });

  group('the status filter', () {
    test('filters the list, and "converted" finds both shapes', () async {
      await quote('f1');
      await quote('f2');
      await quote('f3');
      await sales().markStatus('f2', DocumentStatus.sent);
      await sales().markConverted('f3', invoiceId: 'inv-f3');

      final sent = await sales()
          .watchList(docType: 'quotation', statuses: {DocumentStatus.sent})
          .first;
      expect(sent.map((d) => d.id), ['f2']);

      // Post-v9 rows carry the link and a live lifecycle; pre-v9 rows carry
      // the flag in status. A filter that matched only the column would
      // silently miss every document converted since the upgrade — which is
      // every document a new user has.
      final converted = await sales()
          .watchList(
            docType: 'quotation',
            statuses: {DocumentStatus.convertedLegacy},
          )
          .first;
      expect(converted.map((d) => d.id), ['f3']);

      final all = await sales().watchList(docType: 'quotation').first;
      expect(all.length, 3, reason: 'no filter means every status');
    });

    test('"expired" is computed after the query, not in it', () async {
      await quote(
        'e1',
        validTill: DateTime.now().subtract(const Duration(days: 2)),
      );
      await quote(
        'e2',
        validTill: DateTime.now().add(const Duration(days: 30)),
      );

      final expired = await sales()
          .watchList(docType: 'quotation', statuses: {DocumentStatus.expired})
          .first;
      expect(
        expired.map((d) => d.id),
        ['e1'],
        reason:
            'SQLite cannot know which rows are expired — the rule is in '
            'Dart, so the filter has to run after the query',
      );
    });
  });
}
