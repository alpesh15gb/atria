import 'package:flutter/material.dart';

import '../../core/database/repositories/party_repository.dart';
import '../../core/database/repositories/report_repository.dart';

/// Runs a party statement and re-runs it whenever that party's books move.
///
/// A statement is the one report whose whole value is being current: it is what
/// the shopkeeper reads off the counter before deciding to chase a bill. Both
/// statement screens live under the nav shell's `IndexedStack`, so they are
/// never rebuilt when a payment is recorded in another tab — and a plain
/// `FutureBuilder` makes it worse, handing the same already-completed future to
/// every rebuild, so it never recomputes at all.
///
/// The signal already exists: `PartyRepository.watchOutstandingChanges()` ticks
/// on parties, invoices, bills and payments. The parties list uses it for its
/// Outstanding column; these two statements did not.
class PartyStatementBuilder extends StatelessWidget {
  const PartyStatementBuilder({
    super.key,
    required this.repo,
    required this.query,
    required this.builder,
  });

  final PartyRepository repo;

  /// The read. Called on mount and again on every movement, so it must be a
  /// pure function of its arguments — named `query` because `build` is already
  /// the widget's own method.
  final Future<PartyStatement> Function() query;

  final Widget Function(BuildContext context, AsyncSnapshot<PartyStatement> snapshot)
      builder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      // `initialData` so the first frame is a loading state rather than an
      // `AsyncSnapshot` with neither data nor an error, which would flash the
      // builder's empty branch.
      initialData: 0,
      stream: repo.watchOutstandingChanges().map((_) => 0),
      builder: (context, _) => FutureBuilder<PartyStatement>(
        future: query(),
        builder: builder,
      ),
    );
  }
}
