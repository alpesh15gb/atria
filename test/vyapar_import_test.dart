import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/vyapar_backup.dart';
import 'package:atria/core/services/vyapar_import.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/settings/vyapar_import_screen.dart';

/// Vyapar backups are a ZIP holding one SQLite database. These tests build the
/// same shape from scratch so they run anywhere, and then — when the developer
/// happens to have a real backup on their desktop — import that too and check
/// the books reconcile against Vyapar's own figures.
void main() {
  group('Vyapar backup reader', () {
    test('reads the company, parties, items and documents', () async {
      final snapshot = await VyaparBackupReader.read(vyaparFixtureBytes());

      expect(snapshot.firm['firm_name'], 'Apex Integrations');
      expect(snapshot.parties, hasLength(2));
      expect(snapshot.expenseHeads, hasLength(1));
      expect(snapshot.items, hasLength(3));
      expect(snapshot.taxRates[24], 18);

      final kinds = snapshot.documents.map((d) => d.kind).toList();
      expect(kinds, containsAll(<VyaparDocKind>[
        VyaparDocKind.saleInvoice,
        VyaparDocKind.quotation,
        VyaparDocKind.purchaseOrder,
        VyaparDocKind.purchaseBill,
        VyaparDocKind.paymentIn,
      ]));
      expect(snapshot.unsupportedTypeCounts[99], 1);
    });

    test('decodes document types from Vyapar\'s own type codes', () {
      // The codes matter: 2 is the purchase *bill* and 28 the purchase *order*,
      // which is the opposite of what their numbering suggests.
      expect(vyaparDocKindFor(1), VyaparDocKind.saleInvoice);
      expect(vyaparDocKindFor(2), VyaparDocKind.purchaseBill);
      expect(vyaparDocKindFor(3), VyaparDocKind.paymentIn);
      expect(vyaparDocKindFor(4), VyaparDocKind.paymentOut);
      expect(vyaparDocKindFor(24), VyaparDocKind.saleOrder);
      expect(vyaparDocKindFor(27, 0), VyaparDocKind.quotation);
      expect(vyaparDocKindFor(27, 1), VyaparDocKind.quotation);
      expect(vyaparDocKindFor(28), VyaparDocKind.purchaseOrder);
      expect(vyaparDocKindFor(30), VyaparDocKind.deliveryNote);
      expect(vyaparDocKindFor(60), VyaparDocKind.unsupported);
    });

    test('rejects a file that is not a Vyapar backup', () async {
      await expectLater(
        VyaparBackupReader.read(Uint8List.fromList(utf8.encode('not a zip'))),
        throwsA(isA<VyaparFormatException>()),
      );

      // A ZIP that holds something other than a SQLite database.
      final archive = Archive()
        ..addFile(ArchiveFile('notes.vyp', 5, utf8.encode('hello')));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
      await expectLater(
        VyaparBackupReader.read(bytes),
        throwsA(isA<VyaparFormatException>()),
      );
    });
  });

  group('Vyapar import', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.test(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('previews without writing anything', () async {
      final preview = await VyaparImportService(db).preview(vyaparFixtureBytes());

      expect(preview.firmName, 'Apex Integrations');
      expect(preview.gstin, '36CZFPM0045M2Z7');
      expect(preview.state, 'Telangana');
      expect(preview.counts.parties, 2);
      expect(preview.counts.items, 3);
      expect(preview.counts.saleInvoices, 2);
      expect(preview.counts.quotations, 1);
      expect(preview.counts.purchaseBills, 1);
      expect(preview.counts.purchaseOrders, 1);
      expect(preview.counts.skipped, 1);
      expect(preview.warnings.join(), contains('type code 99'));

      expect(await db.firmRepository.all(), isEmpty);
      expect(await db.select(db.parties).get(), isEmpty);
    });

    test('imports the books and reconciles them to Vyapar', () async {
      final result = await VyaparImportService(db).run(vyaparFixtureBytes());
      final firmId = result.firmId;

      // ---- Firm ----------------------------------------------------------
      final firm = await db.firmRepository.getById(firmId);
      expect(firm, isNotNull);
      expect(firm!.name, 'Apex Integrations');
      expect(firm.gstin, '36CZFPM0045M2Z7');
      expect(firm.stateCode, '36');
      expect(firm.pan, 'CZFPM0045M');
      expect(await db.settingsGet('active_firm_id'), firmId);

      // ---- Parties -------------------------------------------------------
      final parties = await db.partyRepositoryFor(firmId).all();
      expect(parties, hasLength(2));
      final customer =
          parties.firstWhere((party) => party.name.startsWith('M/s Keystone'));
      expect(customer.type, 'customer');
      expect(customer.gstType, 'registered');
      expect(customer.stateCode, '36');
      // "Hyderabad, Telangana-500034" is split into the city and pincode the
      // party form and e-way bills want separately.
      expect(customer.city, 'Hyderabad');
      expect(customer.pincode, '500034');
      expect(customer.addressLine1, '8-2-350 Road Number 3');

      final supplierSpec = parties
          .firstWhere((party) => party.name.startsWith('I-HEAP'));
      expect(supplierSpec.type, 'supplier');

      // Vyapar's expense heads are names, but they are not parties.
      expect(parties.map((p) => p.name), isNot(contains('Petrol')));

      final expenseCategories =
          await db.itemRepositoryFor(firmId).categories(kind: 'expense');
      expect(expenseCategories.map((c) => c.name), contains('Petrol'));

      final itemCategories =
          await db.itemRepositoryFor(firmId).categories(kind: 'item');
      expect(itemCategories.map((c) => c.name), contains('Consumables'));

      // ---- Items ---------------------------------------------------------
      final items = await db.itemRepositoryFor(firmId).all();
      expect(items, hasLength(3));
      final good =
          items.firstWhere((item) => item.name == 'Canon NPG90');
      expect(good.unit, 'pcs');
      expect(good.gstRate, 18);
      expect(good.sku, 'CAN1');
      expect(good.hsn, '84439959');
      expect(good.mrp, 1500);
      expect(good.lowStockAlert, 2);
      expect(good.isService, isFalse);
      // 10 in Vyapar, having already had -2, -1 and +10 posted by the documents
      // below — so the opening balance must be 3 for the closing figure to land
      // back on Vyapar's 10.
      expect(good.openingStock, 3);
      expect(good.currentStock, 10);

      // A SAC code starting 99 marks a service, but this one carries stock in
      // Vyapar (it sits at a negative quantity), so it must stay a stocked item
      // or the quantity would silently disappear.
      final contract = items
          .firstWhere((item) => item.name == 'ANNUAL MAINTAINANCE CONTRACT');
      expect(contract.isService, isFalse);
      expect(contract.stockType, 'tracked');
      expect(contract.openingStock, -5);
      expect(contract.currentStock, -5);

      // A service with no stock to lose is labelled as one.
      final installation =
          items.firstWhere((item) => item.name == 'INSTALLATION SERVICE');
      expect(installation.isService, isTrue);
      expect(installation.stockType, 'untracked');
      expect(installation.currentStock, 0);

      // ---- Sales ---------------------------------------------------------
      final sales = db.salesRepositoryFor(firmId);
      final invoices = await sales.list(docType: 'invoice');
      expect(invoices, hasLength(2));
      expect(invoices.map((i) => i.number), containsAll(['1', '2']));

      final unpaid = invoices.firstWhere((i) => i.number == '1');
      expect(unpaid.grandTotal, 2360);
      expect(unpaid.balanceDue, 2360);
      expect(unpaid.paidAmount, 0);
      expect(unpaid.paymentStatus, 'unpaid');
      expect(unpaid.partyName, 'M/s Keystone Infra Pvt Ltd');
      expect(unpaid.isInterState, isFalse);
      expect(unpaid.placeOfSupply, '36');
      expect(unpaid.cgst, 180);
      expect(unpaid.sgst, 180);

      final lineItems = await sales.itemsFor(unpaid.id);
      expect(lineItems, hasLength(1));
      expect(lineItems.first.quantity, 2);
      expect(lineItems.first.rate, 1000);
      expect(lineItems.first.gstRate, 18);
      expect(lineItems.first.taxableValue, 2000);

      final quotations = await sales.list(docType: 'quotation');
      expect(quotations, hasLength(1));
      expect(quotations.first.number, '1');

      // ---- Purchases -----------------------------------------------------
      final purchases = db.purchaseRepositoryFor(firmId);
      final bills = await purchases.list(docType: 'bill');
      expect(bills, hasLength(1));
      expect(bills.first.number, 'SUP-1');
      expect(bills.first.supplierInvoiceNumber, 'SUP-1');
      expect(bills.first.grandTotal, 9440);
      expect(bills.first.balanceDue, 0);
      expect(bills.first.paymentStatus, 'paid');

      final orders = await purchases.list(docType: 'purchase_order');
      expect(orders, hasLength(1));
      // The purchase order must not have touched stock: the item's closing
      // quantity is asserted above and would be 15 if it had.
      expect(orders.first.grandTotal, 4720);

      // ---- Payments ------------------------------------------------------
      final payments = db.paymentRepositoryFor(firmId);
      final received = await payments.list(type: 'payment_in');
      expect(received, hasLength(1));
      expect(received.first.amount, 1180);
      expect(received.first.partyName, 'M/s Keystone Infra Pvt Ltd');
      expect(received.first.linkedInvoiceId, isNotNull);

      final paidOut = await payments.list(type: 'payment_out');
      expect(paidOut, hasLength(1));
      expect(paidOut.first.amount, 9440);
      // Vyapar recorded this one through its payment-mode map with a UPI
      // reference, which is all the information there is about how it was paid.
      expect(paidOut.first.mode, 'upi');
      expect(paidOut.first.linkedInvoiceId, isNotNull);

      // ---- Reported counts and warnings ----------------------------------
      expect(result.counts.parties, 2);
      expect(result.counts.items, 3);
      expect(result.counts.saleInvoices, 2);
      expect(result.counts.payments, 2);
      expect(result.warnings.join(), contains('type code 99'));
    });

    test('a second import of the same backup does not collide on numbers',
        () async {
      final service = VyaparImportService(db);
      final first = await service.run(vyaparFixtureBytes());
      final second = await service.run(vyaparFixtureBytes());

      expect(second.firmId, isNot(first.firmId));
      final secondInvoices = await db
          .salesRepositoryFor(second.firmId)
          .list(docType: 'invoice');
      expect(secondInvoices, hasLength(2));
      // Each firm keeps the original Vyapar numbers: the uniqueness is scoped
      // per firm, so nothing had to be renamed.
      expect(secondInvoices.map((i) => i.number), containsAll(['1', '2']));
    });

    test('renames numbers that repeat inside one document series', () async {
      // Vyapar restarts invoice numbering each financial year, and its prefix
      // lives in a separate column, so the same number really does appear
      // twice in a decade of books.
      final bytes = vyaparFixtureBytes(mutate: (raw) {
        raw.execute(
          "INSERT INTO kb_transactions (txn_id, txn_date, txn_name_id, "
          "txn_type, txn_sub_type, txn_status, txn_payment_status, "
          "txn_ref_number_char, txn_cash_amount, txn_balance_amount, "
          "txn_tax_inclusive, txn_place_of_supply) "
          "VALUES (8, '2026-05-02 00:00:00', 6, 1, 1, 1, 1, '1', 0, 1180, 2, "
          "'Telangana')",
        );
        raw.execute(
          'INSERT INTO kb_lineitems (lineitem_id, lineitem_txn_id, item_id, '
          'quantity, priceperunit, total_amount, lineitem_tax_amount, '
          'lineitem_discount_amount, lineitem_discount_percent, '
          'lineitem_additional_cess, lineitem_unit_id, lineitem_tax_id) '
          'VALUES (9, 8, 1, 1, 1000, 1180, 180, 0, 0, 0, 15, 24)',
        );
      });

      final result = await VyaparImportService(db).run(bytes);
      final invoices =
          await db.salesRepositoryFor(result.firmId).list(docType: 'invoice');

      expect(invoices, hasLength(3));
      expect(
        invoices.map((invoice) => invoice.number).toList()..sort(),
        ['1', '1-2', '2'],
      );
    });

    group('GST registration', () {
      test('a registered buyer in another state is charged IGST', () async {
        final bytes = vyaparFixtureBytes(mutate: (raw) {
          raw.execute(
              "UPDATE kb_names SET name_state = 'Maharashtra' WHERE name_id = 6");
        });

        final result = await VyaparImportService(db).run(bytes);
        final invoice = (await db
                .salesRepositoryFor(result.firmId)
                .list(docType: 'invoice'))
            .firstWhere((doc) => doc.number == '1');

        expect(invoice.isInterState, isTrue);
        expect(invoice.partyGstType, 'registered');
        expect(invoice.igst, 360);
        expect(invoice.cgst, 0);
        expect(invoice.sgst, 0);
        // The statutory place of supply is the buyer's state, not the firm's.
        expect(invoice.placeOfSupply, '27');
      });

      test('an unregistered buyer in another state is not charged IGST',
          () async {
        // This is the case the sale editor also refuses to treat as inter-state:
        // with no GSTIN on the buyer there is no registration to compare, so the
        // supply is taxed locally. Matching the editor matters because
        // `isInterState` is what separates B2CL from B2CS in GSTR-1.
        final bytes = vyaparFixtureBytes(mutate: (raw) {
          raw.execute("UPDATE kb_names SET name_gstin_number = '', "
              "name_customer_type = 0, name_state = 'Maharashtra' "
              'WHERE name_id = 6');
        });

        final result = await VyaparImportService(db).run(bytes);
        final invoice = (await db
                .salesRepositoryFor(result.firmId)
                .list(docType: 'invoice'))
            .firstWhere((doc) => doc.number == '1');

        expect(invoice.isInterState, isFalse);
        expect(invoice.partyGstType, 'unregistered');
        expect(invoice.igst, 0);
        expect(invoice.cgst, 180);
        expect(invoice.sgst, 180);
        expect(invoice.partyGstin, isNull);
        // The place of supply still records where the goods went.
        expect(invoice.placeOfSupply, '27');
      });

      test('a company that is not GST registered stays local and says so',
          () async {
        final bytes = vyaparFixtureBytes(mutate: (raw) {
          raw.execute("UPDATE kb_firms SET firm_gstin_number = ''");
          raw.execute("UPDATE kb_settings SET setting_value = '0' "
              "WHERE setting_key = 'VYAPAR.GSTENABLED'");
          raw.execute(
              "UPDATE kb_names SET name_state = 'Maharashtra' WHERE name_id = 6");
        });

        final result = await VyaparImportService(db).run(bytes);
        final firm = await db.firmRepository.getById(result.firmId);
        final invoice = (await db
                .salesRepositoryFor(result.firmId)
                .list(docType: 'invoice'))
            .firstWhere((doc) => doc.number == '1');

        expect(firm!.gstin, isNull);
        // Still knows which state it is in — the firm's address needs it even
        // when it has no GSTIN.
        expect(firm.stateCode, '36');
        expect(invoice.isInterState, isFalse);
        expect(invoice.igst, 0);
        expect(result.warnings.join(), contains('not registered for GST'));
      });

      test('a party flagged registered but with an unusable GSTIN is not',
          () async {
        // A 14-character GSTIN must never print on an invoice, and a party with
        // no GSTIN cannot be treated as B2B — but the data loss is reported.
        final bytes = vyaparFixtureBytes(mutate: (raw) {
          raw.execute("UPDATE kb_names SET name_gstin_number = '36AACCK6531F1Z' "
              'WHERE name_id = 6');
        });

        final result = await VyaparImportService(db).run(bytes);
        final party = (await db.partyRepositoryFor(result.firmId).all())
            .firstWhere((row) => row.name.startsWith('M/s Keystone'));
        final invoice = (await db
                .salesRepositoryFor(result.firmId)
                .list(docType: 'invoice'))
            .firstWhere((doc) => doc.number == '1');

        expect(party.gstin, isNull);
        expect(party.gstType, 'unregistered');
        expect(party.pan, isNull);
        expect(invoice.isInterState, isFalse);
        expect(result.warnings.join(), contains('15-character'));
      });
    });

    test('deletes the partial firm when an import fails', () async {
      // A locked period applies to every firm (a global settings row), and it
      // legitimately stops an import part-way through. What matters is that no
      // half-written firm is left behind for the user to find.
      await db.settingsSet('books_locked_upto', '2026-12-31');

      await expectLater(
        VyaparImportService(db).run(vyaparFixtureBytes()),
        throwsA(isA<Exception>()),
      );

      expect(await db.firmRepository.all(), isEmpty);
      expect(await db.select(db.parties).get(), isEmpty);
      expect(await db.select(db.items).get(), isEmpty);
      expect(await db.select(db.units).get(), isEmpty);
      expect(await db.select(db.categories).get(), isEmpty);
      expect(await db.select(db.salesInvoices).get(), isEmpty);
      expect(await db.select(db.purchaseBills).get(), isEmpty);
      expect(await db.select(db.payments).get(), isEmpty);
      expect(await db.select(db.stockMovements).get(), isEmpty);
      expect(await db.settingsGet('active_firm_id'), isNull);
    });

    test('imports a real Vyapar backup when one is on the desktop', () async {
      final file = File(
        p.join(
          Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              '',
          'Desktop',
          'vyapar.vyb',
        ),
      );
      if (!file.existsSync()) {
        markTestSkipped('No vyapar.vyb on the desktop');
        return;
      }

      final bytes = file.readAsBytesSync();
      final snapshot = await VyaparBackupReader.read(bytes);
      final service = VyaparImportService(db);
      final preview = await service.preview(bytes);
      final result = await service.run(bytes);

      // Every party's balance in Apex Books must equal the balance Vyapar showed.
      final parties = await db.partyRepositoryFor(result.firmId).all();
      expect(parties, isNotEmpty);

      final sales = db.salesRepositoryFor(result.firmId);
      final invoices = await sales.list(docType: 'invoice', limit: 1000);
      expect(invoices, hasLength(preview.counts.saleInvoices));

      final vyaparInvoices = snapshot.documents
          .where((d) => d.kind == VyaparDocKind.saleInvoice)
          .toList();
      final settledByPaymentTxn = <int, double>{};
      for (final link in snapshot.paymentLinks) {
        settledByPaymentTxn.update(
          link.documentTxnId,
          (value) => value + link.amount,
          ifAbsent: () => link.amount,
        );
      }
      var expectedOutstanding = 0.0;
      for (final invoice in vyaparInvoices) {
        final stated = invoice.balanceAmount -
            (settledByPaymentTxn[invoice.id] ?? 0);
        if (stated > 0) expectedOutstanding += stated;
      }
      final actualOutstanding = invoices.fold<double>(
        0,
        (sum, invoice) => sum + invoice.balanceDue,
      );
      // Rounded to the paise: Apex Books recomputes line tax itself, so a document
      // can differ from Vyapar by a rounding step.
      expect(
        (actualOutstanding - expectedOutstanding).abs(),
        lessThan(1),
        reason: 'outstanding $actualOutstanding vs Vyapar $expectedOutstanding',
      );
    });
  });

  group('Vyapar import screen', () {
    testWidgets('offers the file picker before anything is written',
        (tester) async {
      final db = AppDatabase.test(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
      );
      await db.firmRepository.create(name: 'Existing Books');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const VyaparImportScreen(),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Import from Vyapar'), findsOneWidget);
      expect(find.text('Choose your Vyapar backup'), findsOneWidget);
      expect(find.text('Choose a file'), findsOneWidget);
      // Nothing to import until a file has been read.
      expect(find.text('Import into a new business'), findsNothing);
      expect(find.textContaining('Backup & Restore'), findsOneWidget);

      // Unmount, then let drift's stream-teardown timers drain before closing.
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await db.close();
    });
  });
}

/// Builds a miniature Vyapar `.vyb` — a ZIP around a SQLite database built with
/// the same table and column names Vyapar uses.
///
/// [mutate] runs against the raw database after seeding, for the cases that need
/// a backup shaped differently (a repeated invoice number, say).
Uint8List vyaparFixtureBytes({void Function(Database db)? mutate}) {
  final directory = Directory.systemTemp.createTempSync('atria_vyapar_test_');
  try {
    final file = File(p.join(directory.path, 'company.vyp'));
    final db = sqlite3.open(file.path);
    try {
      _createSchema(db);
      _seedFixture(db);
      mutate?.call(db);
    } finally {
      db.dispose();
    }

    final content = file.readAsBytesSync();
    final archive = Archive()
      ..addFile(ArchiveFile(
        'ApexIntegrations__t_2026_04_15_12_30_13_viho.vyp',
        content.length,
        content,
      ));
    return Uint8List.fromList(ZipEncoder().encode(archive)!);
  } finally {
    directory.deleteSync(recursive: true);
  }
}

void _createSchema(Database db) {
  db.execute('''
CREATE TABLE kb_firms (
  firm_id INTEGER, firm_name TEXT, firm_gstin_number TEXT, firm_state TEXT,
  firm_address TEXT, firm_pincode TEXT, firm_phone TEXT, firm_email TEXT,
  firm_invoice_prefix TEXT, firm_bank_name TEXT, firm_bank_account_number TEXT,
  firm_bank_ifsc_code TEXT);
CREATE TABLE kb_names (
  name_id INTEGER, full_name TEXT, party_billing_name TEXT, name_type INTEGER,
  name_group_id INTEGER, name_gstin_number TEXT, name_state TEXT,
  phone_number TEXT, email TEXT, amount REAL, address TEXT, pincode TEXT,
  credit_limit INTEGER, credit_limit_enabled INTEGER, name_expense_type TEXT,
  name_customer_type INTEGER);
CREATE TABLE kb_settings (setting_id INTEGER, setting_key TEXT,
  setting_value TEXT);
CREATE TABLE kb_tax_code (
  tax_code_id INTEGER, tax_code_name TEXT, tax_rate REAL, tax_code_type INTEGER);
CREATE TABLE kb_item_units (
  unit_id INTEGER, unit_name TEXT, unit_short_name TEXT);
CREATE TABLE kb_item_categories (
  item_category_id INTEGER, item_category_name TEXT);
CREATE TABLE kb_party_groups (
  party_group_id INTEGER, party_group_name TEXT);
CREATE TABLE kb_paymentTypes (
  paymentType_id INTEGER, paymentType_type TEXT, paymentType_name TEXT,
  paymentType_bankName TEXT);
CREATE TABLE kb_items (
  item_id INTEGER, item_name TEXT, item_code TEXT, base_unit_id INTEGER,
  item_hsn_sac_code TEXT, item_tax_id INTEGER, item_tax_type INTEGER,
  item_sale_unit_price REAL, item_purchase_unit_price REAL,
  item_stock_quantity REAL, item_min_stock_quantity REAL, item_type INTEGER,
  category_id INTEGER, item_mrp REAL, item_wholesale_price REAL,
  item_description TEXT, item_catalogue_description TEXT,
  item_additional_cess_per_unit REAL);
CREATE TABLE kb_transactions (
  txn_id INTEGER, txn_date TEXT, txn_due_date TEXT, txn_name_id INTEGER,
  txn_type INTEGER, txn_sub_type INTEGER, txn_status INTEGER,
  txn_payment_status INTEGER, txn_ref_number_char TEXT,
  txn_invoice_prefix TEXT, txn_payment_reference TEXT,
  txn_cash_amount REAL, txn_balance_amount REAL, txn_round_off_amount REAL,
  txn_discount_amount REAL, txn_discount_percent REAL, txn_tax_amount REAL,
  txn_tax_inclusive INTEGER, txn_payment_type_id INTEGER,
  txn_place_of_supply TEXT, txn_billing_address TEXT, txn_shipping_address TEXT,
  txn_description TEXT);
CREATE TABLE kb_lineitems (
  lineitem_id INTEGER, lineitem_txn_id INTEGER, item_id INTEGER,
  quantity REAL, priceperunit REAL, total_amount REAL,
  lineitem_tax_amount REAL, lineitem_discount_amount REAL,
  lineitem_discount_percent REAL, lineitem_additional_cess REAL,
  lineitem_unit_id INTEGER, lineitem_tax_id INTEGER, lineitem_description TEXT);
CREATE TABLE kb_txn_links (
  txn_links_id INTEGER, txn_links_txn_1_id INTEGER, txn_links_txn_2_id INTEGER,
  txn_links_amount REAL, txn_links_txn_1_type INTEGER,
  txn_links_txn_2_type INTEGER);
CREATE TABLE txn_payment_mapping (
  id INTEGER, payment_id INTEGER, cheque_id INTEGER, txn_id INTEGER,
  amount REAL, payment_reference TEXT);
''');
}

void _seedFixture(Database db) {
  db.execute("INSERT INTO kb_firms VALUES (1, 'Apex Integrations', "
      "'36CZFPM0045M2Z7', 'Telangana', '4th Floor, Millenium Arcade, Hyderabad', "
      "'500062', '9100960692', 'alpesh2060@gmail.com', '2026-27/', "
      "'DCB BANK', '0123456789', 'DCBL0000123')");

  db.execute("INSERT INTO kb_tax_code VALUES (24, 'GST@18%', 18.0, 1)");

  db.execute("INSERT INTO kb_item_units VALUES (9, 'KILOGRAMS', 'Kg')");
  db.execute("INSERT INTO kb_item_units VALUES (15, 'PIECES', 'Pcs')");
  db.execute("INSERT INTO kb_item_units VALUES (22, 'DAYS', 'DY')");

  db.execute(
      "INSERT INTO kb_item_categories VALUES (1, 'Consumables')");
  db.execute("INSERT INTO kb_party_groups VALUES (1, 'General')");

  db.execute("INSERT INTO kb_paymentTypes VALUES (1, 'CASH', 'Cash', '')");
  db.execute(
      "INSERT INTO kb_paymentTypes VALUES (3, 'BANK', 'DCB BANK', 'DCB BANK LIMITED')");

  // `VYAPAR.GSTENABLED` is how Vyapar records that the company is registered —
  // `kb_firms` itself carries no such flag.
  db.execute("INSERT INTO kb_settings VALUES (1, 'VYAPAR.GSTENABLED', '1')");

  // name_type 2 = an expense head, which Vyapar stores among its parties.
  db.execute(
      "INSERT INTO kb_names (name_id, full_name, name_type, amount, "
      "name_customer_type) VALUES (1, 'Petrol', 2, 0, 0)");
  db.execute('''
INSERT INTO kb_names (name_id, full_name, party_billing_name, name_type,
  name_gstin_number, name_state, phone_number, email, amount, address, pincode,
  credit_limit, credit_limit_enabled, name_customer_type)
VALUES (6, 'M/s Keystone Infra Pvt Ltd', 'M/s Keystone Infra Pvt Ltd', 1,
  '36AACCK6531F1ZP', 'Telangana', '9393645644', 'accounts@keystoneinfra.com',
  2360.0, '8-2-350 Road Number 3\nHyderabad, Telangana-500034\nIndia', '',
  100000, 1, 1)''');
  db.execute('''
INSERT INTO kb_names (name_id, full_name, name_type, name_gstin_number,
  name_state, phone_number, amount, address, pincode, name_customer_type)
VALUES (8, 'I-HEAP ELECTRONICS PVT LTD', 1, '36AAHCI7898C2Z3', 'Telangana',
  '9100960692', 0.0, '2nd Floor, Parklane Circle\nHyderabad, Telangana-500003\nIndia',
  '', 1)''');

  db.execute('''
INSERT INTO kb_items (item_id, item_name, item_code, base_unit_id,
  item_hsn_sac_code, item_tax_id, item_tax_type, item_sale_unit_price,
  item_purchase_unit_price, item_stock_quantity, item_min_stock_quantity,
  item_type, item_mrp, item_wholesale_price, item_description,
  item_additional_cess_per_unit)
VALUES (1, 'Canon NPG90', 'CAN1', 15, '84439959', 24, 1, 1000.0, 800.0, 10.0,
  2.0, 1, 1500.0, 1200.0, 'Mono laser printer', 0)''');
  db.execute('''
INSERT INTO kb_items (item_id, item_name, base_unit_id, item_hsn_sac_code,
  item_tax_id, item_tax_type, item_sale_unit_price, item_purchase_unit_price,
  item_stock_quantity, item_min_stock_quantity, item_type, item_mrp,
  item_wholesale_price, item_description, item_additional_cess_per_unit)
VALUES (2, 'ANNUAL MAINTAINANCE CONTRACT', 22, '9987313', 24, 2, 1129.0, 0.0,
  -5.0, 0.0, 1, 0.0, 0.0, 'AMC', 0)''');
  db.execute('''
INSERT INTO kb_items (item_id, item_name, base_unit_id, item_hsn_sac_code,
  item_tax_id, item_tax_type, item_sale_unit_price, item_purchase_unit_price,
  item_stock_quantity, item_min_stock_quantity, item_type, item_mrp,
  item_wholesale_price, item_description, item_additional_cess_per_unit)
VALUES (3, 'INSTALLATION SERVICE', 22, '998721', 24, 2, 500.0, 0.0, 0.0, 0.0,
  1, 0.0, 0.0, 'On-site installation', 0)''');

  void doc(
    int id,
    String date,
    int? nameId,
    int type,
    int subType,
    String ref,
    double balance,
    double cash, {
    int status = 1,
    int paymentStatus = 1,
    double roundOff = 0,
  }) {
    db.execute(
      'INSERT INTO kb_transactions (txn_id, txn_date, txn_due_date, '
      'txn_name_id, txn_type, txn_sub_type, txn_status, txn_payment_status, '
      'txn_ref_number_char, txn_cash_amount, txn_balance_amount, '
      'txn_round_off_amount, txn_tax_inclusive, txn_place_of_supply) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 2, ?)',
      [
        id,
        date,
        date,
        nameId,
        type,
        subType,
        status,
        paymentStatus,
        ref,
        cash,
        balance,
        roundOff,
        type == 2 || type == 28 ? null : 'Telangana',
      ],
    );
  }

  void line(int id, int txnId, int? itemId, double qty, double price,
      double total, double tax) {
    db.execute(
      'INSERT INTO kb_lineitems (lineitem_id, lineitem_txn_id, item_id, '
      'quantity, priceperunit, total_amount, lineitem_tax_amount, '
      'lineitem_discount_amount, lineitem_discount_percent, '
      'lineitem_additional_cess, lineitem_unit_id, lineitem_tax_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 15, 24)',
      [id, txnId, itemId, qty, price, total, tax],
    );
  }

  // 1 — sale invoice, unpaid.
  doc(1, '2026-04-04 00:00:00', 6, 1, 1, '1', 2360, 0);
  line(1, 1, 1, 2, 1000, 2360, 360);
  // 2 — sale invoice, settled by a payment transaction of its own.
  doc(2, '2026-04-10 00:00:00', 6, 1, 1, '2', 0, 1180, paymentStatus: 3);
  line(2, 2, 1, 1, 1000, 1180, 180);
  // 3 — estimate / quotation, and not a ledger document.
  doc(3, '2026-04-12 00:00:00', 6, 27, 1, '1', 1180, 0, status: 2);
  line(3, 3, 1, 1, 1000, 1180, 180);
  // 4 — purchase order: real code 28, and it must not move stock.
  doc(4, '2026-04-14 00:00:00', 8, 28, 1, '1', 4720, 0, status: 2);
  line(4, 4, 1, 5, 800, 4720, 720);
  // 5 — purchase bill, settled through the payment-mode map.
  doc(5, '2026-04-16 00:00:00', 8, 2, 4, 'SUP-1', 0, 9440, paymentStatus: 3);
  line(5, 5, 1, 10, 800, 9440, 1440);
  // 6 — payment in against invoice 2.
  doc(6, '2026-04-20 00:00:00', 6, 3, 1, '1', 0, 1180, paymentStatus: 3);
  // 7 — a document type Apex Books does not import.
  doc(7, '2026-04-21 00:00:00', 6, 99, 0, '1', 0, 0);

  db.execute('INSERT INTO kb_txn_links VALUES (1, 2, 6, 1180.0, 1, 3)');
  db.execute(
      "INSERT INTO txn_payment_mapping VALUES (1, 3, NULL, 5, 9440.0, 'UPI')");
  db.execute(
      'INSERT INTO txn_payment_mapping VALUES (2, 3, NULL, 1, 0.0, NULL)');
}
