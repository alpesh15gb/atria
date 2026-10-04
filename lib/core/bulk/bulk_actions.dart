import 'package:flutter/foundation.dart';

/// Which rows a bulk action applies to, and how big the pool they were chosen
/// from.
///
/// Kept as a plain immutable value with no Flutter or database dependency, so
/// the selection rules can be tested directly. The subtle ones are:
///
/// * **"Select all" means all *loaded*, not all *existing*.** There is no
///   pagination in this app's lists, so today those coincide — but a list that
///   caps its rows (Sales caps at 200) would make them differ, and an action
///   that silently operates on 200 of 4,000 rows while the toolbar says "all"
///   is how a shop loses a quarter's books' worth of confidence in the app.
///   [loadedCount] is carried so the UI can say "all 200 loaded" out loud
///   instead of implying more.
/// * **A selection is not automatically cleared when a row disappears.** If a
///   document is deleted from another screen while it is selected here, it
///   should not linger in the selection and then fail a bulk action with an
///   error nobody can act on. [pruned] is how the screen reconciles.
/// * **Selection survives a filter change only for rows still on screen.**
///   Ticking a row and then narrowing the list should not silently keep the
///   tick on something the operator can no longer see; [pruned] against the new
///   visible set is how that is enforced.
@immutable
class BulkSelection {
  const BulkSelection({this.ids = const {}, this.loadedCount = 0});

  /// Ids currently ticked.
  final Set<String> ids;

  /// How many rows the operator could have picked from. Used by "Select all"
  /// and to decide whether the toolbar's count is worth showing.
  final int loadedCount;

  bool get isEmpty => ids.isEmpty;

  bool get isNotEmpty => ids.isNotEmpty;

  int get count => ids.length;

  /// True when everything currently loaded is selected.
  ///
  /// Guarded on [loadedCount] so a list that has loaded nothing reports false
  /// rather than vacuously true — otherwise a screen with no rows would offer a
  /// "Select all" that claims success having selected nothing.
  bool get isAllLoaded => loadedCount > 0 && ids.length == loadedCount;

  bool contains(String id) => ids.contains(id);

  BulkSelection toggle(String id) {
    final next = Set<String>.from(ids);
    if (!next.remove(id)) next.add(id);
    return BulkSelection(ids: next, loadedCount: loadedCount);
  }

  /// Ticks everything loaded, or clears the whole selection if it already was
  /// everything. One control, two meanings — the same way a file manager's
  /// select-all checkbox behaves.
  BulkSelection toggleAll(Iterable<String> visibleIds) {
    if (isAllLoaded) return const BulkSelection();
    return BulkSelection(ids: visibleIds.toSet(), loadedCount: loadedCount);
  }

  BulkSelection cleared() => const BulkSelection();

  /// Drops any ticked id that is not in [visibleIds] any more.
  BulkSelection pruned(Set<String> visibleIds) {
    if (ids.isEmpty) return this;
    final next = ids.intersection(visibleIds);
    if (next.length == ids.length) return this;
    return BulkSelection(ids: next, loadedCount: loadedCount);
  }
}

/// Soft-deletes one row. Returns whether it **actually** did.
///
/// The boolean is not decoration. A repository method that quietly returns
/// `void` when handed an id it cannot find is correct for one delete — there is
/// nothing to report — and quietly wrong for two hundred, where the caller then
/// announces "12 invoices deleted" for 11 rows that changed and offers an undo
/// covering a document that was never touched. `false` is recorded as a failure
/// so the count the operator sees is the count that happened.
typedef SoftDeleteFn = Future<bool> Function(String id);

/// Puts one soft-deleted row back, returning whether it did.
typedef RestoreFn = Future<bool> Function(String id);

/// What a bulk delete actually did.
///
/// [deletedIds] is the record of fact, not of intent. A delete loop that keeps
/// going after a failure and then reports the requested count would tell an
/// operator that 12 invoices are safely in the recycle bin when 3 of them are
/// still live — and the undo would then "restore" rows that were never deleted,
/// which on a document number can mean a collision.
class BulkDeleteOutcome {
  const BulkDeleteOutcome({
    required this.requested,
    required this.deletedIds,
    required this.failures,
  });

  final int requested;

  /// The ids that were successfully soft-deleted. Safe to restore.
  final Set<String> deletedIds;

  /// Ids that could not be deleted, with the reason.
  final Map<String, Object> failures;

  int get deleted => deletedIds.length;

  int get failed => failures.length;

  bool get isCompleteSuccess => failures.isEmpty && deleted == requested;
}

/// Deletes many rows, one transaction per row, continuing past failures.
///
/// Why not one transaction around all of them: these soft-deletes reverse stock
/// and party balances, and a single failure halfway through a 200-row delete
/// would roll back the whole batch — leaving the operator with a button that
/// either works or does nothing at all, on documents they may have selected by
/// accident. Partial progress plus an accurate report is more useful than
/// all-or-nothing.
///
/// Failures are collected rather than thrown so one locked document does not
/// abandon the other 199. The caller decides how loudly to complain, using
/// [BulkDeleteOutcome.failures].
Future<BulkDeleteOutcome> bulkSoftDelete(
  List<String> ids,
  SoftDeleteFn softDelete,
) async {
  final deleted = <String>{};
  final failures = <String, Object>{};
  for (final id in ids) {
    try {
      if (await softDelete(id)) {
        deleted.add(id);
      } else {
        failures[id] = StateError('not found, or already in the recycle bin');
      }
    } catch (error) {
      failures[id] = error;
    }
  }
  return BulkDeleteOutcome(
    requested: ids.length,
    deletedIds: deleted,
    failures: failures,
  );
}

/// Undoes a [bulkSoftDelete], restoring only what it confirmed it deleted.
///
/// Same partial-failure contract in reverse: a restore that cannot complete is
/// reported, not swallowed, because "your invoices are back" followed by a
/// silent failure leaves documents split across two states with nobody aware.
Future<BulkDeleteOutcome> bulkRestore(
  Set<String> ids,
  RestoreFn restore,
) async {
  final restored = <String>{};
  final failures = <String, Object>{};
  for (final id in ids) {
    try {
      if (await restore(id)) {
        restored.add(id);
      } else {
        failures[id] = StateError('not found, or not in the recycle bin');
      }
    } catch (error) {
      failures[id] = error;
    }
  }
  return BulkDeleteOutcome(
    requested: ids.length,
    deletedIds: restored,
    failures: failures,
  );
}
