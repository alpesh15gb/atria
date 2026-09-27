import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import '../database/repositories/repository_extensions.dart';
import '../database/repositories/purchase_repository.dart';
import '../database/repositories/sales_repository.dart';
import '../engine/document_numbering.dart';
import '../engine/gst_engine.dart';
import '../utils/id_utils.dart';

/// Seeds a realistic demo firm so the app is explorable on first launch.
/// Idempotent: it checks the seeded flag before writing anything.
class DemoSeeder {
  DemoSeeder(this.db);

  final AppDatabase db;

  Future<bool> seedIfNeeded() async {
    final settings = db;
    final already = await _bool(settings, 'seeded_demo');
    if (already) return false;
    await _seed();
    await settings.settingsSet('seeded_demo', 'true');
    return true;
  }

  Future<bool> _bool(AppDatabase db, String key) async {
    final row = await (db.select(db.appSettings)
          ..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value == 'true';
  }

  Future<void> _seed() async {
    final firmRepo = db.firmRepository;
    final firm = await firmRepo.create(
      name: 'Shri Balaji Traders',
      legalName: 'Shri Balaji Traders',
      gstin: '29AABCB1234L1Z5',
      pan: 'AABCB1234L',
      stateCode: '29',
      addressLine1: 'No. 14, Commercial Street',
      city: 'Bengaluru',
      pincode: '560001',
      phone: '9876543210',
      email: 'balajitraders@example.com',
    );

    // Bank details, UPI id and printed invoice terms aren't part of the initial
    // create() record, so they're applied as a profile update.
    await firmRepo.update(firm.copyWith(
      addressLine2: const Value('Shivaji Nagar'),
      invoiceTerms: const Value(
          'Goods once sold will not be taken back. Interest @18% p.a. on overdue bills. All disputes subject to Bengaluru jurisdiction.'),
      upiId: const Value('balajitraders@oksbi'),
      bankName: const Value('State Bank of India'),
      bankAccountName: const Value('Shri Balaji Traders'),
      bankAccountNumber: const Value('32101234567'),
      bankIfsc: const Value('SBIN0001234'),
      bankBranch: const Value('Shivaji Nagar, Bengaluru'),
      showBankOnInvoice: true,
    ));

    final firmId = firm.id;
    final parties = db.partyRepositoryFor(firmId);
    final items = db.itemRepositoryFor(firmId);
    final sales = db.salesRepositoryFor(firmId);
    final purchases = db.purchaseRepositoryFor(firmId);
    final payments = db.paymentRepositoryFor(firmId);

    // ---- Parties ----
    final partyDefs = <_PartyDef>[
      _PartyDef(
        name: 'Sri Lakshmi Enterprises',
        type: 'customer',
        gstin: '29AADCS1234M1Z1',
        gstType: 'registered',
        phone: '9008012345',
        city: 'Bengaluru',
        stateCode: '29',
        addressLine1: '25, MG Road',
      ),
      _PartyDef(
        name: 'Karnataka Hardware Mart',
        type: 'customer',
        gstin: '29AAHCK5678P1Z2',
        gstType: 'registered',
        phone: '9123456780',
        city: 'Bengaluru',
        stateCode: '29',
        addressLine1: '8, Chickpet',
      ),
      _PartyDef(
        name: 'Ganesh Stores',
        type: 'customer',
        gstType: 'unregistered',
        phone: '9988776655',
        city: 'Mysuru',
        stateCode: '29',
        addressLine1: 'Devaraja Market',
      ),
      _PartyDef(
        name: 'Royal Interiors Pvt Ltd',
        type: 'customer',
        gstin: '27AAGCR9012Q1Z3',
        gstType: 'registered',
        phone: '9090909090',
        city: 'Mumbai',
        stateCode: '27',
        addressLine1: 'Andheri East',
      ),
      _PartyDef(
        name: 'Mahalaxmi Suppliers',
        type: 'supplier',
        gstin: '29AALCM3456R1Z4',
        gstType: 'registered',
        phone: '9876501234',
        city: 'Bengaluru',
        stateCode: '29',
        addressLine1: 'Yeshwanthpur',
      ),
      _PartyDef(
        name: 'Shah & Sons Wholesale',
        type: 'supplier',
        gstin: '24AAJCS7890T1Z5',
        gstType: 'registered',
        phone: '9876512345',
        city: 'Ahmedabad',
        stateCode: '24',
        addressLine1: 'Kalupur',
      ),
    ];

    final createdParties = <String, String>{};
    for (final p in partyDefs) {
      createdParties[p.name] = (await parties.create(
        name: p.name,
        type: p.type,
        gstin: p.gstin,
        gstType: p.gstType,
        phone: p.phone,
        city: p.city,
        stateCode: p.stateCode,
        addressLine1: p.addressLine1,
      )).id;
    }

    // ---- Items ----
    final itemDefs = <_ItemDef>[
      _ItemDef(
        name: 'PVC Pipe 4 inch (3m)',
        hsn: '3917',
        unit: 'pcs',
        salePrice: 420,
        purchasePrice: 340,
        gstRate: 18,
        openingStock: 180,
        lowStockAlert: 40,
      ),
      _ItemDef(
        name: 'GI Elbow 1 inch',
        hsn: '7307',
        unit: 'pcs',
        salePrice: 65,
        purchasePrice: 48,
        gstRate: 18,
        openingStock: 500,
        lowStockAlert: 100,
      ),
      _ItemDef(
        name: 'Brass Tap 15mm',
        hsn: '7412',
        unit: 'pcs',
        salePrice: 145,
        purchasePrice: 112,
        gstRate: 12,
        openingStock: 120,
        lowStockAlert: 30,
      ),
      _ItemDef(
        name: 'Sanitary ware Basin',
        hsn: '6910',
        unit: 'pcs',
        salePrice: 1850,
        purchasePrice: 1420,
        gstRate: 18,
        openingStock: 34,
        lowStockAlert: 10,
      ),
      _ItemDef(
        name: 'Water Tank 500L',
        hsn: '3925',
        unit: 'pcs',
        salePrice: 4600,
        purchasePrice: 3750,
        gstRate: 18,
        openingStock: 22,
        lowStockAlert: 6,
      ),
      _ItemDef(
        name: 'PVC Solvent Cement 1L',
        hsn: '3214',
        unit: 'pcs',
        salePrice: 260,
        purchasePrice: 198,
        gstRate: 28,
        openingStock: 60,
        lowStockAlert: 20,
      ),
      _ItemDef(
        name: 'Installation & Fitting Service',
        hsn: '998721',
        unit: 'svc',
        salePrice: 350,
        purchasePrice: 0,
        gstRate: 18,
        isService: true,
        stockType: 'untracked',
      ),
    ];

    final createdItems = <String, String>{};
    for (final i in itemDefs) {
      createdItems[i.name] = (await items.create(
        name: i.name,
        hsn: i.hsn,
        unit: i.unit,
        salePrice: i.salePrice,
        purchasePrice: i.purchasePrice,
        gstRate: i.gstRate,
        isService: i.isService,
        stockType: i.stockType,
        openingStock: i.openingStock,
        lowStockAlert: i.lowStockAlert,
      )).id;
    }

    // ---- Sales invoices spread over the last 5 months ----
    final now = DateTime.now();
    final saleSpreads = <_SaleSpread>[
      _SaleSpread(5, 'Sri Lakshmi Enterprises', [
        ('PVC Pipe 4 inch (3m)', 40),
        ('GI Elbow 1 inch', 60),
      ]),
      _SaleSpread(5, 'Karnataka Hardware Mart', [
        ('Brass Tap 15mm', 24),
        ('Sanitary ware Basin', 4),
      ]),
      _SaleSpread(4, 'Royal Interiors Pvt Ltd', [
        ('Water Tank 500L', 6),
        ('Installation & Fitting Service', 8),
      ]),
      _SaleSpread(4, 'Ganesh Stores', [
        ('PVC Solvent Cement 1L', 12),
        ('GI Elbow 1 inch', 80),
      ]),
      _SaleSpread(3, 'Sri Lakshmi Enterprises', [
        ('Water Tank 500L', 3),
        ('PVC Pipe 4 inch (3m)', 25),
      ]),
      _SaleSpread(2, 'Karnataka Hardware Mart', [
        ('Sanitary ware Basin', 6),
        ('Brass Tap 15mm', 18),
      ]),
      _SaleSpread(2, 'Royal Interiors Pvt Ltd', [
        ('Installation & Fitting Service', 12),
        ('PVC Solvent Cement 1L', 8),
      ]),
      _SaleSpread(1, 'Ganesh Stores', [
        ('PVC Pipe 4 inch (3m)', 15),
        ('PVC Solvent Cement 1L', 6),
      ]),
      _SaleSpread(1, 'Sri Lakshmi Enterprises', [
        ('GI Elbow 1 inch', 120),
        ('Brass Tap 15mm', 30),
      ]),
      _SaleSpread(0, 'Karnataka Hardware Mart', [
        ('Water Tank 500L', 2),
        ('Sanitary ware Basin', 3),
      ]),
    ];

    var invoiceSequence = 100;
    for (final spread in saleSpreads) {
      final date = DateTime(now.year, now.month - spread.monthsAgo, 12);
      final number = DocumentNumbering.format(
        prefix: firm.invoicePrefix,
        sequence: invoiceSequence++,
        style: NumberingStyle.values[firm.numberingStyle.clamp(0, 2)],
        date: date,
        padding: firm.invoiceSequencePadding,
      );
      final partyId = createdParties[spread.partyName]!;
      final party = await parties.getById(partyId);
      final isInterState = party?.stateCode != firm.stateCode;
      final lines = <SalesLineDraft>[];
      for (final (itemName, qty) in spread.lines) {
        final itemId = createdItems[itemName]!;
        final item = await items.getById(itemId);
        if (item == null) continue;
        lines.add(SalesLineDraft(
          id: IdUtils.newId(),
          itemId: itemId,
          name: item.name,
          hsn: item.hsn,
          quantity: Decimal.fromInt(qty),
          unit: item.unit,
          rate: Decimal.parse(item.salePrice.toString()),
          gstRate: item.gstRate,
          cessRate: item.cessRate,
          taxMode: item.taxMode == 'inclusive'
              ? TaxMode.inclusive
              : TaxMode.exclusive,
        ));
      }
      if (lines.isEmpty) continue;
      final draft = SalesDraft(
        id: IdUtils.newId(),
        number: number,
        docType: 'invoice',
        partyId: partyId,
        invoiceDate: date,
        dueDate: date.add(const Duration(days: 15)),
        lines: lines,
        partyName: party?.name,
        partyGstin: party?.gstin,
        partyGstType: party?.gstType,
        partyPhone: party?.phone,
        billingAddress: _partyAddress(party),
        placeOfSupply: party?.stateCode,
        isInterState: isInterState,
        notes: 'Thank you for your business.',
        sequence: 0,
      );
      final saved = await sales.save(draft);

      // Partial/full payments so balances look realistic.
      if (spread.monthsAgo >= 2) {
        final amount = saved.grandTotal;
        await payments.create(
          type: 'payment_in',
          number: DocumentNumbering.format(
            prefix: firm.paymentInPrefix,
            sequence: 100 + spread.monthsAgo,
            style: NumberingStyle.simple,
            date: date,
          ),
          partyId: partyId,
          partyName: party?.name,
          amount: amount,
          date: date.add(const Duration(days: 7)),
          mode: spread.monthsAgo.isEven ? 'upi' : 'bank_transfer',
          reference: 'UTR${80000 + spread.monthsAgo}',
          linkedInvoiceId: saved.id,
          linkedInvoiceNumber: saved.number,
          onLinked: (id, amt) =>
              sales.applyPayment(invoiceId: id, amount: amt),
        );
      } else if (spread.monthsAgo == 1) {
        await payments.create(
          type: 'payment_in',
          number: DocumentNumbering.format(
            prefix: firm.paymentInPrefix,
            sequence: 201,
            style: NumberingStyle.simple,
            date: date,
          ),
          partyId: partyId,
          partyName: party?.name,
          amount: saved.grandTotal * 0.5,
          date: date.add(const Duration(days: 5)),
          mode: 'upi',
          linkedInvoiceId: saved.id,
          linkedInvoiceNumber: saved.number,
          onLinked: (id, amt) =>
              sales.applyPayment(invoiceId: id, amount: amt),
        );
      }
    }

    // ---- A few purchase bills ----
    final purchaseSpreads = <_PurchaseSpread>[
      _PurchaseSpread(4, 'Mahalaxmi Suppliers', [
        ('PVC Pipe 4 inch (3m)', 60),
        ('GI Elbow 1 inch', 150),
      ]),
      _PurchaseSpread(3, 'Shah & Sons Wholesale', [
        ('Sanitary ware Basin', 10),
        ('Water Tank 500L', 8),
      ]),
      _PurchaseSpread(2, 'Mahalaxmi Suppliers', [
        ('Brass Tap 15mm', 40),
        ('PVC Solvent Cement 1L', 20),
      ]),
      _PurchaseSpread(1, 'Shah & Sons Wholesale', [
        ('Water Tank 500L', 4),
      ]),
    ];

    for (final spread in purchaseSpreads) {
      final date = DateTime(now.year, now.month - spread.monthsAgo, 9);
      final number = DocumentNumbering.format(
        prefix: firm.purchasePrefix,
        sequence: 100 + spread.monthsAgo,
        style: NumberingStyle.values[firm.numberingStyle.clamp(0, 2)],
        date: date,
        padding: firm.invoiceSequencePadding,
      );
      final partyId = createdParties[spread.partyName]!;
      final party = await parties.getById(partyId);
      final isInterState = party?.stateCode != firm.stateCode;
      final lines = <PurchaseLineDraft>[];
      for (final (itemName, qty) in spread.lines) {
        final itemId = createdItems[itemName]!;
        final item = await items.getById(itemId);
        if (item == null) continue;
        lines.add(PurchaseLineDraft(
          id: IdUtils.newId(),
          itemId: itemId,
          name: item.name,
          hsn: item.hsn,
          quantity: Decimal.fromInt(qty),
          unit: item.unit,
          rate: Decimal.parse(item.purchasePrice.toString()),
          gstRate: item.gstRate,
        ));
      }
      if (lines.isEmpty) continue;
      await purchases.save(PurchaseDraft(
        id: IdUtils.newId(),
        number: number,
        docType: 'bill',
        partyId: partyId,
        supplierInvoiceNumber: 'SUP-$number',
        billDate: date,
        dueDate: date.add(const Duration(days: 30)),
        lines: lines,
        partyName: party?.name,
        partyGstin: party?.gstin,
        partyGstType: party?.gstType,
        partyPhone: party?.phone,
        billingAddress: _partyAddress(party),
        placeOfSupply: party?.stateCode,
        isInterState: isInterState,
      ));
    }

    // ---- A quotation and a sales order ----
    final quoteParty = await parties.getById(
        createdParties['Royal Interiors Pvt Ltd']!);
    final quoteItem = await items.getById(
        createdItems['Water Tank 500L']!);
    if (quoteParty != null && quoteItem != null) {
      await sales.save(
        SalesDraft(
          id: IdUtils.newId(),
          number: DocumentNumbering.format(
            prefix: firm.quotationPrefix,
            sequence: 1,
            style: NumberingStyle.values[firm.numberingStyle.clamp(0, 2)],
            date: now,
            padding: firm.invoiceSequencePadding,
          ),
          docType: 'quotation',
          partyId: quoteParty.id,
          invoiceDate: now,
          dueDate: now.add(const Duration(days: 7)),
          status: 'confirmed',
          lines: [
            SalesLineDraft(
              id: IdUtils.newId(),
              itemId: quoteItem.id,
              name: quoteItem.name,
              hsn: quoteItem.hsn,
              quantity: Decimal.fromInt(4),
              unit: quoteItem.unit,
              rate: Decimal.parse(quoteItem.salePrice.toString()),
              gstRate: quoteItem.gstRate,
            ),
          ],
          partyName: quoteParty.name,
          partyGstin: quoteParty.gstin,
          partyGstType: quoteParty.gstType,
          partyPhone: quoteParty.phone,
          billingAddress: _partyAddress(quoteParty),
          placeOfSupply: quoteParty.stateCode,
          isInterState: quoteParty.stateCode != firm.stateCode,
        ),
        affectStock: false,
      );
    }

    // ---- Expenses ----
    final expenses = db.expenseRepositoryFor(firmId);
    final expenseDefs = [
      ('Rent', 18000, 5, 'rent'),
      ('Salaries & Wages', 42000, 4, 'salary'),
      ('Electricity', 6400, 3, 'electricity'),
      ('Transport & Fuel', 8200, 2, 'transport'),
      ('Office Supplies', 3600, 1, 'office'),
      ('Internet & Telephone', 1499, 1, 'internet'),
    ];
    for (final (category, amount, monthsAgo, mode) in expenseDefs) {
      await expenses.create(
        type: 'expense',
        number: DocumentNumbering.format(
          prefix: firm.expensePrefix,
          sequence: 100 + monthsAgo,
          style: NumberingStyle.simple,
          date: DateTime(now.year, now.month - monthsAgo, 5),
        ),
        category: category,
        amount: amount.toDouble(),
        date: DateTime(now.year, now.month - monthsAgo, 5),
        mode: mode,
      );
    }

    // ---- Mark the seeded firm as default and active ----
    await db.settingsSet('active_firm_id', firmId);
  }

  String _partyAddress(PartyEntity? party) {
    if (party == null) return '';
    return [
      party.addressLine1,
      party.addressLine2,
      [party.city, party.pincode].where((e) => e != null && e.isNotEmpty).join(' '),
    ].where((e) => e != null && e.trim().isNotEmpty).join(', ');
  }
}

class _PartyDef {
  final String name;
  final String type;
  final String? gstin;
  final String gstType;
  final String? phone;
  final String? city;
  final String? stateCode;
  final String? addressLine1;

  const _PartyDef({
    required this.name,
    required this.type,
    this.gstin,
    required this.gstType,
    this.phone,
    this.city,
    this.stateCode,
    this.addressLine1,
  });
}

class _ItemDef {
  final String name;
  final String hsn;
  final String unit;
  final double salePrice;
  final double purchasePrice;
  final double gstRate;
  final double openingStock;
  final double lowStockAlert;
  final bool isService;
  final String stockType;

  const _ItemDef({
    required this.name,
    required this.hsn,
    required this.unit,
    required this.salePrice,
    required this.purchasePrice,
    required this.gstRate,
    this.openingStock = 0,
    this.lowStockAlert = 0,
    this.isService = false,
    this.stockType = 'tracked',
  });
}

class _SaleSpread {
  final int monthsAgo;
  final String partyName;
  final List<(String, int)> lines;

  const _SaleSpread(this.monthsAgo, this.partyName, this.lines);
}

class _PurchaseSpread {
  final int monthsAgo;
  final String partyName;
  final List<(String, int)> lines;

  const _PurchaseSpread(this.monthsAgo, this.partyName, this.lines);
}
