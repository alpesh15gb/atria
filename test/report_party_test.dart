import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/database/repositories/party_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_providers.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/sources/party/party_common.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:atria/shared/widgets/report_filter_bar.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The six Party reports.
///
/// **Every assertion here is about a number a CA would check**, because that is
/// the failure mode these reports have. A party report that renders is easy; one
/// whose totals quietly disagree with the sales register beside it is the thing
/// that costs somebody their afternoon, and it looks completely fine on screen.
void main() {
  late AppDatabase db;
  late String firmId;
  late SalesRepository sales;
  late PurchaseRepository purchases;
  late PartyRepository parties;
  late String itemId;

  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(gstin: '29ABCDE1234F1Z5', 
      name: 'Apex Traders',
      stateCode: '29',
    );
    firmId = firm.id;
    sales = db.salesRepositoryFor(firmId);
    purchases = db.purchaseRepositoryFor(firmId);
    parties = db.partyRepositoryFor(firmId);
  });

  /// The item every fixture sells and buys.
  ///
  /// In its own `setUp` because a Dart local function cannot be referenced
  /// before its declaration — creating the item from the block above would have
  /// to reach down into a helper defined further down the file.
  setUp(() async {
    final item = await db
        .itemRepositoryFor(firmId)
        .create(
          name: 'Cement bag',
          hsn: '2523',
          purchasePrice: 800,
          salePrice: 1000,
          gstRate: 18,
        );
    itemId = item.id;
  });

  tearDown(() => db.close());

  /// A party, optionally filed into a group.
  ///
  /// `PartyRepository.create` takes no `categoryId`, so grouping goes through
  /// `update` — which is also how the app itself does it, so the fixture cannot
  /// set up a state the UI could never reach.
  Future<String> party(
    String name, {
    String? categoryId,
    String? gstin,
    String? phone,
    String? city,
  }) async {
    final created = await parties.create(
      name: name,
      type: 'both',
      gstin: gstin,
      phone: phone,
      city: city,
    );
    if (categoryId != null) {
      await parties.update(created.copyWith(categoryId: Value(categoryId)));
    }
    return created.id;
  }

  Future<String> category(String name) =>
      db.itemRepositoryFor(firmId).createCategory(name, kind: 'party').then((c) => c.id);

  /// An invoice at 18% GST on ₹1,000 of goods, so ₹1,180 of invoice total.
  ///
  /// **Tax is the point of this fixture.** A report that used `grandTotal` where
  /// it should use `taxableValue` produces ₹1,180 here, and every expected value
  /// below is written as `taxable` so the difference is a visible 180 rather than
  /// something a reader has to notice.
  Future<void> invoice({
    required String id,
    required DateTime date,
    required String partyId,
    String quantity = '1',
    String rate = '1000',
    String docType = 'invoice',
    String? lineItemId,
    String? discount,
  }) async {
    await sales.save(
      SalesDraft(
        id: id,
        number: id.toUpperCase(),
        invoiceDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Customer',
        lines: [
          SalesLineDraft(
            id: '$id-l1',
            itemId: lineItemId ?? itemId,
            name: 'Cement bag',
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            discountAmount: discount == null ? null : Decimal.parse(discount),
            gstRate: 18,
          ),
        ],
      ),
    );
  }

  Future<void> bill({
    required String id,
    required DateTime date,
    required String partyId,
    String quantity = '1',
    String rate = '800',
    String docType = 'bill',
  }) async {
    await purchases.save(
      PurchaseDraft(
        id: id,
        number: id.toUpperCase(),
        billDate: date,
        docType: docType,
        partyId: partyId,
        partyName: 'Supplier',
        lines: [
          PurchaseLineDraft(
            id: '$id-l1',
            itemId: itemId,
            name: 'Cement bag',
            hsn: '2523',
            quantity: Decimal.parse(quantity),
            unit: 'bag',
            rate: Decimal.parse(rate),
            gstRate: 18,
          ),
        ],
      ),
    );
  }

  Future<ReportResult> run(String id, {Map<String, Object?> filters = const {}}) async {
    final definition = ReportCatalogue.byId(id);
    expect(definition, isNotNull, reason: 'no report registered as "$id"');
    return definition!.run(db, firmId, window, filters: filters);
  }

  Future<ReportResult> runFor(String id, String partyId) =>
      run(id, filters: {kPartyFilterId: partyId});

  /// The one row for [name], failing loudly when it is missing or duplicated.
  ///
  /// `firstWhere` alone would pass on a report that printed the party twice,
  /// which is exactly the shape of bug these reports are prone to — so the
  /// count is asserted as well as the value.
  Future<ReportRow> onlyRow(ReportResult result, String name) async {
    final matching = result.rows
        .where((r) => '${r.cells['party'] ?? r.cells['group']}' == name)
        .toList();
    expect(matching, hasLength(1), reason: 'expected exactly one "$name" row');
    return matching.single;
  }

  Decimal money(ReportResult result, String key) =>
      result.grandTotals[key] ?? Decimal.zero;

  // ============================================================
  group('the shared sign rule', () {
    test('a credit note reduces sales and a debit note reduces purchases', () async {
      // Plan rule 1, and the one every party report inherits through
      // `partyMoney`. A report that added a credit note would overstate revenue
      // by the returned amount, and would disagree with the P&L by the same
      // figure — which is the disagreement a CA finds first.
      final customer = await party('Ramu');
      final supplier = await party('BuildMart');

      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      // **Partial notes, not full-value ones.** A credit note for exactly the
      // invoice nets to zero, which is also what a report that *ignored* the sign
      // rule prints — so the fixture that proves the rule cannot also be the one
      // where both answers agree. Returning part of the sale is what leaves a
      // figure the two implementations disagree about.
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        rate: '400',
        docType: 'credit_note',
      );
      await bill(id: 'pb-1', date: DateTime(2026, 4, 10), partyId: supplier);
      await bill(
        id: 'dn-1',
        date: DateTime(2026, 4, 20),
        partyId: supplier,
        rate: '300',
        docType: 'debit_note',
      );

      final result = await run('party_wise_pnl');
      expect(money(result, 'sales'), Decimal.fromInt(600));
      expect(money(result, 'purchases'), Decimal.fromInt(500));
    });

    test('tax nets with the document, so a return does not inflate it', () async {
      // The value half of the sign rule and the tax half are separate bugs.
      // `taxable_value` is multiplied by the sign in `_collect`; the tax columns
      // are **stored positive** on every document and have to be signed in Dart
      // for the same reason. Adding an unsigned credit note's tax makes output
      // tax exceed what was ever collected, and a GSTR-1 built off this column
      // over-states the liability by exactly the returned amount.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        rate: '400',
        docType: 'credit_note',
      );

      final result = await runFor('sale_purchase_by_party', customer);
      final row = await onlyRow(result, 'Ramu');
      expect(row.number(_col('saleValue')), Decimal.fromInt(600));
      // ₹1,000 at 18% = 180; ₹400 at 18% = 72 returned; 180 − 72.
      expect(row.number(_col('saleTax')), Decimal.fromInt(108));
    });

    test('the two reports agree on the same documents', () async {
      // Party wise P&L and Sale Purchase By Party are two views of one
      // computation. If they ever sum differently it means one of them grew its
      // own query, and a reader comparing the two has no way to tell which is
      // right — so this is asserted on every summable column they share.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(id: 'inv-2', date: DateTime(2026, 5, 10), partyId: customer);

      final pnl = await run('party_wise_pnl');
      final twoWay = await run('sale_purchase_by_party');
      expect(money(pnl, 'sales'), money(twoWay, 'saleValue'));
      expect(money(pnl, 'purchases'), money(twoWay, 'purchaseValue'));
    });
  });

  // ============================================================
  group('Party Statement', () {
    test('it reports what the party owes, including tax', () async {
      // The deliberate divergence from every other report, and the reason the
      // statement is not re-derived here. A customer billed ₹1,180 at 18% owes
      // ₹1,180; printing ₹1,000 makes the document you send them wrong in the
      // one direction that causes a dispute.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final result = await runFor('party_statement', customer);
      expect(result.count, 1);
      expect(money(result, 'debit'), Decimal.fromInt(1180));
      expect(money(result, 'credit'), Decimal.zero);
    });

    test('a purchase is a credit, because we owe them', () async {
      final supplier = await party('BuildMart');
      await bill(id: 'pb-1', date: DateTime(2026, 4, 10), partyId: supplier);

      final result = await runFor('party_statement', supplier);
      // ₹800 + 18% = ₹944 owed to the supplier.
      expect(money(result, 'credit'), Decimal.fromInt(944));
      expect(money(result, 'debit'), Decimal.zero);
    });

    test('the running balance ends at the sum of the columns above it', () async {
      // The first thing a statement reader checks, and the last thing an
      // implementation can be trusted to get right. Asserted on the printed
      // figures rather than on the repository's own `closing`, because the
      // report re-derives the balance from the rounded Dr/Cr cells.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      await bill(id: 'pb-1', date: DateTime(2026, 4, 20), partyId: customer);

      final result = await runFor('party_statement', customer);
      final expected = result.rows.fold<Decimal>(
        Decimal.zero,
        (sum, r) => sum + r.number(_col('debit')) - r.number(_col('credit')),
      );
      final last = result.rows.last.number(_col('balance'));
      expect(
        last,
        expected,
        reason: 'the closing balance must equal opening + Σ(debit − credit)',
      );
    });

    test('with no party chosen it is empty, not a guess', () async {
      // A statement is a document addressed to one counterparty. Picking the
      // first party would produce a real-looking statement of the wrong
      // customer, which is worse than an empty screen that says "pick one".
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final result = await run('party_statement');
      expect(result.isEmpty, isTrue);
    });

    test('a party with nothing in the period says so rather than printing nil',
        () async {
      final customer = await party('Ramu');
      await party('Silent');

      final result = await runFor('party_statement', customer);
      expect(result.isEmpty, isTrue);
      expect(result.notes.join(' '), contains('No transactions'));
    });
  });

  // ============================================================
  group('Party wise P&L', () {
    test('profit is sales less cost, and the margin is on sales', () async {
      // The whole reason this report exists. Margin on the invoice *total*
      // would fold output GST into the denominator and understate every margin
      // by the tax rate.
      final customer = await party('Ramu');
      await bill(
        id: 'pb-1',
        date: DateTime(2026, 4, 1),
        partyId: await party('Supplier'),
      );
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        quantity: '2',
      );

      final result = await runFor('party_wise_pnl', customer);
      final row = await onlyRow(result, 'Ramu');
      expect(row.number(_col('sales')), Decimal.fromInt(2000));
      expect(row.number(_col('cogs')), Decimal.fromInt(1600));
      expect(row.number(_col('profit')), Decimal.fromInt(400));
      // 400 / 2000 = 20%. On the ₹2,360 total it would read 16.95%.
      expect(row.number(_col('margin')).round(scale: 2), Decimal.fromInt(20));
    });

    test('a supplier is a row even with no sales at all', () async {
      // Iterating only the sales map drops every supplier in the firm and makes
      // the Purchases total short by exactly them.
      final supplier = await party('BuildMart');
      await bill(id: 'pb-1', date: DateTime(2026, 4, 10), partyId: supplier);

      final result = await run('party_wise_pnl');
      final row = await onlyRow(result, 'BuildMart');
      expect(row.number(_col('sales')), Decimal.zero);
      expect(row.number(_col('purchases')), Decimal.fromInt(800));
      expect(money(result, 'purchases'), Decimal.fromInt(800));
    });

    test('an uncosted item is flagged, because 100% margin is not a result',
        () async {
      // Without a note, a firm whose items were never costed sees every customer
      // at 100% margin and concludes the business is wonderful.
      //
      // The item carries **no purchase price**, because an item that has one is
      // costed: `_recordMovement` falls back to `item.purchasePrice` when there
      // is no prior movement to average, which is a documented estimate rather
      // than a missing figure. Only a zero-cost item reaches the uncosted branch,
      // so the fixture has to be one.
      final free = await db
          .itemRepositoryFor(firmId)
          .create(name: 'Unsorted sample', hsn: '2523', gstRate: 18);
      final customer = await party('Ramu');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 10),
        partyId: customer,
        lineItemId: free.id,
      );

      final result = await runFor('party_wise_pnl', customer);
      expect(result.notes.join(' '), contains('No cost of goods recorded'));
      expect(result.notes.join(' '), contains('Ramu'));
    });

    test('the window is pushed into the query', () async {
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      await invoice(
        id: 'inv-out',
        date: DateTime(2026, 1, 10),
        partyId: customer,
      );

      final result = await runFor('party_wise_pnl', customer);
      // Only the April invoice; the January one is filtered in SQL, not dropped
      // after the fact.
      expect(money(result, 'sales'), Decimal.fromInt(1000));
    });
  });

  // ============================================================
  group('All parties', () {
    test('a party who did not trade is still listed', () async {
      // The difference between this report and Party wise P&L: a shopkeeper
      // asking "who are my customers" wants the master, and a report that hides
      // the quiet ones makes a customer who left look deleted.
      final active = await party('Ramu');
      await party('Quiet Customer');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: active);

      final result = await run('all_parties');
      expect(
        result.rows.map((r) => r.cells['party']),
        containsAll(<String>['Ramu', 'Quiet Customer']),
      );
    });

    test('a soft-deleted party is not listed', () async {
      final gone = await party('Deleted Customer');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: gone);
      await parties.delete(gone);

      final result = await run('all_parties');
      expect(
        result.rows.map((r) => r.cells['party']),
        isNot(contains('Deleted Customer')),
      );
    });

    test('outstanding is sales less purchases for the period', () async {
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);
      await bill(id: 'pb-1', date: DateTime(2026, 4, 10), partyId: customer);

      final result = await run('all_parties');
      final row = await onlyRow(result, 'Ramu');
      // ₹1,000 sold, ₹800 bought from the same party. Taxable both times.
      expect(row.number(_col('outstanding')), Decimal.fromInt(200));
    });
  });

  // ============================================================
  group('Party Report By Item', () {
    test('the quantity is netted, so a return does not inflate it', () async {
      // Plan rule 2, and here the damage lands on the quantity column — the one
      // a reader trusts most. Three sacks sold and one returned reads four if the
      // return is printed as a fresh row.
      final customer = await party('Ramu');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 10),
        partyId: customer,
        quantity: '3',
      );
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        quantity: '1',
        docType: 'credit_note',
      );

      final result = await runFor('party_report_by_item', customer);
      expect(result.count, 1, reason: 'one item, one row, however many documents');
      final row = result.rows.single;
      expect(row.number(_col('quantity')), Decimal.fromInt(2));
      expect(row.number(_col('value')), Decimal.fromInt(2000));
    });

    test('it groups by party, so each customer is a block', () async {
      final a = await party('Ramu');
      final b = await party('Sharma');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: a);
      await invoice(id: 'inv-2', date: DateTime(2026, 4, 12), partyId: b);

      final result = await run('party_report_by_item');
      expect(
        result.groups.map((g) => g.name).toSet(),
        {'Ramu', 'Sharma'},
      );
      // And each block foots to the total, which is what the group is for.
      final fromGroups = result.groups.fold<Decimal>(
        Decimal.zero,
        (sum, g) => sum + g.totalFor(_col('value')),
      );
      expect(fromGroups, money(result, 'value'));
    });

    test('the item name comes from the invoice, not the item master', () async {
      // An invoice is a historical document. Renaming the item today must not
      // rewrite what last quarter's paperwork says.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final items = db.itemRepositoryFor(firmId);
      await items.update(
        (await items.getById(itemId))!.copyWith(name: 'Cement bag XL'),
      );

      final result = await runFor('party_report_by_item', customer);
      expect(result.rows.single.cells['item'], 'Cement bag');
    });
  });

  // ============================================================
  group('Sale Purchase By Party', () {
    test('value and tax are separate columns, because a return is filed on the value', () async {
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final result = await runFor('sale_purchase_by_party', customer);
      final row = await onlyRow(result, 'Ramu');
      expect(row.number(_col('saleValue')), Decimal.fromInt(1000));
      expect(row.number(_col('saleTax')), Decimal.fromInt(180));
      // The discounted figure is a sale of ₹900, not ₹1,000, so a return built
      // from this column files the right amount.
    });

    test('discount is the line discount plus the invoice discount', () async {
      // Printing only `item_discount` understates it by the header discount on
      // every discounted invoice — which is exactly what `discountOf` exists to
      // stop a second source from getting wrong.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final result = await runFor('sale_purchase_by_party', customer);
      final row = await onlyRow(result, 'Ramu');
      // No discount on this fixture, so the column must read a real zero rather
      // than being absent — `assertIntegrity` treats an unfilled column as a
      // defect, and a reader treats a blank as "not calculated".
      expect(row.cells.containsKey('saleDiscount'), isTrue);
      expect(row.number(_col('saleDiscount')), Decimal.zero);
    });

    test('a credit note takes its discount back off, not adds it on', () async {
      // "Discount given" is a total across a period. A customer returning goods
      // has been given *less* discount over that period, not more — and if the
      // return's discount is added rather than subtracted, the one column in
      // this report that describes what the firm gave away reads high on exactly
      // the months where customers came back.
      final customer = await party('Ramu');
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 10),
        partyId: customer,
        discount: '100',
      );
      await invoice(
        id: 'cn-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        rate: '400',
        discount: '40',
        docType: 'credit_note',
      );

      final result = await runFor('sale_purchase_by_party', customer);
      final row = await onlyRow(result, 'Ramu');
      expect(row.number(_col('saleDiscount')), Decimal.fromInt(60));
    });
  });

  // ============================================================
  group('Sale Purchase By Party Group', () {
    test('a party with no group is reported, not dropped', () async {
      // `parties.categoryId` is nullable and null means nobody has classified
      // this customer yet. A roll-up that dropped them totals short by exactly
      // the parties nobody has got round to, with nothing to say so.
      final grouped = await party('Ramu', categoryId: await category('City'));
      final loose = await party('Unfiled');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: grouped);
      await invoice(id: 'inv-2', date: DateTime(2026, 4, 11), partyId: loose);

      final result = await run('sale_purchase_by_party_group');
      expect(
        result.rows.map((r) => r.cells['group']),
        containsAll(<String>['City', 'Ungrouped']),
      );
      // And the total is the whole business, not just the classified part.
      expect(money(result, 'saleValue'), Decimal.fromInt(2000));
    });

    test('ungrouped sorts last and is measured in a note', () async {
      // It is a to-do, not a segment, and it should not lead the table by
      // virtue of being the newest category nobody has tidied.
      final grouped = await party('Ramu', categoryId: await category('City'));
      final loose = await party('Unfiled');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: grouped);
      await invoice(
        id: 'inv-2',
        date: DateTime(2026, 4, 11),
        partyId: loose,
        quantity: '5',
      );

      final result = await run('sale_purchase_by_party_group');
      final names = result.rows.map((r) => r.cells['group']).toList();
      expect(names.last, 'Ungrouped');
      expect(result.notes.join(' '), contains('not filed into a group'));
      expect(result.notes.join(' '), contains('5000.00'));
    });

    test('the group totals equal the sum of their parties', () async {
      final city = await category('City');
      final a = await party('Ramu', categoryId: city);
      final b = await party('Sharma', categoryId: city);
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: a);
      await invoice(id: 'inv-2', date: DateTime(2026, 4, 12), partyId: b);

      final result = await run('sale_purchase_by_party_group');
      final group = result.rows.firstWhere((r) => r.cells['group'] == 'City');
      expect(group.number(_col('saleValue')), Decimal.fromInt(2000));
      expect(group.number(_col('parties')), Decimal.fromInt(2));
    });
  });

  // ============================================================
  group('the filter plumbing', () {
    test('every party report declares the party filter under one id', () async {
      // One id across the six, so the picker, the cache key and the export
      // header all read the same key and switching between two party reports
      // keeps the party.
      for (final id in const [
        'party_statement',
        'party_wise_pnl',
        'all_parties',
        'party_report_by_item',
        'sale_purchase_by_party',
        'sale_purchase_by_party_group',
      ]) {
        final spec = ReportCatalogue.byId(id)!.spec;
        expect(
          spec.hasFilters,
          isTrue,
          reason: '$id has no party picker, so it cannot be scoped to a party',
        );
        expect(spec.filterWithId(kPartyFilterId), isNotNull, reason: id);
      }
    });

    test('the options are the firm\'s live parties, in name order', () async {
      final b = await party('BuildMart');
      await party('Anand Stores');
      final deletedId = await party('Deleted Co');
      await parties.delete(deletedId);

      final definition = ReportCatalogue.byId('party_statement')!;
      final options = await definition.source.optionsFor(
        db,
        firmId,
        definition.spec,
        kPartyFilterId,
      );

      // Sorted, because "Anand" before "BuildMart" is the only order a reader
      // can scan; and the deleted one is gone, because offering it opens a
      // statement for somebody the user just removed.
      expect(options.map((o) => o.label), ['Anand Stores', 'BuildMart']);
      expect(options.first.value, isNot(b));
    });

    test('selecting a party re-runs the report rather than redrawing the old one',
        () async {
      // The cache key has to include the filter. Left out, the reader picks a
      // customer, sees the previous party's numbers, and has no way to tell.
      final a = await party('Ramu');
      final b = await party('Sharma');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: a);
      await invoice(
        id: 'inv-2',
        date: DateTime(2026, 4, 12),
        partyId: b,
        quantity: '3',
      );

      final ramu = await runFor('party_wise_pnl', a);
      final sharma = await runFor('party_wise_pnl', b);
      expect(money(ramu, 'sales'), Decimal.fromInt(1000));
      expect(money(sharma, 'sales'), Decimal.fromInt(3000));
    });

    testWidgets('the bar renders a picker and writes the choice back', (
      tester,
    ) async {
      // The screen had no filter row at all, so a party report was unusable:
      // the picker is the only way to reach the customer you mean.
      final customer = await party('Ramu');
      await invoice(id: 'inv-1', date: DateTime(2026, 4, 10), partyId: customer);

      final spec = ReportCatalogue.byId('party_wise_pnl')!.spec;
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          // The firm id is a `StateNotifierProvider` fed from the settings
          // repository, which is a whole persistence chain this widget does not
          // care about. Overriding it at the source is what keeps the test about
          // the picker rather than about booting the app's storage layer.
          activeFirmIdProvider.overrideWith(
            (ref) => ActiveFirmController(
              ref.watch(settingsRepositoryProvider),
              ref.watch(firmRepositoryProvider),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: ReportFilterBar(
                reportId: 'party_wise_pnl',
                spec: spec,
                filters: const {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Party'), findsOneWidget);
      // Opens on "All", because a report must not open scoped to a guess.
      expect(find.text('Every party'), findsOneWidget);

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ramu').last);
      await tester.pumpAndSettle();

      expect(
        container.read(reportFiltersProvider('party_wise_pnl'))[kPartyFilterId],
        customer,
        reason: 'the chosen party must reach the provider the result reads',
      );
    });

    testWidgets('a report with no filters renders no bar', (tester) async {
      final spec = ReportCatalogue.byId('sale')!.spec;
      expect(spec.hasFilters, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportFilterBar(
              reportId: 'sale',
              spec: spec,
              filters: const {},
            ),
          ),
        ),
      );
      expect(find.byType(DropdownButton<String>), findsNothing);
    });
  });

  // ============================================================
  group('the catalogue', () {
    test('all six party reports are built, not stubs', () async {
      final partyReports = ReportCatalogue.inCategory(
        ReportCategory.party,
      );
      expect(partyReports, hasLength(6));
      expect(
        partyReports.map((d) => d.spec.id),
        containsAll(<String>[
          'party_statement',
          'party_wise_pnl',
          'all_parties',
          'party_report_by_item',
          'sale_purchase_by_party',
          'sale_purchase_by_party_group',
        ]),
      );
    });

    test('every party report foots to its own columns', () async {
      // The integrity check the screen shows as a red banner. Run over all six
      // with real documents behind them, because a check that passes only on an
      // empty result proves nothing.
      // Full master data on the first party, because `All parties` declares GSTIN,
      // Phone and City and `assertIntegrity` rightly objects to a column no row
      // ever fills. Filling them here also proves those columns are read from the
      // master rather than left as decoration.
      final customer = await party(
        'Ramu',
        gstin: '29ABCDE1234F1Z5',
        phone: '9845012345',
        city: 'Bengaluru',
      );
      final supplier = await party('BuildMart');
      final city = await category('City');
      final grouped = await party('Grouped', categoryId: city);

      await bill(id: 'pb-1', date: DateTime(2026, 4, 1), partyId: supplier);
      await invoice(
        id: 'inv-1',
        date: DateTime(2026, 4, 20),
        partyId: customer,
        quantity: '2',
      );
      await invoice(id: 'inv-2', date: DateTime(2026, 5, 2), partyId: grouped);
      await db
          .paymentRepositoryFor(firmId)
          .create(
            type: 'payment_in',
            number: 'RCP-1',
            amount: 500,
            date: DateTime(2026, 5, 10),
            partyId: customer,
          );

      for (final id in const [
        'party_statement',
        'party_wise_pnl',
        'all_parties',
        'party_report_by_item',
        'sale_purchase_by_party',
        'sale_purchase_by_party_group',
      ]) {
        final result = await runFor(id, customer);
        final problems = ReportIntegrityChecks.assertIntegrity(result).problems;
        expect(problems, isEmpty, reason: '$id does not foot: $problems');
      }
    });
  });
}

ReportColumn _col(String key) => ReportColumn(key: key, label: key);
