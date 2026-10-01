import 'package:drift/drift.dart';

import '../api/server_client.dart' show ServerRequestException;
import '../api/sync_client.dart';
import '../database/app_database.dart';
import '../database/repositories/settings_repository.dart';
import '../state/auth_controller.dart';
import 'pull_applier.dart';

/// The outcome of one sync run, shaped for both a UI line and a log line.
class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.pulled = 0,
    this.pending = 0,
    this.skipped = false,
    this.needsSignIn = false,
    this.error,
    this.at,
  });

  /// Outbox rows marked as sent by this run.
  final int pushed;

  /// Journal changes applied into the local database by this run.
  final int pulled;

  /// Rows still waiting, after this run.
  final int pending;

  /// True when the sync switch is off and nothing was attempted.
  final bool skipped;

  /// True when there is no usable session: the outbox is untouched and will
  /// drain once the device is signed in again.
  final bool needsSignIn;

  /// Why the sync stopped, in words worth showing. Null when it finished.
  final String? error;

  /// When the run finished, for "last synced" display.
  final DateTime? at;

  bool get ok => error == null && !needsSignIn;

  /// A one-line summary for the settings screen.
  String get describe {
    if (skipped) return 'Sync is switched off.';
    if (needsSignIn) return 'Sign in to Atria to sync.';
    if (error != null) return error!;
    if (pushed == 0 && pulled == 0 && pending == 0) {
      return 'Everything is already synced.';
    }
    final parts = <String>[
      if (pushed > 0) 'sent $pushed',
      if (pulled > 0) 'received $pulled',
    ];
    if (parts.isEmpty) {
      return pending > 0
          ? 'Sent 0 change(s); $pending still waiting.'
          : 'Everything is already synced.';
    }
    return 'Synced: ${parts.join(', ')} change(s).'
        '${pending > 0 ? ' $pending still waiting to be sent.' : ''}';
  }
}

/// The outcome of a restore attempt, shaped for the onboarding panel.
class RestoreReport {
  const RestoreReport({required this.restored, required this.describe});

  /// True when the firm row landed locally and the books can be opened.
  final bool restored;

  /// What happened, in words worth showing as-is.
  final String describe;
}

/// Drains the local outbox and replays the firm's journal.
///
/// This is the whole of sync: **push** sends what this device did; **pull**
/// replays what other devices did, ordered by the server's per-firm sequence.
/// One run is push-then-pull — pushing first means a pull can never make this
/// device forget a local change that had not yet left.
///
/// Merge policy on the pull side is row-level last-write-wins on `updated_at`
/// (see [PullApplier]). The server arbitrates nothing: it stores a journal, and
/// the journal's order plus each row's `updated_at` is the whole algorithm.
/// That is deliberately the simplest rule that cannot lose a *newer* edit, and
/// it is stated once, in one class, rather than smeared across the UI.
///
/// Three rules make it safe to run at any moment:
///
/// * **Order is preserved.** Rows are drained in `createdAt, id` order, which is
///   the order they were enqueued, so a create is never sent after the update
///   that changed it. A batch that fails stops the run rather than skipping
///   ahead, because a hole in that order is exactly what breaks the server's
///   replay later.
/// * **Runs are idempotent.** Each row's own id travels as the server's
///   idempotency key, so a batch that landed but timed out on the way back is
///   simply reported as duplicates on the retry.
/// * **Failure is recorded, not lost.** A failed batch increments `attempts` and
///   writes the reason on the affected rows, so a repeatedly failing change is
///   visible in the outbox rather than an invisible brick wall.
class SyncEngine {
  SyncEngine(this._db, this._settings, this._auth, this._client);

  final AppDatabase _db;
  final SettingsRepository _settings;
  final AuthController _auth;
  final SyncClient _client;

  /// How many changes one push carries.
  ///
  /// Well under the server's 500 cap, so a device that was offline for a month
  /// still sends several batches in one run instead of one enormous request
  /// that either times out or hits the body limit.
  static const int batchSize = 200;

  /// The order the firm's tables are journalled in: every parent before the
  /// children that reference it. The pull replays changes in this order and
  /// skips a child whose parent has not applied yet — permanently, because
  /// the cursor advances regardless — so drain order is a correctness rule,
  /// not a nicety.
  static const List<String> journalOrder = [
    'firms',
    'categories',
    'units',
    'parties',
    'items',
    'sales_invoices',
    'sales_invoice_items',
    'purchase_bills',
    'purchase_bill_items',
    'payments',
    'expenses',
    'accounts',
    'journal_entries',
    'journal_lines',
    'stock_movements',
  ];

  /// Re-enqueues every live row of [firmId] into the outbox, so the next push
  /// re-journals the whole firm and every other device re-pulls the complete
  /// books.
  ///
  /// The recovery tool for a journal that is missing rows. The case that
  /// earned it: books born under a build that only journalled document
  /// parents — the server's journal then held invoices with their totals but
  /// not their lines, and every restore rebuilt that half-state on every
  /// device. The origin device still holds the complete data, so replaying
  /// its rows into the journal heals all of them at once.
  ///
  /// Row shapes make this safe to run against any journal state: parents are
  /// applied last-write-wins on `updated_at`, children insert-if-absent —
  /// so re-delivering rows a device already has changes nothing, and a row
  /// another device edited more recently is not clobbered.
  ///
  /// Rows are enqueued in [journalOrder] (parents before children), each with
  /// a deterministic id, so running this twice cannot double-send: the second
  /// run's inserts simply collide with the first's and are ignored.
  ///
  /// Returns how many outbox rows were newly enqueued.
  Future<int> rejournalEverything({required String firmId}) async {
    var enqueued = 0;
    for (final entity in journalOrder) {
      final table = _tableNamed(entity);
      if (table == null) continue;

      // Only rows that belong to the firm and are live. Soft-deleted rows are
      // skipped deliberately: their deletion already travelled as a payload
      // with is_deleted set, and re-sending them would resurrect nothing but
      // doubt. The child tables have no firm_id of their own — they are
      // reached through the parent row they hang from.
      final hasDeleted = table.columnsByName.containsKey('is_deleted');
      final hasFirm = table.columnsByName.containsKey('firm_id');
      final String sql;
      if (entity == 'firms') {
        sql = 'SELECT id FROM ${table.actualTableName} WHERE id = ?';
      } else if (hasFirm) {
        sql = 'SELECT id FROM ${table.actualTableName} WHERE firm_id = ?'
            '${hasDeleted ? ' AND is_deleted = 0' : ''}';
      } else {
        switch (entity) {
          case 'sales_invoice_items':
            sql = 'SELECT c.id FROM sales_invoice_items c '
                'JOIN sales_invoices p ON p.id = c.invoice_id '
                'WHERE p.firm_id = ? AND p.is_deleted = 0'
                '${hasDeleted ? ' AND c.is_deleted = 0' : ''}';
          case 'purchase_bill_items':
            sql = 'SELECT c.id FROM purchase_bill_items c '
                'JOIN purchase_bills p ON p.id = c.bill_id '
                'WHERE p.firm_id = ? AND p.is_deleted = 0'
                '${hasDeleted ? ' AND c.is_deleted = 0' : ''}';
          case 'journal_lines':
            sql = 'SELECT c.id FROM journal_lines c '
                'JOIN journal_entries p ON p.id = c.entry_id '
                'WHERE p.firm_id = ?';
          default:
            continue;
        }
      }

      final ids = await _db
          .customSelect(sql, variables: [Variable.withString(firmId)])
          .get();
      for (final row in ids) {
        final entityId = row.data['id'] as String;
        final queueId = 'rejournal_${entity}_$entityId';
        // Deterministic id, so a second run of the repair cannot double-send:
        // anything already queued (from the first run, or a still-pending
        // ordinary change for the same row) is left as it is.
        final already = await (_db.select(_db.syncQueue)
              ..where((t) => t.id.equals(queueId)))
            .getSingleOrNull();
        if (already != null) continue;
        await _db.into(_db.syncQueue).insert(
              SyncQueueCompanion.insert(
                id: queueId,
                firmId: Value(firmId),
                entity: entity,
                entityId: entityId,
                operation: 'insert',
              ),
            );
        enqueued++;
      }
    }
    return enqueued;
  }

  /// How long a *sent* outbox row is kept before being pruned.
  ///
  /// Not deleted immediately: the queue is the only record on the device of
  /// what has been sent, and a support question a week later ("did my March
  /// invoice reach the server?") is answerable from it. After that it is dead
  /// weight.
  static const Duration keepSentFor = Duration(days: 14);

  /// One drain attempt: pushes everything queued, oldest first.
  ///
  /// Honours the sync switch rather than taking a "force" flag: there is no
  /// caller that should be able to send a shop's books to a server the operator
  /// has switched off, and a parameter that exists to be ignored is a trap.
  Future<SyncReport> push() async {
    final now = DateTime.now();

    if (!(await _settings.getBool(SettingsRepository.kSyncEnabled))) {
      return SyncReport(skipped: true, pending: await pendingCount(), at: now);
    }

    final accessToken = await _auth.accessToken();
    if (accessToken == null) {
      return SyncReport(
        needsSignIn: true,
        pending: await pendingCount(),
        at: now,
      );
    }

    var pushed = 0;
    String? error;
    try {
      while (true) {
        final batch = await _nextBatch();
        if (batch.isEmpty) break;

        // Everything in one batch belongs to one firm (the outbox row carries
        // it), but a device with two businesses open has rows for both. Group
        // per firm so each push carries the right id.
        final firmId = batch.first.firmId;
        if (firmId == null || firmId.isEmpty) {
          // Nothing to attach it to. Retiring these is the honest move: they
          // can never succeed, and leaving them means every future run reads
          // them again.
          await _retireUnsendable(
            batch.where((r) => r.firmId == null || r.firmId!.isEmpty).toList(),
            'No business is attached to this change.',
          );
          continue;
        }

        final sameFirm =
            batch.where((r) => r.firmId == firmId).toList(growable: false);
        final ids = sameFirm.map((r) => r.id).toList(growable: false);

        await _ensureFirmRegistered(firmId, accessToken);

        final changes = <Map<String, Object?>>[];
        for (final row in sameFirm) {
          changes.add(await _encode(row));
        }

        try {
          await _client.pushChanges(
            firmId: firmId,
            accessToken: accessToken,
            changes: changes,
          );
        } on Object catch (failure) {
          // Record why on the exact rows that did not go, then stop the run.
          // The next attempt retries this same batch first — a hole in the
          // order is what would break a replay later.
          await _recordFailure(ids, '$failure');
          rethrow;
        }
        await _markSent(ids);
        pushed += sameFirm.length;
      }
    } on ServerRequestException catch (failure) {
      error = failure.signedOut
          ? 'Atria no longer accepts this device\'s session. Sign in again to '
              'resume syncing.'
          : failure.message;
    } on Object catch (failure) {
      error = 'Sync stopped: $failure';
    }

    final at = DateTime.now();
    final pending = await pendingCount();
    if (error == null) {
      await _settings.set(
        SettingsRepository.kSyncLastPushedAt,
        at.toUtc().toIso8601String(),
      );
      await pruneSent();
    }
    return SyncReport(
      pushed: pushed,
      pending: pending,
      error: error,
      at: at,
    );
  }

  /// One full sync: push this device's outbox, then pull the firm's journal.
  ///
  /// Honours the sync switch like [push] does. A pull failure is reported but
  /// does not roll back the push — the two directions are independent, and the
  /// next run resumes the pull from the stored cursor.
  Future<SyncReport> sync() async {
    if (!(await _settings.getBool(SettingsRepository.kSyncEnabled))) {
      return SyncReport(
        skipped: true,
        pending: await pendingCount(),
        at: DateTime.now(),
      );
    }

    final pushReport = await push();
    if (pushReport.needsSignIn || pushReport.skipped) return pushReport;

    // A device can belong to firms this install has never opened (restore
    // created one while another was active) — pull for every firm the outbox
    // has ever mentioned plus the active one, deduplicated.
    final firmIds = <String>{...await _knownFirmIds()};
    var pulled = 0;
    String? pullError;
    for (final firmId in firmIds) {
      try {
        pulled += await _pullFirm(firmId);
      } on ServerRequestException catch (failure) {
        pullError = failure.signedOut
            ? 'Atria no longer accepts this device\'s session. Sign in again to '
                'resume syncing.'
            : failure.message;
        break;
      } on Object catch (failure) {
        pullError = 'Sync stopped while receiving: $failure';
        break;
      }
    }

    final at = DateTime.now();
    if (pullError == null) {
      await _settings.set(
        SettingsRepository.kSyncLastSyncedAt,
        at.toUtc().toIso8601String(),
      );
    }
    return SyncReport(
      pushed: pushReport.pushed,
      pulled: pulled,
      pending: pushReport.pending,
      error: pullError ?? pushReport.error,
      at: at,
    );
  }

  /// Restores one firm's books onto this device by replaying its journal.
  ///
  /// Used by onboarding on a second device: sign in, pick the business, and
  /// its whole history arrives through the same journal the steady-state sync
  /// uses — one code path, one set of merge rules.
  ///
  /// The pull loop is the same as [_pullFirm] but bypasses the sync switch and
  /// the per-firm cursor only after success: restoring onto an empty device
  /// must work with sync switched off (the switch governs background sync,
  /// not an action the person pressed), and a half-restored books database
  /// must not look like a complete one.
  Future<RestoreReport> restoreFirm(String firmId) async {
    final accessToken = await _auth.accessToken();
    if (accessToken == null) {
      return const RestoreReport(
        restored: false,
        describe: 'Your session has expired. Sign in again.',
      );
    }

    try {
      final applier = PullApplier(_db);
      var afterSeq = await _settings.getInt('sync_cursor_$firmId') ?? 0;
      var appliedTotal = 0;

      var hasMore = true;
      while (hasMore) {
        final page = await _client.pullChanges(
          firmId: firmId,
          accessToken: accessToken,
          afterSeq: afterSeq,
        );
        if (page.changes.isNotEmpty) {
          final report = await applier.applyPage(firmId: firmId, page: page);
          appliedTotal += report.applied;
          if (report.highestSeq > afterSeq) afterSeq = report.highestSeq;
        }
        hasMore = page.hasMore;
        if (hasMore && page.changes.isEmpty) break;
      }

      // The cursor is written only on success, like [_pullFirm].
      if (afterSeq > 0) {
        await _settings.setInt('sync_cursor_$firmId', afterSeq);
      }

      final firmRow = await (_db.select(_db.firms)
            ..where((t) => t.id.equals(firmId)))
          .getSingleOrNull();
      if (firmRow == null) {
        // The journal never carried this firm's insert — the original device
        // created it but never pushed (sync was off, or the server address
        // changed). Say so rather than opening books that look emptied.
        return RestoreReport(
          restored: false,
          describe: 'The server has no books for that business yet. On the '
              'device that has them, turn sync on in Settings and press '
              '"Send now" first.',
        );
      }

      await _settings.set(
        SettingsRepository.kSyncRegisteredFirms,
        // Registering is push-side state: after a restore, this device will
        // push to this firm too, and _ensureFirmRegistered's 409-as-success
        // makes a re-register harmless.
        await _registeredFirmsWith(firmId),
      );
      await _settings.setBool(SettingsRepository.kSyncEnabled, true);

      return RestoreReport(
        restored: true,
        describe:
            'Restored ${firmRow.name} ($appliedTotal change(s) received).',
      );
    } on ServerRequestException catch (failure) {
      return RestoreReport(
        restored: false,
        describe: failure.signedOut
            ? 'Your session has expired. Sign in again.'
            : failure.message,
      );
    } on Object catch (failure) {
      return RestoreReport(restored: false, describe: 'Restore failed: $failure');
    }
  }

  /// Appends [firmId] to the registered-firms setting. Read-modify-write of
  /// a value only the sync flows touch.
  Future<String> _registeredFirmsWith(String firmId) async {
    final raw = await _settings.get(SettingsRepository.kSyncRegisteredFirms);
    final existing =
        (raw ?? '').split(',').map((id) => id.trim()).where(idNotEmpty).toSet();
    existing.add(firmId);
    return existing.join(',');
  }

  static bool idNotEmpty(String id) => id.isNotEmpty;

  /// Every firm this device has local books for. The outbox mentions firms by
  /// id; the firms table is the other source.
  Future<Set<String>> _knownFirmIds() async {
    final ids = <String>{};
    final firmRows = await _db.select(_db.firms).get();
    ids.addAll(firmRows.map((f) => f.id));
    final queued = await _db.select(_db.syncQueue)
        .get();
    for (final row in queued) {
      final id = row.firmId;
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// Replays one firm's journal from the stored cursor. Returns the number of
  /// changes applied.
  Future<int> _pullFirm(String firmId) async {
    final accessToken = await _auth.accessToken();
    if (accessToken == null) return 0;

    final cursorKey = 'sync_cursor_$firmId';
    var afterSeq = await _settings.getInt(cursorKey) ?? 0;

    final applier = PullApplier(_db);
    var appliedTotal = 0;

    // The loop's exit is the server's `hasMore`, not a local count: a journal
    // exactly one page long must not take a second round trip, and a journal
    // exactly N pages long must not stop one page early.
    var hasMore = true;
    while (hasMore) {
      final page = await _client.pullChanges(
        firmId: firmId,
        accessToken: accessToken,
        afterSeq: afterSeq,
      );
      if (page.changes.isNotEmpty) {
        // The cursor must advance *after* the writes land: a crash between
        // them re-applies a page (children are insert-if-absent, parents are
        // last-write-wins — both idempotent), whereas a cursor advanced first
        // would silently skip a page for ever.
        final report = await applier.applyPage(firmId: firmId, page: page);
        appliedTotal += report.applied;
        if (report.highestSeq > afterSeq) afterSeq = report.highestSeq;
      }
      hasMore = page.hasMore;
      if (hasMore && page.changes.isEmpty) {
        // A page that says more follows but carries nothing would loop for
        // ever. Stop and let the next sync try again.
        break;
      }
    }

    if (afterSeq > 0) {
      await _settings.setInt(cursorKey, afterSeq);
    }
    return appliedTotal;
  }

  /// How many changes are waiting to be sent.
  Future<int> pendingCount() async {
    final count = _db.syncQueue.id.count();
    final query = _db.selectOnly(_db.syncQueue)
      ..addColumns([count])
      ..where(_db.syncQueue.syncedAt.isNull());
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// Sent rows older than [keepSentFor].
  ///
  /// The outbox grows on every single save — a shop writing fifty invoices a day
  /// adds hundreds of rows — so something has to cap it. Pruning only touches
  /// rows that are already marked sent, so it cannot lose an unsent change.
  Future<int> pruneSent({
    Duration keep = keepSentFor,
    DateTime? now,
  }) async {
    final cutoff = (now ?? DateTime.now()).subtract(keep);
    final deleted = await (_db.delete(_db.syncQueue)
          ..where((t) =>
              t.syncedAt.isNotNull() &
              t.syncedAt.isSmallerThanValue(cutoff)))
        .go();
    return deleted;
  }

  /// Records the reason on rows that can never be sent, and retires them.
  ///
  /// Retired rather than deleted: the row is the only evidence of what was lost,
  /// and silently deleting a change is how a books app loses an invoice without
  /// anybody noticing.
  Future<void> _retireUnsendable(List<SyncQueueEntity> rows, String reason) async {
    if (rows.isEmpty) return;
    final ids = rows.map((r) => r.id).toList(growable: false);
    await _bumpAttempts(ids, reason, sent: true);
  }

  /// The next batch, oldest first — with one firm's rows first, so a device with
  /// two businesses does not alternate between them on every loop.
  Future<List<SyncQueueEntity>> _nextBatch() async {
    // Children must never lead a batch, and the tiebreak inside one second of
    // created_at used to be the row id — an alphabetical sort that puts
    // `sales_invoice_items_…` BEFORE `sales_invoices_…` (the names diverge at
    // the underscore). A batch ordered that way delivers a child first, the
    // server journals it first, and every pull skips it as an FK orphan for
    // ever. So the entity's position in [journalOrder] sorts before time.
    final caseWhen = [
      for (var i = 0; i < journalOrder.length; i++)
        "WHEN '${journalOrder[i]}' THEN $i",
    ].join(' ');
    // The entity names interpolated here are this class's own compile-time
    // constants, never user input — the same trust PullApplier places in its
    // table allowlist.
    final idRows = await _db
        .customSelect(
          'SELECT id FROM sync_queue WHERE synced_at IS NULL '
          'ORDER BY CASE entity $caseWhen '
          'ELSE ${journalOrder.length} END ASC, created_at ASC, id ASC '
          'LIMIT $batchSize',
          readsFrom: {_db.syncQueue},
        )
        .get();
    if (idRows.isEmpty) return const [];
    final ids = idRows.map((row) => row.data['id'] as String).toList();
    final rows = await (_db.select(_db.syncQueue)
          ..where((t) => t.id.isIn(ids)))
        .get();
    final byId = {for (final row in rows) row.id: row};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Registers the firm on the server the first time it is pushed.
  ///
  /// The journal's rows carry a foreign key to `firms`, so a push for a firm the
  /// server has never heard of fails with a constraint error that says nothing
  /// useful. Registering first turns that into one extra round trip once per
  /// firm per install; a firm that already exists answers 409, which
  /// [AuthClient.registerFirm] treats as success.
  Future<void> _ensureFirmRegistered(String firmId, String accessToken) async {
    final raw = await _settings.get(SettingsRepository.kSyncRegisteredFirms);
    final registered = _decodeFirmIds(raw);
    if (registered.contains(firmId)) return;

    final firm = await (_db.select(_db.firms)..where((t) => t.id.equals(firmId)))
        .getSingleOrNull();
    if (firm == null) {
      // The firm was purged locally but its outbox rows survive (the purge
      // deletes them, but a crash between the two steps is possible). Nothing
      // can be registered, and a push would fail on the foreign key.
      return;
    }

    final account = _auth.email;
    await _auth.registerFirmForSync(
      accessToken: accessToken,
      firmId: firmId,
      name: firm.name,
      gstin: firm.gstin,
      memberName: account.isEmpty ? firm.name : account,
    );
    registered.add(firmId);
    await _settings.set(
      SettingsRepository.kSyncRegisteredFirms,
      registered.join(','),
    );
  }

  static Set<String> _decodeFirmIds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>{};
    return raw
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  /// One outbox row as the wire format.
  ///
  /// The payload is the entity as it is *now*, not as it was when the change was
  /// enqueued. A failed push followed by an update therefore sends the newer
  /// state, which is what a journal replay should see — the alternative would be
  /// storing a snapshot per change on the device for a case the server can
  /// reconstruct from the sequence.
  Future<Map<String, Object?>> _encode(SyncQueueEntity row) async {
    final table = _tableNamed(row.entity);
    return {
      'id': row.id,
      'entity': row.entity,
      'entityId': row.entityId,
      'operation': row.operation,
      'payload': table == null ? null : await _rowJson(table, row.entityId),
      'createdAt': row.createdAt.toUtc().toIso8601String(),
    };
  }

  /// The drift table for an entity name, or null when it is not one we sync.
  ///
  /// Resolved from [AppDatabase.allTables] rather than taken from the outbox row
  /// as-is, because the entity name ends up inside a SQL string: interpolating a
  /// value a caller controls into a query is how injection bugs start, even when
  /// today every caller is our own code.
  TableInfo<Table, dynamic>? _tableNamed(String entity) {
    for (final table in _db.allTables) {
      if (table.actualTableName == entity) return table;
    }
    return null;
  }

  /// The current row for [entityId], as JSON, or null when it is gone.
  Future<Map<String, Object?>?> _rowJson(
    TableInfo<Table, dynamic> table,
    String entityId,
  ) async {
    final primaryKey = table.$primaryKey.toList(growable: false);
    if (primaryKey.isEmpty) return null;
    final where = primaryKey.map((c) => '${c.name} = ?').join(' AND ');
    final rows = await _db
        .customSelect(
          'SELECT * FROM ${table.actualTableName} WHERE $where LIMIT 1',
          variables: [for (final _ in primaryKey) Variable.withString(entityId)],
          readsFrom: {table},
        )
        .get();
    if (rows.isEmpty) return null;
    return _normalise(table, rows.first.data);
  }

  /// Turns one raw SQLite row into the JSON shape the app's own drift
  /// `toJson()` produces.
  ///
  /// A raw `SELECT` hands back what SQLite stores, which is not what the app
  /// means: booleans arrive as 0/1, and drift writes timestamps as *seconds*
  /// while its JSON uses milliseconds. Pushing the raw values would put
  /// `is_deleted: 0` in the server's journal, where nothing can tell it from a
  /// count — so the two column types that drift encodes differently are
  /// converted here, and everything else is already JSON-safe.
  Map<String, Object?> _normalise(
    TableInfo<Table, dynamic> table,
    Map<String, dynamic> raw,
  ) {
    final bySqlName = {
      for (final column in table.$columns) column.name: column,
    };
    final out = <String, Object?>{};
    for (final entry in raw.entries) {
      final column = bySqlName[entry.key];
      final value = entry.value;
      if (column == null || value == null) {
        out[entry.key] = value;
        continue;
      }
      switch (column.type) {
        case DriftSqlType.bool:
          out[entry.key] = value == 1 || value == true;
        case DriftSqlType.dateTime:
          // drift stores seconds by default; its JSON shape is milliseconds.
          out[entry.key] = value is int ? value * 1000 : value;
        default:
          out[entry.key] = value;
      }
    }
    return out;
  }

  /// Marks [ids] as sent inside one transaction.
  ///
  /// One statement for the batch: fifty individual updates inside a transaction
  /// still cost fifty round trips to SQLite, and this runs on every sync.
  Future<void> _markSent(List<String> ids) async {
    if (ids.isEmpty) return;
    await (_db.update(_db.syncQueue)..where((t) => t.id.isIn(ids))).write(
      SyncQueueCompanion(
        syncedAt: Value(DateTime.now()),
        error: const Value(null),
      ),
    );
  }

  /// Records a failed attempt on [ids] so the next run — and the settings
  /// screen — can see why the batch did not go.
  Future<void> _recordFailure(List<String> ids, String message) async {
    if (ids.isEmpty) return;
    await _bumpAttempts(ids, message, sent: false);
  }

  /// `attempts = attempts + 1`, plus the reason, in one statement.
  ///
  /// Written as SQL rather than a drift `update(companion)` because the count
  /// has to be incremented *relative to its current value*: reading it into
  /// Dart and writing back the sum would lose a concurrent increment, and
  /// nothing here should have to hold a lock to count attempts.
  Future<void> _bumpAttempts(
    List<String> ids,
    String message, {
    required bool sent,
  }) async {
    final placeholders = List.filled(ids.length, '?').join(', ');
    await _db.customUpdate(
      'UPDATE sync_queue SET error = ?, attempts = attempts + 1'
      '${sent ? ', synced_at = ?' : ''} WHERE id IN ($placeholders)',
      variables: [
        Variable.withString(message),
        if (sent) Variable.withDateTime(DateTime.now()),
        for (final id in ids) Variable.withString(id),
      ],
      updates: {_db.syncQueue},
    );
  }
}
