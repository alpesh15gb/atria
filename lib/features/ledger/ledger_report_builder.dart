import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/repositories/ledger_repository.dart';

/// Runs an expensive ledger query and re-runs it whenever the books move.
///
/// The ledger screens all live under the nav shell's `IndexedStack`, so they are
/// **never rebuilt** when a document is recorded in another tab — and a plain
/// `FutureBuilder` makes it worse, because even a rebuild hands it the same
/// already-completed future, which never recomputes. The Trial Balance, the
/// Balance Sheet and the account ledger therefore froze at whatever they first
/// read, for the life of the session: open the trial balance, record a ₹5,000
/// receipt from the Payments tab, come back, and the cash balance is unchanged.
///
/// The repository already publishes the right signal — `watchBookMovement()`
/// ticks on any of the seven posting tables — and `cashBankBalancesProvider`
/// uses it. This is that same wiring, given to the report bodies.
///
/// [build] runs once on mount and again on every tick; it must be a function of
/// its arguments only, not of anything captured at a particular moment.
class LedgerReportBuilder<T> extends ConsumerWidget {
  const LedgerReportBuilder({
    super.key,
    required this.repo,
    required this.query,
    required this.builder,
  });

  final LedgerRepository repo;

  /// The expensive read. Called on mount and again on every book movement, so
  /// it must be a pure function of its arguments — it is named `query` rather
  /// than `build` only because `build` is already the widget's own method.
  final Future<T> Function() query;

  final Widget Function(BuildContext context, AsyncSnapshot<T> snapshot) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<int>(
      // `initialData` so the first frame is a loading state rather than an
      // `AsyncSnapshot` with neither data nor an error — which would render the
      // builder's "no data" branch and flash.
      initialData: 0,
      stream: repo.watchBookMovement().map((_) => 0),
      builder: (context, movement) {
        return FutureBuilder<T>(future: query(), builder: builder);
      },
    );
  }
}
