import 'package:atria/core/bulk/bulk_actions.dart';
import 'package:flutter_test/flutter_test.dart';

/// The selection rules and the bulk-delete contract, tested directly.
///
/// These are the parts of bulk actions that are easy to get subtly wrong and
/// impossible to notice by using the app: a selection that keeps a row it can
/// no longer show, a "select all" that claims to cover rows nobody loaded, and
/// a delete that reports more rows than it touched.
void main() {
  group('BulkSelection', () {
    test('toggling adds once and removes once', () {
      const start = BulkSelection(loadedCount: 3);

      final ticked = start.toggle('a');
      expect(ticked.contains('a'), isTrue);
      expect(ticked.count, 1);

      final unticked = ticked.toggle('a');
      expect(unticked.contains('a'), isFalse);
      expect(unticked.isEmpty, isTrue);
    });

    test('the original selection is never mutated', () {
      // Immutable on purpose: a list widget rebuilds with the previous value
      // still on screen, and an in-place toggle would repaint rows that were
      // never asked about.
      const start = BulkSelection(loadedCount: 3);
      start.toggle('a');
      expect(start.isEmpty, isTrue);
      expect(start.loadedCount, 3);
    });

    test('a list that has loaded nothing is not "all selected"', () {
      // Vacuous truth: 0 of 0. Offering a ticked "select all" on an empty
      // list is a control that claims success having done nothing.
      const none = BulkSelection();
      expect(none.isAllLoaded, isFalse);
      expect(none.isNotEmpty, isFalse);
    });

    test('select all ticks everything, and doing it again clears', () {
      const start = BulkSelection(loadedCount: 3);
      const visible = ['a', 'b', 'c'];

      final all = start.toggleAll(visible);
      expect(all.count, 3);
      expect(all.isAllLoaded, isTrue);

      expect(
        all.toggleAll(visible).isEmpty,
        isTrue,
        reason: 'the same control unticks when everything is already ticked',
      );
    });

    test('select all says how many rows it actually covers', () {
      // "Select all" on a list that capped its rows means "all 200 loaded", and
      // the bar has to be able to say so rather than implying 4,000.
      const start = BulkSelection(loadedCount: 200);
      final all = start.toggleAll(List.generate(200, (i) => 'id-$i'));
      expect(all.count, 200);
      expect(all.loadedCount, 200);
    });

    test('a partial selection is not all-loaded', () {
      const partial = BulkSelection(ids: {'a', 'b'}, loadedCount: 5);
      expect(partial.isAllLoaded, isFalse);
      // …and select-all must therefore still be offered rather than clearing.
      final grown = partial.toggleAll(['a', 'b', 'c', 'd', 'e']);
      expect(grown.count, 5);
    });

    test('rows that disappeared are dropped from the selection', () {
      // A document deleted elsewhere must not linger here and then fail the
      // bulk action with an error the operator cannot act on.
      const start = BulkSelection(ids: {'a', 'gone'}, loadedCount: 2);
      final pruned = start.pruned({'a'});
      expect(pruned.contains('gone'), isFalse);
      expect(pruned.contains('a'), isTrue);
    });

    test('pruning an already-correct selection returns the same value', () {
      // Let the screen decide "nothing to do" by identity, so a rebuild does
      // not churn through setState for every keystroke in the search field.
      const start = BulkSelection(ids: {'a', 'b'}, loadedCount: 2);
      expect(identical(start.pruned({'a', 'b'}), start), isTrue);
    });

    test('narrowing the filter drops ticks the operator can no longer see', () {
      // The trap: tick two rows, then search. The hidden tick survives and
      // silently joins the next bulk action.
      const start = BulkSelection(ids: {'a', 'z'}, loadedCount: 2);
      final afterSearch = start.pruned({'a'});
      expect(afterSearch.count, 1);
    });

    test('clear returns a genuinely empty selection', () {
      const start = BulkSelection(ids: {'a', 'b'}, loadedCount: 2);
      final cleared = start.cleared();
      expect(cleared.isEmpty, isTrue);
      expect(cleared.count, 0);
    });
  });

  group('bulkSoftDelete', () {
    test('every id is deleted and reported', () async {
      final done = <String>[];
      final outcome = await bulkSoftDelete(['a', 'b', 'c'], (id) async {
        done.add(id);
        return true;
      });

      expect(done, ['a', 'b', 'c']);
      expect(outcome.deleted, 3);
      expect(outcome.failed, 0);
      expect(outcome.isCompleteSuccess, isTrue);
      expect(outcome.deletedIds, {'a', 'b', 'c'});
    });

    test('one failure does not abandon the rest', () async {
      // A single locked period or a document with a broken line must not stop
      // the other 199 from being deleted — the operator asked for all of them.
      final attempted = <String>[];
      final outcome = await bulkSoftDelete(['a', 'bad', 'c'], (id) async {
        attempted.add(id);
        if (id == 'bad') throw StateError('locked period');
        return true;
      });

      expect(attempted, ['a', 'bad', 'c'], reason: 'the loop must continue');
      expect(outcome.deleted, 2);
      expect(outcome.failed, 1);
      expect(outcome.deletedIds, {'a', 'c'});
      expect(outcome.failures['bad'], isA<StateError>());
    });

    test('a partial delete is never reported as complete', () {
      // The failure mode this whole class exists to prevent: reporting the
      // requested count when some rows are still live in the books.
      final outcome = bulkSoftDelete(['a', 'bad'], (id) async {
        if (id == 'bad') throw StateError('nope');
        return true;
      });
      return outcome.then((o) {
        expect(o.isCompleteSuccess, isFalse);
        expect(o.requested, 2);
        expect(o.deleted, 1);
      });
    });

    test('undo is only offered for rows it confirmed deleting', () async {
      // Restoring a row that was never deleted can collide with the document
      // number of a live one.
      final outcome = await bulkSoftDelete(['a', 'bad'], (id) async {
        if (id == 'bad') throw StateError('nope');
        return true;
      });
      // The caller undoes outcome.deletedIds, never the ids it asked for.
      expect(outcome.deletedIds.contains('bad'), isFalse);
    });

    test('an empty selection deletes nothing and succeeds trivially', () async {
      var calls = 0;
      final outcome = await bulkSoftDelete([], (id) async {
        calls++;
        return true;
      });
      expect(calls, 0);
      expect(outcome.requested, 0);
      expect(outcome.isCompleteSuccess, isTrue);
    });

    test('a delete that changed nothing is a failure, not a success', () async {
      // This is the whole reason the callback returns a bool. SalesRepository
      // .softDelete returns quietly for an id that is not in the books — fine
      // for one delete, and a lie for two hundred: the operator would be told
      // "12 invoices deleted" for 11 rows that changed, and offered an undo
      // covering a document that was never touched.
      final outcome = await bulkSoftDelete(['a', 'ghost'], (id) async {
        return id == 'a';
      });

      expect(outcome.deleted, 1);
      expect(outcome.failed, 1);
      expect(outcome.isCompleteSuccess, isFalse);
      expect(outcome.deletedIds, {'a'});
      expect(outcome.failures['ghost'], isA<StateError>());
    });

    test('ids are deleted in the order given', () async {
      final order = <String>[];
      await bulkSoftDelete(['z', 'a', 'm'], (id) async {
        order.add(id);
        return true;
      });
      expect(order, [
        'z',
        'a',
        'm',
      ], reason: 'the first ids are the ones the operator saw first');
    });
  });

  group('bulkRestore', () {
    test('restores exactly what it is given', () async {
      final back = <String>[];
      final outcome = await bulkRestore({'a', 'b'}, (id) async {
        back.add(id);
        return true;
      });
      expect(back..sort(), ['a', 'b']);
      expect(outcome.deleted, 2);
      expect(outcome.isCompleteSuccess, isTrue);
    });

    test('a restore that cannot finish is reported, not swallowed', () async {
      // "Your invoices are back" followed by a silent failure leaves documents
      // split across two states with nobody aware.
      final outcome = await bulkRestore({'a', 'bad'}, (id) async {
        if (id == 'bad') throw StateError('already purged');
        return true;
      });
      expect(outcome.deleted, 1);
      expect(outcome.failed, 1);
      expect(outcome.failures['bad'], isA<StateError>());
    });
  });
}
