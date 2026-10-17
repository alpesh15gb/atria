import 'package:atria/core/api/scan_client.dart';
import 'package:atria/features/purchase/bill_scan_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('printed total survives review edits and reaches the purchase seed', () {
    final bill = ScannedBill.fromJson({
      'supplierName': 'VIDA INDIA CONSULTING SERVICES',
      'grandTotal': 37540,
      'lines': [
        {'name': 'Camera', 'quantity': 6, 'rate': 2627.12, 'gstRate': 18},
        {'name': 'Cable', 'quantity': 1, 'rate': 1313.56, 'gstRate': 18},
      ],
    });
    var review = ScannedReviewState.fromBill(bill);
    review = review.copyWith(invoiceNumber: () => 'Q-86');
    review = review.withLineQuantity(review.lineIds.first, 6);
    review = review.withLineItem(review.lineIds.first, 'camera-id');
    review = review.withoutLine(1);
    final seed = review.toSeed()!;
    expect(seed.grandTotal, 37540);
    expect(seed.lines, hasLength(1));
    expect(seed.invoiceNumber, 'Q-86');
  });
}
