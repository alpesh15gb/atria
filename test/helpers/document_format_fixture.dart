import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;

Future<
  (
    FirmEntity,
    SalesInvoiceEntity,
    List<SalesInvoiceItemEntity>,
    PurchaseBillEntity,
    List<PurchaseBillItemEntity>,
  )
>
documentFormatFixture(
  AppDatabase db, {
  bool registered = true,
  int count = 4,
  bool interState = false,
}) async {
  var firm = await db.firmRepository.create(
    name: 'Apex Integrations',
    gstin: registered ? '29ABCDE1234F1Z5' : null,
    stateCode: '29',
    addressLine1: '64, Whitefield Main Road, Palm Meadows',
    city: 'Bengaluru',
    pincode: '560066',
    phone: '9876543210',
    email: 'accounts@example.com',
  );
  firm = await db.firmRepository.update(
    firm.copyWith(
      bankName: const Value('Example Bank'),
      bankAccountNumber: const Value('123456789012'),
      bankIfsc: const Value('EXAM0001234'),
      bankBranch: const Value('Whitefield'),
      showBankOnInvoice: true,
      showQrOnInvoice: true,
      upiId: const Value('apex@example'),
      signatureName: const Value('A. Kumar'),
      invoiceTerms: const Value(
        '1. Please quote the invoice number with your payment.\n2. Goods are subject to the agreed warranty terms.\n3. Subject to local jurisdiction.',
      ),
      invoiceNotes: const Value('Thank you for your business.'),
    ),
  );
  final names = [
    'Colgate 200 gm',
    'Surf Excel Easy Wash Detergent Powder 1kg',
    'Dove Soap',
    'Head & Shoulders Shampoo',
  ];
  final invoice = await db
      .salesRepositoryFor(firm.id)
      .save(
        SalesDraft(
          id: 'sample-sale',
          number: 'INV-001',
          docType: 'invoice',
          invoiceDate: DateTime(2026, 10, 11),
          dueDate: DateTime(2026, 10, 26),
          partyName: 'Kalyan Enterprises',
          partyGstin: '29AABCK1234F1Z5',
          billingAddress:
              '37/2, Commercial Street\nBengaluru, Karnataka, 560001',
          shippingAddress:
              'R City Business Park, Warehouse 2\nBengaluru, Karnataka, 560048',
          placeOfSupply: interState ? '27' : '29',
          isInterState: interState,
          lines: [
            for (var i = 0; i < count; i++)
              SalesLineDraft(
                id: 'sale-line-$i',
                name: count > 4
                    ? 'Product ${i + 1} - specification and warranty details'
                    : names[i],
                hsn: ['33061020', '340119', '340119', '3304'][i % 4],
                quantity: Decimal.fromInt(i % 4 + 1),
                unit: 'NOS',
                rate: Decimal.parse(
                  ['64.41', '126.27', '33.05', '253.39'][i % 4],
                ),
                gstRate: i % 3 == 0
                    ? 18
                    : i % 3 == 1
                    ? 5
                    : 12,
              ),
          ],
        ),
      );
  final bill = await db
      .purchaseRepositoryFor(firm.id)
      .save(
        PurchaseDraft(
          id: 'sample-purchase',
          number: 'PUR-001',
          docType: 'bill',
          billDate: DateTime(2026, 10, 11),
          dueDate: DateTime(2026, 10, 26),
          partyName: 'Trade Supplies Ltd',
          partyGstin: '29AABCT1234F1Z5',
          placeOfSupply: '29',
          lines: [
            for (var i = 0; i < count; i++)
              PurchaseLineDraft(
                id: 'purchase-line-$i',
                name: count > 4 ? 'Supply ${i + 1}' : names[i],
                hsn: ['33061020', '340119', '340119', '3304'][i % 4],
                quantity: Decimal.fromInt(i % 4 + 1),
                unit: 'NOS',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
          ],
        ),
      );
  return (
    firm,
    invoice,
    await db.salesRepositoryFor(firm.id).itemsFor(invoice.id),
    bill,
    await db.purchaseRepositoryFor(firm.id).itemsFor(bill.id),
  );
}
