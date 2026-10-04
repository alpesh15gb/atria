import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/shared/widgets/item_type_ahead.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cover for the catalogue/stock fixes whose failures were SILENT.
///
///  * A10 — the document line picker matched on the item NAME only, so an EAN-13
///    scanned into an invoice line matched nothing, the "Save item" row was
///    offered above the product the code belongs to, and committing it created a
///    real catalogue item literally named "8901234567890".
///  * B10 — `PartyRepository.outstandingFor`'s unlinked-payments query was the
///    only query in that method that did not filter `isDeleted`, so a BINNED
///    advance kept reducing the party's outstanding for the life of the bin.
void main() {
  const rice = ItemSuggestion(
    name: 'Basmati Rice 1 kg',
    salePrice: 120,
    unit: 'kg',
    sku: 'RICE-001',
    hsn: '10063000',
    barcode: '8901234567890',
  );

  group('item type-ahead identifier matching', () {
    test('a scanned barcode matches the item it belongs to', () {
      expect(itemSuggestionMatches(rice, '8901234567890'), isTrue);
      expect(itemSuggestionExactMatch(rice, '8901234567890'), isTrue);
    });

    test('a scanned barcode is matched whole, never as a fragment', () {
      // A substring test here would light up half the catalogue on "89012".
      expect(itemSuggestionMatches(rice, '89012'), isFalse);
      expect(itemSuggestionExactMatch(rice, '89012'), isFalse);
    });

    test('leading or trailing whitespace from a scan still resolves', () {
      expect(itemSuggestionMatches(rice, '  8901234567890 '), isTrue);
      expect(itemSuggestionExactMatch(rice, ' 8901234567890\n'), isTrue);
    });

    test('SKU and HSN resolve too, case-insensitively', () {
      expect(itemSuggestionExactMatch(rice, 'rice-001'), isTrue);
      expect(itemSuggestionExactMatch(rice, '10063000'), isTrue);
      expect(itemSuggestionMatches(rice, 'rice'), isTrue);
    });

    test('the name still matches by substring, as a type-ahead needs', () {
      expect(itemSuggestionMatches(rice, 'basmati'), isTrue);
      // …but a partial name is NOT an exact hit, which is what lets a genuinely
      // new name still offer the "Save item" row.
      expect(itemSuggestionExactMatch(rice, 'basmati'), isFalse);
    });

    test('an unknown value matches nothing — it must stay creatable', () {
      expect(itemSuggestionMatches(rice, 'kkskks'), isFalse);
      expect(itemSuggestionExactMatch(rice, 'kkskks'), isFalse);
    });

    test('rows with no identifiers degrade to name matching, not to nothing',
        () {
      const bare = ItemSuggestion(name: 'Steel Rod 12mm', salePrice: 250);
      expect(itemSuggestionMatches(bare, 'steel'), isTrue);
      expect(itemSuggestionExactMatch(bare, 'Steel Rod 12mm'), isTrue);
      expect(itemSuggestionMatches(bare, '8901234567890'), isFalse);
    });

    test('a blank query never matches', () {
      expect(itemSuggestionMatches(rice, ''), isFalse);
      expect(itemSuggestionMatches(rice, '   '), isFalse);
      expect(itemSuggestionExactMatch(rice, ''), isFalse);
    });
  });

  group('outstandingFor ignores binned payments', () {
    late AppDatabase db;
    late String firmId;

    setUp(() async {
      db = AppDatabase.test(NativeDatabase.memory());
      final firm = await db.firmRepository.create(
        name: 'Atria Enterprise',
        stateCode: '24',
        gstin: '24AABCA1234A1Z5',
      );
      firmId = firm.id;
    });

    tearDown(() => db.close());

    test('a binned advance stops reducing outstanding, and restoring it '
        'brings the reduction back', () async {
      final parties = db.partyRepositoryFor(firmId);
      final payments = db.paymentRepositoryFor(firmId);
      final party = await parties.create(
        name: 'Ramesh Stores',
        type: 'customer',
        openingBalance: 5000,
        openingBalanceType: 'dr',
      );
      expect(await parties.outstandingFor(party.id), 5000.0);

      // An unlinked advance — exactly the row the query reads.
      final advance = await payments.create(
        type: 'payment_in',
        number: 'PAY-ADVANCE',
        partyId: party.id,
        partyName: party.name,
        amount: 2000,
        date: DateTime(2026, 4, 2),
      );
      expect(await parties.outstandingFor(party.id), 3000.0);

      // The contract at payment_repository.dart:208-211 — binning it must stop
      // it counting the moment it is binned.
      await payments.softDelete(advance.id);
      expect(await parties.outstandingFor(party.id), 5000.0);

      await payments.restore(advance.id);
      expect(await parties.outstandingFor(party.id), 3000.0);
    });
  });
}
