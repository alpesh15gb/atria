import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression cover for the boot gate.
///
/// Both startup controllers completed their readiness futures in a `finally`
/// block, so a database that failed to open still counted as "ready". The boot
/// gate then resolved, the router built on an unreadable database, and the app
/// crashed on its first real query. A failure must surface as a failure.
void main() {
  late ProviderContainer container;
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('a healthy database boots', () async {
    await expectLater(
      container.read(appInitializationProvider.future),
      completes,
    );
    expect(container.read(appInitializationProvider).hasError, isFalse);
  });

  test('a failed load rejects the boot gate instead of completing it',
      () async {
    container.dispose();
    db = AppDatabase.test(_FailingExecutor());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    await expectLater(
      container.read(appInitializationProvider.future),
      throwsA(isA<UnreadableBooksError>()),
    );
    final init = container.read(appInitializationProvider);
    expect(init.hasError, isTrue,
        reason: 'A failed boot has to be observable: `hasValue` false with no '
            'error is indistinguishable from "still loading", and the splash '
            'would spin forever.');
    // Onboarding is awaited first, so it is the controller that surfaces the
    // failure; the firm controller is never even constructed.
    expect(container.read(onboardingDoneProvider.notifier).initError,
        isA<UnreadableBooksError>());
  });

  test('the failure does not leave a half-loaded flag behind', () async {
    container.dispose();
    db = AppDatabase.test(_FailingExecutor());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );

    // The controller must not report a flag it never actually read: the boot
    // gate is the only thing standing between this state and a router that
    // sends a user with no books onto the dashboard.
    await container
        .read(appInitializationProvider.future)
        .catchError((_) => null);
    expect(container.read(onboardingDoneProvider), isFalse,
        reason: 'Onboarding never completed, so the flag must stay false.');
  });

  test('a retry after a transient failure reaches a ready state', () async {
    container.dispose();
    db = AppDatabase.test(_FailingExecutor());
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    await container
        .read(appInitializationProvider.future)
        .catchError((_) => null);

    // The recovery path rebuilds the controllers against a fresh database.
    final reopened = AppDatabase.test(NativeDatabase.memory());
    container.dispose();
    container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(reopened)],
    );

    await expectLater(
      container.read(appInitializationProvider.future),
      completes,
    );
    expect(container.read(appInitializationProvider).hasValue, isTrue);
    await reopened.close();
  });
}

/// Thrown by [_FailingExecutor] to stand in for a book file that will not open
/// — corrupt, locked by another instance, or on storage the OS won't let us
/// read. A distinct type keeps the assertions honest.
class UnreadableBooksError implements Exception {
  const UnreadableBooksError(this.reason);
  final String reason;

  @override
  String toString() => 'UnreadableBooksError: $reason';
}

/// A [QueryExecutor] whose every statement fails. Closing a real database does
/// not reproduce the bug (drift tolerates queries after close), so a genuinely
/// failing connection is needed.
class _FailingExecutor extends QueryExecutor {
  static const _error = UnreadableBooksError('the book file would not open');

  Never _fail() => throw _error;

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    _fail();
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
          String statement, List<Object?> args) async =>
      _fail();

  @override
  Future<int> runInsert(String statement, List<Object?> args) async => _fail();

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async => _fail();

  @override
  Future<int> runDelete(String statement, List<Object?> args) async => _fail();

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async =>
      _fail();

  @override
  Future<void> runBatched(BatchedStatements statements) async => _fail();

  @override
  TransactionExecutor beginTransaction() => _FailingTransactionExecutor();

  @override
  QueryExecutor beginExclusive() => _FailingTransactionExecutor();
}

class _FailingTransactionExecutor extends _FailingExecutor
    implements TransactionExecutor {
  @override
  bool get supportsNestedTransactions => false;

  @override
  Future<void> send() async {}

  @override
  Future<void> rollback() async {}
}
