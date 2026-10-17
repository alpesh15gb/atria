import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../../domain/member_role.dart';
import '../../utils/money.dart';
import 'bank_balance.dart';
import 'sync_mixin.dart';

class BankAccountRepository with SyncQueueMixin {
  BankAccountRepository(this.db, this.firmId);
  @override
  final AppDatabase db;
  final String firmId;

  Future<void> save(BankAccountsCompanion values) async {
    db.assertPermission(Permission.manageMasters);
    await db.transaction(() async {
      final id = values.id.value;
      final old = await (db.select(
        db.bankAccounts,
      )..where((a) => a.id.equals(id))).getSingleOrNull();
      if (old != null && old.firmId != firmId) {
        throw StateError('Account belongs to another business.');
      }
      final name = values.name.value.trim();
      final peers = await (db.select(
        db.bankAccounts,
      )..where((a) => a.firmId.equals(firmId))).get();
      if (peers.any(
        (a) => a.id != id && a.name.trim().toLowerCase() == name.toLowerCase(),
      )) {
        throw StateError('An account with this name already exists.');
      }
      var movement = Money.zero;
      final payments =
          await (db.select(db.payments)..where(
                (p) => p.firmId.equals(firmId) & p.bankAccountId.equals(id),
              ))
              .get();
      for (final payment in payments) {
        movement += Money.of(bankPaymentAmount(payment));
      }
      final opening = values.openingBalance.present
          ? Money.round2(Money.of(values.openingBalance.value)).toDouble()
          : Money.round2(Money.of(values.currentBalance.value) - movement)
                .toDouble();
      await db
          .into(db.bankAccounts)
          .insertOnConflictUpdate(
            values.copyWith(
              firmId: Value(firmId),
              openingBalance: Value(opening),
              updatedAt: Value(DateTime.now()),
            ),
          );
      await rebuildBankBalances(db, firmId);
      await _queue(id, old == null ? 'insert' : 'update');
    });
  }

  Future<void> archive(String id) async {
    db.assertPermission(Permission.manageMasters);
    await db.transaction(() async {
      await (db.update(
        db.bankAccounts,
      )..where((a) => a.id.equals(id) & a.firmId.equals(firmId))).write(
        BankAccountsCompanion(
          isArchived: const Value(true),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await _queue(id, 'update');
    });
  }

  Future<void> _queue(String id, String operation) async {
    final row = await (db.select(
      db.bankAccounts,
    )..where((a) => a.id.equals(id) & a.firmId.equals(firmId))).getSingle();
    await enqueue(
      firmId: firmId,
      entity: 'bank_accounts',
      entityId: id,
      operation: operation,
      payload: jsonEncode(row.toJson()),
    );
  }
}
