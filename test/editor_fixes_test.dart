import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/sync/scan_seed.dart';
import 'package:atria/features/purchase/bill_scan_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic cover for the fixes that were silent money/stock bugs rather
/// than layout ones:
///
/// * [DocumentSettlement] — the single derivation of (balance, paymentStatus)
///   every write path now shares. A bill edited below what was paid used to
///   store a negative payable beside a 'paid' status.
/// * [matchScannedItem] — resolving a scanned bill line to a catalogue item, so
///   the quantity actually moves stock (and refusing to guess when two items
///   answer the same key).
/// * [ScannedReviewState] — lines addressed by a stable id, so removing line 0
///   cannot leave line 1's numbers sitting on line 0's state.
void main() {
  group('DocumentSettlement', () {
    test('an unpaid document owes its whole value', () {
      final s = DocumentSettlement.of(grandTotal: 10000, paidAmount: 0);
      expect(s.balance, 10000);
      expect(s.status, 'unpaid');
      expect(s.overpaid, isFalse);
    });

    test('a part payment leaves the remainder and reads partial', () {
      final s = DocumentSettlement.of(grandTotal: 1000, paidAmount: 400);
      expect(s.balance, 600);
      expect(s.status, 'partial');
      expect(s.overpaid, isFalse);
    });

    test('editing below what was paid clamps at zero, never negative', () {
      // The A14 repro: pay ₹10,000 in full, then delete a ₹3,000 line.
      final s = DocumentSettlement.of(grandTotal: 7000, paidAmount: 10000);
      expect(s.balance, 0, reason: 'a document cannot owe a negative amount');
      expect(s.status, 'paid');
      expect(
        s.overpaid,
        isTrue,
        reason:
            'the payments ledger records more than the bill is worth, and '
            'the user has to be told',
      );
    });

    test('a sub-paisa residue is settled, not an unpaid balance', () {
      final s = DocumentSettlement.of(grandTotal: 1000, paidAmount: 1000.0005);
      expect(s.status, 'paid');
      expect(s.overpaid, isFalse);
    });

    test('a document that carries no balance agrees with its own status', () {
      // Purchase orders and debit notes store a ₹0 balance; the status used to
      // be derived from the unclamped difference, so they read "Unpaid".
      expect(DocumentSettlement.settled.balance, 0);
      expect(DocumentSettlement.settled.status, 'paid');
      expect(DocumentSettlement.settled.overpaid, isFalse);
    });
  });

  group('matchScannedItem', () {
    ItemEntity item(
      String id,
      String name, {
      String? sku,
      String? hsn,
      String? barcode,
    }) => ItemEntity(
      id: id,
      firmId: 'firm-1',
      name: name,
      sku: sku,
      hsn: hsn,
      barcode: barcode,
      unit: 'pcs',
      costingMethod: 'moving_average',
      salePrice: 100,
      purchasePrice: 80,
      gstRate: 18,
      cessRate: 0,
      taxMode: 'exclusive',
      isService: false,
      stockType: 'tracked',
      openingStock: 0,
      currentStock: 0,
      lowStockAlert: 0,
      isDeleted: false,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    ScannedLineSeed line(String name, {String? hsn}) => ScannedLineSeed(
      name: name,
      hsn: hsn,
      quantity: 2,
      rate: 50,
      gstRate: 18,
      cessRate: 0,
    );

    final catalogue = [
      item('i1', 'Surf Excel 1kg', sku: 'SE-1', hsn: '3402'),
      item('i2', 'Biscuit Amira', sku: 'BA-9', hsn: '1905'),
    ];

    test('matches a name that differs only by case and spacing', () {
      expect(matchScannedItem(catalogue, line('  surf excel 1KG '))?.id, 'i1');
    });

    test('matches on SKU when the description is not the name', () {
      expect(matchScannedItem(catalogue, line('SE-1'))?.id, 'i1');
    });

    test('matches on barcode', () {
      final withBarcode = [item('i3', 'Notebook', barcode: '9781234567890')];
      expect(matchScannedItem(withBarcode, line('9781234567890'))?.id, 'i3');
    });

    test('falls back to a unique HSN', () {
      expect(
        matchScannedItem(catalogue, line('Unreadable', hsn: '1905'))?.id,
        'i2',
      );
    });

    test('refuses an ambiguous HSN instead of guessing an item', () {
      // Two stocked items legitimately share a classification; picking one
      // would move the wrong item's stock, which is worse than moving none.
      final shared = [
        item('i1', 'Ceiling Fan 1200mm', hsn: '8414'),
        item('i2', 'Table Fan 1200mm', hsn: '8414'),
      ];
      expect(matchScannedItem(shared, line('Fan', hsn: '8414')), isNull);
    });

    test('refuses two items that differ only by case', () {
      final twins = [item('i1', 'Laptop'), item('i2', 'laptop')];
      expect(matchScannedItem(twins, line('LAPTOP')), isNull);
    });

    test('an empty description matches nothing', () {
      expect(matchScannedItem(catalogue, line('   ')), isNull);
    });
  });

  group('ScannedReviewState lines are addressed by id, not position', () {
    test('editing a line after a deletion writes to that line', () {
      final review = ScannedReviewState.fromBill(_FakeBill()).withoutLine(0);
      expect(review.lines.map((l) => l.name), ['Biscuit Amira']);

      final edited = review.withLineQuantity(review.lineIds.single, 7);
      expect(edited.lines.single.quantity, 7);
      expect(
        edited.lines.single.name,
        'Biscuit Amira',
        reason: 'the edit must not have touched the other line',
      );
    });

    test('a removed line takes its catalogue link with it', () {
      final first = ScannedReviewState.fromBill(_FakeBill());
      final linked = first.withLineItem(first.lineIds.first, 'i2');
      expect(linked.linkedCount, 1);

      final afterRemoval = linked.withoutLine(0);
      expect(afterRemoval.linkedCount, 0);
      expect(afterRemoval.lineIds, hasLength(1));
      expect(afterRemoval.lineItemIds, hasLength(1));
    });

    test('a link made after a deletion lands on the surviving line', () {
      final review = ScannedReviewState.fromBill(_FakeBill()).withoutLine(0);
      final linked = review.withLineItem(review.lineIds.single, 'i2');
      expect(linked.lineItemIds.single, 'i2');
    });

    test('the seed carries the reviewer\'s picks to the editor', () {
      final review = ScannedReviewState.fromBill(_FakeBill());
      final linked = review.withLineItem(review.lineIds[1], 'i2');
      final seed = linked.toSeed()!;
      expect(seed.lines, hasLength(2));
      // `lineItemIds` is INDEX-ALIGNED with `lines`, because that is the only
      // thing the editor can address: it walks `seed.lines[i]` and reads
      // `seed.lineItemIds[i]`. A compacted list holding just the linked picks
      // would put i2 on line 0 — the very mispairing this group guards against.
      expect(seed.lineItemIds, hasLength(seed.lines.length));
      expect(seed.lineItemIds, [null, 'i2']);
      expect(seed.lines[1].name, 'Biscuit Amira',
          reason: 'the pick must ride with the line it was made on');
    });

    test('a deleted line takes its pick out of the seed with it', () {
      final review = ScannedReviewState.fromBill(_FakeBill());
      final linked = review
          .withLineItem(review.lineIds.first, 'i2')
          .withLineItem(review.lineIds[1], 'i1');
      expect(linked.toSeed()!.lineItemIds, ['i2', 'i1']);

      final seed = linked.withoutLine(0).toSeed()!;
      expect(seed.lines.map((l) => l.name), ['Biscuit Amira']);
      expect(seed.lineItemIds, ['i1'],
          reason: 'the removed line\'s pick must not slide onto the survivor');
    });

    test('the charge fields the review screen exposes reach the seed', () {
      final review = ScannedReviewState.fromBill(_FakeBill()).copyWith(
        dueDateRaw: () => '2026-10-30',
        shippingCharge: () => 120,
        otherCharges: () => 45,
      );
      final seed = review.toSeed()!;
      expect(seed.dueDate, DateTime(2026, 10, 30));
      expect(seed.shippingCharge, 120);
      expect(seed.otherCharges, 45);
    });

    test('a charge field cleared to empty is zero, not the old figure', () {
      final review = ScannedReviewState.fromBill(_FakeBill())
          .copyWith(shippingCharge: () => 0);
      expect(review.toSeed()!.shippingCharge, 0);
    });
  });
}

/// The model answer the review screen reads through [ScannedReviewState.fromBill]
/// (typed `dynamic` there, so the reading can never crash the app).
class _FakeBill {
  final double? grandTotal = null;
  final String? supplierName = 'Khanna Hardware';
  final String? supplierGstin = null;
  final String? supplierPhone = null;
  final String? supplierAddress = null;
  final String? supplierInvoiceNumber = 'KH/26/9';
  final DateTime? billDate = DateTime(2026, 9, 18);
  final DateTime? dueDate = null;
  final String? placeOfSupply = '29';
  final double shippingCharge = 0;
  final double otherCharges = 0;
  final String confidence = 'high';
  final List<String> warnings = const [];
  final String model = 'fake';
  final List<_FakeLine> lines = const [
    _FakeLine(name: 'Surf Excel 1kg', hsn: '3402', quantity: 2, rate: 150),
    _FakeLine(name: 'Biscuit Amira', hsn: '1905', quantity: 6, rate: 40),
  ];
}

class _FakeLine {
  const _FakeLine({
    required this.name,
    required this.hsn,
    required this.quantity,
    required this.rate,
  });

  final String name;
  final String hsn;
  final double quantity;
  final double rate;
  final String unit = 'pcs';
  final double discountPercent = 0;
  final double gstRate = 18;
  final double cessRate = 0;
}
