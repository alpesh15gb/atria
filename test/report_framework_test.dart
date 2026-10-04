import 'package:atria/core/reports/catalogue/report_catalogue.dart';
import 'package:atria/core/reports/engine/report_result.dart';
import 'package:atria/core/reports/engine/report_runner.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';

/// The framework the 47 reports are built on.
///
/// The load-bearing claim is [ReportIntegrityChecks.assertIntegrity]: that a
/// report whose totals do not foot is *caught*, not printed. Nothing else in
/// this codebase checks a total — `report_repository` sums in `double`, and the
/// ledger and the P&L are two implementations that have silently disagreed — so
/// an integrity check that quietly passes everything is worse than none at all.
/// It gets its own group below, and **every one of those tests was proven to
/// fail with the check removed.**
void main() {
  final window = ReportWindow(
    preset: ReportWindowPreset.custom,
    from: DateTime(2026, 4, 1),
    to: DateTime(2026, 6, 30, 23, 59, 59),
  );

  const partySpec = ReportSpec(
    id: 'party_test',
    title: 'Sale Purchase By Party',
    category: 'Party',
    groupBy: ReportGroupBy.party,
    columns: [
      ReportColumn(key: 'date', label: 'Date', kind: ReportValueKind.date),
      ReportColumn(key: 'number', label: 'No.'),
      ReportColumn(key: 'party', label: 'Party'),
      ReportColumn(
        key: 'taxable',
        label: 'Taxable',
        kind: ReportValueKind.money,
      ),
      ReportColumn(
        key: 'tax',
        label: 'GST',
        kind: ReportValueKind.money,
        colorize: true,
      ),
    ],
  );

  ReportResult fold(List<ReportRow> rows, {ReportSpec? spec}) =>
      const ReportRunner().fold(
        spec: spec ?? partySpec,
        window: window,
        rows: rows,
        groupKeyOf: (row) => '${row.cells['party']}',
      );

  group('the catalogue', () {
    test('registers every report in the reference menu', () {
      // 9 transaction + 6 party + 6 GST + 11 item/stock + 2 business status +
      // 6 taxes + 3 expense + 2 order + 1 loan = 46.
      //
      // The plan calls this "47 reports". Its own category table sums to 46, and
      // the menu it transcribed sums to 46, so the headline figure was the
      // thing that was wrong, not the menu. Everything here is built from the
      // menu. **Do not "fix" this to 47 by inventing a 47th report.**
      expect(ReportCatalogue.all, hasLength(46));
      expect(ReportCatalogue.byCategory(), hasLength(9));
      expect(
        ReportCatalogue.inCategory(ReportCategory.transaction),
        hasLength(9),
      );
      expect(
        ReportCatalogue.inCategory(ReportCategory.itemStock),
        hasLength(11),
      );
      expect(ReportCatalogue.inCategory(ReportCategory.loan), hasLength(1));
    });

    test('every id is unique', () {
      // Two reports sharing an id means one route silently serves the other.
      final ids = ReportCatalogue.ids;
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('every report names one of the nine categories', () {
      for (final definition in ReportCatalogue.all) {
        expect(
          () => definition.category,
          returnsNormally,
          reason: '${definition.spec.id} has no category',
        );
      }
    });

    test('every report declares at least one summable column', () {
      // A report whose columns are all rates and percentages has a total row
      // of blanks, which is not a report — it is a table of numbers.
      for (final definition in ReportCatalogue.all) {
        expect(
          definition.spec.columns.any((c) => c.isSummable),
          isTrue,
          reason: '${definition.spec.id} has nothing to total',
        );
      }
    });

    test('the GSTR-2 slot ships as a 2A reconciliation, not a fake GSTR-2', () {
      // GSTR-2 is auto-populated by the portal from suppliers' returns. An app
      // cannot produce it, and a report that prints an empty GSTR-2 is a
      // return the operator might file.
      expect(ReportCatalogue.byId('gstr2'), isNull);
      expect(ReportCatalogue.byId('gstr2a_reconciliation'), isNotNull);
    });

    test('every report is registered, and what is built is counted honestly', () {
      // Registered-but-empty is honest; absent is a feature nobody asks twice.
      expect(ReportCatalogue.all, hasLength(46));

      // `implemented` is the number that has to be right. It grew from zero
      // when Transaction landed, and it must be exactly the set of categories
      // that are finished — so this asserts the Transaction set by name rather
      // than by count, and would catch a report quietly claiming to be built.
      expect(
        ReportCatalogue.implemented.map((d) => d.spec.id).toSet(),
        ReportCatalogue.inCategory(ReportCategory.transaction)
            .map((d) => d.spec.id)
            .toSet(),
      );
      expect(ReportCatalogue.implemented, hasLength(9));
    });
  });

  group('grouping and totalling', () {
    test('rows land in their group and the groups keep source order', () {
      final result = fold([
        ReportRow({
          'date': DateTime(2026, 4, 2),
          'number': 'INV-1',
          'party': 'Beti Foods',
          'taxable': Decimal.fromInt(1000),
          'tax': Decimal.fromInt(180),
        }),
        ReportRow({
          'date': DateTime(2026, 4, 3),
          'number': 'INV-2',
          'party': 'Anand Stores',
          'taxable': Decimal.fromInt(500),
          'tax': Decimal.fromInt(90),
        }),
        ReportRow({
          'date': DateTime(2026, 4, 4),
          'number': 'INV-3',
          'party': 'Beti Foods',
          'taxable': Decimal.fromInt(250),
          'tax': Decimal.fromInt(45),
        }),
      ]);

      expect(result.groups.map((g) => g.name), ['Beti Foods', 'Anand Stores']);
      expect(result.groups.first.rows, hasLength(2));
      expect(result.count, 3, reason: 'the header counts rows, not groups');
    });

    test('the grand total is the sum of the group subtotals', () {
      // Every declared column has to be present, or the integrity check is
      // right to complain — a row that omits `date` renders a blank date, and
      // a blank date in a statement is not a formatting problem.
      ReportRow row(String party, int amount) => ReportRow({
        'date': DateTime(2026, 4, 2),
        'number': 'INV-$party',
        'party': party,
        'taxable': Decimal.fromInt(amount),
        'tax': Decimal.fromInt((amount * 0.18).round()),
      });

      final result = fold([row('A', 1000), row('B', 500), row('C', 250)]);

      final taxable = partySpec.columns.firstWhere((c) => c.key == 'taxable');
      expect(result.grandTotalFor(taxable), Decimal.fromInt(1750));
      expect(result.groups.first.totalFor(taxable), Decimal.fromInt(1000));
      expect(ReportIntegrityChecks.assertIntegrity(result).isClean, isTrue);
    });

    test('an ungrouped report still totals, through one implicit group', () {
      // Otherwise an ungrouped table can be missing its own total row, and
      // "missing" and "zero" look the same on screen.
      final result = const ReportRunner().fold(
        spec: partySpec,
        window: window,
        rows: [
          ReportRow({'party': 'A', 'taxable': Decimal.fromInt(100)}),
          ReportRow({'party': 'B', 'taxable': Decimal.fromInt(200)}),
        ],
      );
      final taxable = partySpec.columns.firstWhere((c) => c.key == 'taxable');
      expect(result.groups, hasLength(1));
      expect(result.grandTotalFor(taxable), Decimal.fromInt(300));
    });

    test('a rate column is never summed', () {
      // "Total 18%" is not a number. Summing rates also invites the reader to
      // add the column up, which is meaningless.
      const spec = ReportSpec(
        id: 'rates',
        title: 'Item Wise Discount',
        category: 'Item/Stock',
        columns: [
          ReportColumn(key: 'item', label: 'Item'),
          ReportColumn(key: 'rate', label: 'Rate', kind: ReportValueKind.rate),
          ReportColumn(
            key: 'amount',
            label: 'Amount',
            kind: ReportValueKind.money,
          ),
        ],
      );
      expect(
        spec.columns.firstWhere((c) => c.key == 'rate').isSummable,
        isFalse,
      );
      expect(
        spec.columns.firstWhere((c) => c.key == 'amount').isSummable,
        isTrue,
      );
    });

    test('money columns are right-aligned and text columns are not', () {
      final money = partySpec.columns.firstWhere((c) => c.key == 'taxable');
      final text = partySpec.columns.firstWhere((c) => c.key == 'number');
      expect(money.effectiveAlign, ReportColumnAlign.right);
      expect(text.effectiveAlign, ReportColumnAlign.left);
    });
  });

  group('sorting', () {
    test('a money column sorts numerically, not lexically', () {
      // "1000" before "500" is the whole failure. A lexical sort puts the
      // biggest sale last, which is exactly what a top-ten report is for.
      const spec = ReportSpec(
        id: 'sorted',
        title: 'Top Sales',
        category: 'Transaction',
        sort: ReportSort(columnKey: 'taxable', descending: true),
        columns: [
          ReportColumn(key: 'party', label: 'Party'),
          ReportColumn(
            key: 'taxable',
            label: 'Taxable',
            kind: ReportValueKind.money,
          ),
        ],
      );
      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'party': 'B', 'taxable': Decimal.fromInt(500)}),
          ReportRow({'party': 'A', 'taxable': Decimal.fromInt(1000)}),
          ReportRow({'party': 'C', 'taxable': Decimal.fromInt(750)}),
        ],
      );
      expect(result.rows.map((r) => r.cells['party']), ['A', 'C', 'B']);
    });

    test('a source sort key wins over the cell text', () {
      // An HSN is 2, 4 or 6 digits with an optional letter suffix, so it has to
      // sort the way the chapter headings read: 12, 12A, 12B, 129 — not
      // lexically, which puts "129" before "12A" and scatters Table 12 across
      // three places. Only the source knows that, which is why the key is
      // separate from the cell.
      const spec = ReportSpec(
        id: 'hsn',
        title: 'Sale Summary By HSN',
        category: 'GST',
        sort: ReportSort(columnKey: 'hsn'),
        columns: [
          ReportColumn(key: 'hsn', label: 'HSN'),
          ReportColumn(
            key: 'taxable',
            label: 'Taxable',
            kind: ReportValueKind.money,
          ),
        ],
      );
      // The chapter prefix padded, then the full code — so 12 and 12A and 129
      // keep their document order.
      String hsnKey(ReportRow row) {
        final code = '${row.cells['hsn']}';
        final digits = code.replaceAll(RegExp(r'[^0-9]'), '');
        return '${digits.padLeft(6, '0')}$code';
      }

      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'hsn': '12B', 'taxable': Decimal.fromInt(1)}),
          ReportRow({'hsn': '129', 'taxable': Decimal.fromInt(3)}),
          ReportRow({'hsn': '12A', 'taxable': Decimal.fromInt(2)}),
        ],
        sortKeyOf: (row) => hsnKey(row),
      );
      expect(result.rows.map((r) => r.cells['hsn']), ['12A', '12B', '129']);

      // And without the key it is lexical, which is exactly what the key is
      // there to prevent. This is the failure, stated, so a reader can see what
      // the key buys.
      final without = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'hsn': '12B', 'taxable': Decimal.fromInt(1)}),
          ReportRow({'hsn': '129', 'taxable': Decimal.fromInt(3)}),
          ReportRow({'hsn': '12A', 'taxable': Decimal.fromInt(2)}),
        ],
      );
      expect(without.rows.map((r) => r.cells['hsn']), ['129', '12A', '12B']);
    });
  });

  group('the cache key', () {
    test('changes when the window changes', () {
      final other = ReportWindow(
        preset: ReportWindowPreset.custom,
        from: DateTime(2026, 7, 1),
        to: DateTime(2026, 9, 30, 23, 59, 59),
      );
      expect(
        partySpec.cacheKey(window, const {}),
        isNot(partySpec.cacheKey(other, const {})),
      );
    });

    test('changes when a filter changes', () {
      expect(
        partySpec.cacheKey(window, const {'party': 'A'}),
        isNot(partySpec.cacheKey(window, const {'party': 'B'})),
      );
    });

    test('does not change when the filter map is rebuilt in another order', () {
      // Two callers building the same filters in a different order are looking
      // at the same report; re-running it would drop the scroll position for
      // no reason.
      expect(
        partySpec.cacheKey(window, const {'a': 1, 'b': 2}),
        partySpec.cacheKey(window, const {'b': 2, 'a': 1}),
      );
    });
  });

  group('assertIntegrity has teeth', () {
    test('a correct report passes', () {
      final result = fold([
        ReportRow({
          'party': 'A',
          'number': 'INV-1',
          'date': DateTime(2026, 4, 2),
          'taxable': Decimal.fromInt(1000),
          'tax': Decimal.fromInt(180),
        }),
        ReportRow({
          'party': 'B',
          'number': 'INV-2',
          'date': DateTime(2026, 4, 3),
          'taxable': Decimal.fromInt(500),
          'tax': Decimal.fromInt(90),
        }),
      ]);
      expect(ReportIntegrityChecks.assertIntegrity(result).isClean, isTrue);
    });

    test('an off-by-one in a group subtotal is caught', () {
      // **The proof that this check is worth having.** A one-rupee error in one
      // of four groups is invisible on screen — the table looks right, the
      // total looks right — and it is exactly the fault a CA finds.
      const spec = ReportSpec(
        id: 'off_by_one',
        title: 'Off By One',
        category: 'Transaction',
        groupBy: ReportGroupBy.category,
        columns: [
          ReportColumn(key: 'name', label: 'Name'),
          ReportColumn(
            key: 'amount',
            label: 'Amount',
            kind: ReportValueKind.money,
          ),
        ],
      );
      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'name': 'A', 'amount': Decimal.fromInt(100)}),
          ReportRow({'name': 'B', 'amount': Decimal.fromInt(200)}),
          ReportRow({'name': 'C', 'amount': Decimal.fromInt(300)}),
          ReportRow({'name': 'D', 'amount': Decimal.fromInt(400)}),
        ],
        groupKeyOf: (row) => '${row.cells['name']}',
      );

      // Now the fault: one group's subtotal is a rupee high.
      final broken = ReportResult(
        spec: result.spec,
        window: result.window,
        count: result.count,
        groups: [
          for (final group in result.groups)
            group.name == 'B'
                ? ReportGroup(
                    name: group.name,
                    rows: group.rows,
                    totals: {'amount': Decimal.fromInt(201)},
                  )
                : group,
        ],
        grandTotals: {'amount': Decimal.fromInt(1000)},
      );

      final integrity = ReportIntegrityChecks.assertIntegrity(broken);
      expect(integrity.isClean, isFalse);
      expect(integrity.headline, contains('do not sum'));
    });

    test('a grand total that disagrees with its own groups is caught', () {
      const spec = ReportSpec(
        id: 'bad_total',
        title: 'Bad Total',
        category: 'Transaction',
        groupBy: ReportGroupBy.category,
        columns: [
          ReportColumn(key: 'name', label: 'Name'),
          ReportColumn(
            key: 'amount',
            label: 'Amount',
            kind: ReportValueKind.money,
          ),
        ],
      );
      final result = ReportResult(
        spec: spec,
        window: window,
        count: 2,
        groups: [
          ReportGroup(
            name: 'A',
            rows: [
              ReportRow({'name': 'A', 'amount': Decimal.fromInt(100)}),
            ],
            totals: {'amount': Decimal.fromInt(100)},
          ),
          ReportGroup(
            name: 'B',
            rows: [
              ReportRow({'name': 'B', 'amount': Decimal.fromInt(200)}),
            ],
            totals: {'amount': Decimal.fromInt(200)},
          ),
        ],
        // Says 500. The table below it adds to 300.
        grandTotals: {'amount': Decimal.fromInt(500)},
      );

      final integrity = ReportIntegrityChecks.assertIntegrity(result);
      expect(integrity.isClean, isFalse);
      expect(integrity.headline, contains('Amount subtotals (300)'));
      expect(integrity.headline, contains('total (500)'));
    });

    test('a declared column no row carries is caught', () {
      // A typo in a source's key renders a column of blanks that looks exactly
      // like a business with no data - the most expensive silent failure there
      // is, because there is nothing to notice.
      const spec = ReportSpec(
        id: 'typo',
        title: 'Typo',
        category: 'Transaction',
        columns: [
          ReportColumn(key: 'party', label: 'Party'),
          ReportColumn(
            key: 'netAmount',
            label: 'Net Amount',
            kind: ReportValueKind.money,
          ),
        ],
      );
      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'party': 'A', 'amount': Decimal.fromInt(100)}),
        ],
      );

      final integrity = ReportIntegrityChecks.assertIntegrity(result);
      expect(integrity.isClean, isFalse);
      // The *key*, not the label: the developer needs to know which key to fix,
      // and the label is what they will change in the wrong place.
      expect(
        integrity.problems.any((p) => p.contains('netAmount')),
        isTrue,
        reason: 'the message must name the key: $integrity',
      );
    });

    test('a column every row leaves null is caught', () {
      // Every row *has* the key, so coverage passes — but the column is blank,
      // which is the same failure one step further away and the one a reader is
      // most likely to believe.
      const spec = ReportSpec(
        id: 'empty_col',
        title: 'Empty Column',
        category: 'Transaction',
        columns: [
          ReportColumn(key: 'party', label: 'Party'),
          ReportColumn(
            key: 'gstin',
            label: 'GSTIN',
            kind: ReportValueKind.text,
          ),
        ],
      );
      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'party': 'A', 'gstin': null}),
          ReportRow({'party': 'B', 'gstin': null}),
        ],
      );

      final integrity = ReportIntegrityChecks.assertIntegrity(result);
      expect(integrity.isClean, isFalse);
      expect(integrity.headline, contains('GSTIN is declared'));
    });

    test('an empty report is clean', () {
      // "No rows" is a fact, not a fault — a company that has sold nothing this
      // quarter has a perfectly good zero-row report.
      final result = const ReportRunner().fold(
        spec: partySpec,
        window: window,
        rows: const [],
        groupKeyOf: (row) => '${row.cells['party']}',
      );
      expect(ReportIntegrityChecks.assertIntegrity(result).isClean, isTrue);
    });
  });

  group('row values', () {
    test('a negated column totals the way the reader sees it', () {
      // A purchase return is stored negative and should read as a positive
      // quantity of goods coming back. Summing the raw value would total the
      // group the wrong way round.
      const spec = ReportSpec(
        id: 'negated',
        title: 'Returns',
        category: 'Item/Stock',
        groupBy: ReportGroupBy.category,
        columns: [
          ReportColumn(key: 'name', label: 'Name'),
          ReportColumn(
            key: 'qty',
            label: 'Qty',
            kind: ReportValueKind.quantity,
            negate: true,
          ),
        ],
      );
      final result = const ReportRunner().fold(
        spec: spec,
        window: window,
        rows: [
          ReportRow({'name': 'A', 'qty': Decimal.fromInt(-5)}),
          ReportRow({'name': 'A', 'qty': Decimal.fromInt(-3)}),
        ],
        groupKeyOf: (row) => '${row.cells['name']}',
      );
      expect(result.grandTotalFor(spec.columns.last), Decimal.fromInt(8));
    });

    test('an export value carries no currency symbol', () {
      // A spreadsheet has to be able to sum the column.
      const column = ReportColumn(
        key: 'amount',
        label: 'Amount',
        kind: ReportValueKind.money,
      );
      final row = ReportRow({'amount': Decimal.fromInt(123456)});
      expect(row.export(column), '123456.00');
      expect(row.text(column), contains('1,23,456.00'));
    });

    test('a missing numeric cell totals as zero rather than throwing', () {
      // An optional column is null on some rows all the time; the report must
      // still render. The *declared* keys are checked by assertIntegrity, which
      // is where a genuinely absent column is an error.
      const column = ReportColumn(
        key: 'amount',
        label: 'Amount',
        kind: ReportValueKind.money,
      );
      expect(ReportRow(const {}).number(column), Decimal.zero);
      expect(ReportRow(const {'amount': null}).number(column), Decimal.zero);
    });
  });
}
