import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../api/server_client.dart' show ServerRequestException;
import '../api/sync_client.dart';
import '../database/app_database.dart';
import '../database/repositories/settings_repository.dart';
import '../domain/member_role.dart';
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
    this.temporarilyUnavailable = false,
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

  /// True when the session is fine and Apex Books could not be reached this run, so
  /// the outbox is equally untouched — but nothing is wrong with the account
  /// and there is no password for the user to type.
  ///
  /// Separate from [needsSignIn] because the two used to be the same report:
  /// `AuthController.accessToken()` returns null both when there is no session
  /// and when the renewal could not be delivered, so being on a train produced
  /// "Sign in to Apex Books to sync" across the app. Only one of them can be acted
  /// on, and the action is not the same, so they are not the same field.
  final bool temporarilyUnavailable;

  /// Why the sync stopped, in words worth showing. Null when it finished.
  final String? error;

  /// When the run finished, for "last synced" display.
  final DateTime? at;

  bool get ok => error == null && !needsSignIn && !temporarilyUnavailable;

  /// A one-line summary for the settings screen.
  String get describe {
    if (skipped) return 'Sync is switched off.';
    if (needsSignIn) return 'Sign in to Apex Books to sync.';
    if (temporarilyUnavailable) {
      return 'Apex Books is unreachable right now, so nothing was sent or received. '
          'Your changes are safe on this device and will go up on the next run.';
    }
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
/// Merge policy on the pull side is row-level last-write-wins on `updated_at`,
/// with a tie going to the pull and a one-day bound on how far the local clock
/// is trusted (see [PullApplier]). The server arbitrates nothing: it stores a
/// journal, and the journal's order plus each row's `updated_at` is the whole
/// algorithm.
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

  /// The largest request body the client will build, in bytes.
  ///
  /// The server refuses anything over 256KB, and it refuses the request
  /// *whole* — there is no partial accept. So this budget has to sit below that
  /// limit with room for the `{"changes":[…]}` wrapper and JSON punctuation,
  /// or the last row of a full batch tips it over.
  ///
  /// Batching by row count alone is what produced bills with no items on other
  /// devices: see the drain.
  static const int maxRequestBytes = 200 * 1024;

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
    _db.assertPermission(Permission.sync);
    var enqueued = 0;
    // Rows that were quarantined and have now been put back in the drain.
    var revived = 0;
    // The outbox id IS the server's `firm_changes.change_id` primary key,
    // which is inserted `ON CONFLICT DO NOTHING`. So an id that repeats
    // across runs is dropped by the server as a duplicate — the client marks
    // it sent and the repair reports success having healed nothing. That is
    // exactly what happened after `pruneSent` removed the first run's rows.
    //
    // The fix is to keep the id stable only for as long as the row can still
    // be pending, and vary it per run otherwise: `runId` is folded in, so a
    // second run against a still-queued row is suppressed locally (the
    // original intent) while a run after pruning produces fresh ids the
    // server will actually accept.
    final runId = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
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
        sql =
            'SELECT id FROM ${table.actualTableName} WHERE firm_id = ?'
            '${hasDeleted ? ' AND is_deleted = 0' : ''}';
      } else {
        switch (entity) {
          case 'sales_invoice_items':
            sql =
                'SELECT c.id FROM sales_invoice_items c '
                'JOIN sales_invoices p ON p.id = c.invoice_id '
                'WHERE p.firm_id = ? AND p.is_deleted = 0'
                '${hasDeleted ? ' AND c.is_deleted = 0' : ''}';
          case 'purchase_bill_items':
            sql =
                'SELECT c.id FROM purchase_bill_items c '
                'JOIN purchase_bills p ON p.id = c.bill_id '
                'WHERE p.firm_id = ? AND p.is_deleted = 0'
                '${hasDeleted ? ' AND c.is_deleted = 0' : ''}';
          case 'journal_lines':
            // `journal_lines` has no is_deleted of its own (only
            // `journal_entries` does), so the `${hasDeleted ...}` template
            // cannot add it — it must be spelled out here. Without this a
            // voided voucher has its debit/credit lines re-journalled, and
            // receiving devices insert them under a deleted entry, which
            // corrupts the trial balance.
            sql =
                'SELECT c.id FROM journal_lines c '
                'JOIN journal_entries p ON p.id = c.entry_id '
                'WHERE p.firm_id = ? AND p.is_deleted = 0';
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
        // Matched on entity+entityId rather than the full id: the id now
        // carries `runId`, so an id-equality check would never suppress
        // anything. A row already queued for this entity — from the first run,
        // or a still-pending ordinary change — is left as it is, which is
        // what keeps a re-run from double-sending the same row.
        final already =
            await (_db.select(_db.syncQueue)..where(
                  (t) => t.entity.equals(entity) & t.entityId.equals(entityId),
                ))
                .getSingleOrNull();
        if (already != null) {
          // A row parked by [_quarantineUnsendable] is unsent but out of the
          // drain, so re-queuing it as a *new* row would do nothing (the
          // entity+entityId check above skips it) and the repair would report
          // success while the row stayed unsent. Clearing `attempts` puts it
          // back in the drain, which is the entire point of asking for a
          // re-send by hand.
          if (already.syncedAt == null && already.attempts >= maxAttempts) {
            await (_db.update(
              _db.syncQueue,
            )..where((t) => t.id.equals(already.id))).write(
              const SyncQueueCompanion(attempts: Value(0), error: Value(null)),
            );
            revived++;
          }
          continue;
        }
        await _db
            .into(_db.syncQueue)
            .insert(
              SyncQueueCompanion.insert(
                // The run id is what makes this a *new* journal entry server
                // side. Deterministic ids were silently deduplicated away,
                // so a second repair run healed nothing while reporting that
                // it had.
                id: '${queueId}_$runId',
                firmId: Value(firmId),
                entity: entity,
                entityId: entityId,
                operation: 'insert',
              ),
            );
        enqueued++;
      }
    }
    if (revived > 0) {
      debugPrint('atria sync: re-send revived $revived quarantined change(s)');
    }
    return enqueued + revived;
  }

  /// How many times a row may fail to push before it is quarantined.
  ///
  /// High enough that a transient outage (offline, 5xx, a dropped connection)
  /// retries many times, low enough that a permanently-rejected row stops
  /// blocking the queue quickly. See the catch in the drain loop.
  static const int maxAttempts = 8;

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

    final token = await _auth.resolveAccessToken();
    final accessToken = token.accessToken;
    if (accessToken == null) {
      // Two different failures with two different remedies. Reporting the
      // offline one as "needs sign in" is what put a password prompt on a
      // phone with no signal, and the prompt does not even help.
      return SyncReport(
        needsSignIn: !token.temporarilyUnavailable,
        temporarilyUnavailable: token.temporarilyUnavailable,
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
          // Nothing to attach it to, so no push can ever succeed for these.
          // Quarantined like any other unsendable row — still unsent, so the
          // change is not erased by claiming it was delivered — and skipped by
          // the drain from here on.
          await _quarantineUnsendable(
            batch.where((r) => r.firmId == null || r.firmId!.isEmpty).toList(),
            'No business is attached to this change.',
          );
          continue;
        }

        final sameFirm = batch
            .where((r) => r.firmId == firmId)
            .toList(growable: false);

        await _ensureFirmRegistered(firmId, accessToken);

        // Encode as many rows as the server's body cap allows, not as many as
        // [batchSize] counts.
        //
        // Counting rows is not enough: a batch is rejected wholesale when its
        // encoded body is too large, and the drain orders rows so that every
        // document *parent* is sent before any of its *lines*. A books-sized
        // batch therefore splits into a small header batch that fits and one or
        // more oversized line batches that do not — so the headers reach the
        // server and the lines never do, and every other device pulls saved
        // bills and estimates with their totals and no items. Splitting on the
        // encoded size is what keeps a document from being delivered piecemeal.
        final changes = <Map<String, Object?>>[];
        var used = 0;
        for (final row in sameFirm) {
          final encoded = await _encode(row);
          final size = _encodedSize(encoded);
          // Always send at least one row: a single change the server will not
          // take must fail loudly and stay queued, never be skipped silently.
          if (changes.isNotEmpty && used + size > maxRequestBytes) break;
          changes.add(encoded);
          used += size;
        }
        final ids = changes
            .map((c) => c['id'] as String)
            .toList(growable: false);

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
          // A row can fail for a reason retrying will never fix: the server
          // caps a body at 256KB while `notes`/`terms` are unbounded TEXT, so
          // one invoice with a long notes blob fails forever. Because the
          // drain is head-of-queue, that single row blocked every payment,
          // expense and later invoice behind it — silently, since nothing
          // read `attempts` to notice. Park it instead, so the rest of the
          // book can leave the device.
          //
          // Parked, not retired: it stays unsent and in `pending`, because
          // "the server will never take this row" is not "the server has
          // this row". See [_quarantineUnsendable].
          final stuck = await _stuckIn(firmId, ids);
          if (stuck.isNotEmpty) {
            await _quarantineUnsendable(
              stuck,
              'Could not be sent in $maxAttempts attempts — kept unsent so it '
              'is not lost, and held back so it cannot block the rest of the '
              'books. Last error: ${stuck.first.error ?? 'unknown'}. '
              'Use "Re-send all books" to try again, or shorten the '
              'note/terms on this document.',
            );
          }
          rethrow;
        }
        await _markSent(ids);
        pushed += changes.length;
      }
    } on ServerRequestException catch (failure) {
      error = failure.signedOut
          ? 'Apex Books no longer accepts this device\'s session. Sign in again to '
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
    return SyncReport(pushed: pushed, pending: pending, error: error, at: at);
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
    // Same reasoning one step down: a push that never got past the token check
    // has nothing to receive either, and retrying would only produce a second
    // failure line for one outage. `describe` already says "unreachable".
    if (pushReport.temporarilyUnavailable) return pushReport;

    // A device can belong to firms this install has never opened (restore
    // created one while another was active) — pull for every firm the outbox
    // has ever mentioned plus the active one, deduplicated.
    final firmIds = <String>{...await _knownFirmIds()};
    var pulled = 0;
    String? pullError;
    var temporarilyUnavailable = false;
    for (final firmId in firmIds) {
      // Resolved per firm because _pullFirm needs the outcome, not just the
      // token: it used to treat a null token as "nothing to do" and return 0,
      // which made an unreachable server look like a completed pull.
      final token = await _auth.resolveAccessToken();
      try {
        pulled += await _pullFirm(firmId, token);
      } on ServerRequestException catch (failure) {
        pullError = failure.signedOut
            ? 'Apex Books no longer accepts this device\'s session. Sign in again to '
                  'resume syncing.'
            : failure.message;
        // Only the token check can make this run "unreachable"; a 500 from a
        // server that answered has its own message and must keep it.
        temporarilyUnavailable = token.temporarilyUnavailable;
        break;
      } on Object catch (failure) {
        pullError = 'Sync stopped while receiving: $failure';
        break;
      }
    }

    final at = DateTime.now();
    // "Last synced" claims a *round trip*, so it is stamped only when both
    // halves completed. Keying it on the pull alone stamped it while the push
    // half was still failing — the one thing the Settings row is read for.
    if (pullError == null && pushReport.error == null) {
      await _settings.set(
        SettingsRepository.kSyncLastSyncedAt,
        at.toUtc().toIso8601String(),
      );
    }
    return SyncReport(
      pushed: pushReport.pushed,
      pulled: pulled,
      pending: pushReport.pending,
      temporarilyUnavailable: temporarilyUnavailable,
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
    final token = await _auth.resolveAccessToken();
    final accessToken = token.accessToken;
    if (accessToken == null) {
      return RestoreReport(
        restored: false,
        // "Sign in again" is only true when the session really is gone; on a
        // train the books are still safe on the other device and this one
        // simply has to wait.
        describe: token.temporarilyUnavailable
            ? 'Could not reach Apex Books, so nothing was restored. Check this '
                  'device is online and try again.'
            : 'Your session has expired. Sign in again.',
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

      final firmRow = await (_db.select(
        _db.firms,
      )..where((t) => t.id.equals(firmId))).getSingleOrNull();
      if (firmRow == null) {
        // The journal never carried this firm's insert — the original device
        // created it but never pushed (sync was off, or the server address
        // changed). Say so rather than opening books that look emptied.
        return RestoreReport(
          restored: false,
          describe:
              'The server has no books for that business yet. On the '
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
      return RestoreReport(
        restored: false,
        describe: 'Restore failed: $failure',
      );
    }
  }

  /// Appends [firmId] to the registered-firms setting. Read-modify-write of
  /// a value only the sync flows touch.
  Future<String> _registeredFirmsWith(String firmId) async {
    final raw = await _settings.get(SettingsRepository.kSyncRegisteredFirms);
    final existing = (raw ?? '')
        .split(',')
        .map((id) => id.trim())
        .where(idNotEmpty)
        .toSet();
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
    final queued = await _db.select(_db.syncQueue).get();
    for (final row in queued) {
      final id = row.firmId;
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// Replays one firm's journal from the stored cursor. Returns the number of
  /// changes applied.
  ///
  /// [token] is resolved by the caller rather than here so that a pull which
  /// could not start is *reported* instead of looking like a firm with nothing
  /// new: a null token used to return 0 silently, and the run went on to record
  /// a successful sync.
  Future<int> _pullFirm(String firmId, AccessTokenResult token) async {
    final accessToken = token.accessToken;
    if (accessToken == null) {
      throw ServerRequestException(
        token.temporarilyUnavailable
            ? 'Could not reach Apex Books, so nothing was received.'
            : 'Apex Books no longer accepts this device\'s session. Sign in again '
                  'to resume syncing.',
        signedOut: !token.temporarilyUnavailable,
      );
    }

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

  /// [pendingCount] as a stream, so Settings can show a count that is still
  /// true after the outbox grew on another tab.
  Stream<int> watchPendingCount() {
    final count = _db.syncQueue.id.count();
    final query = _db.selectOnly(_db.syncQueue)
      ..addColumns([count])
      ..where(_db.syncQueue.syncedAt.isNull());
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  /// Sent rows older than [keepSentFor].
  ///
  /// The outbox grows on every single save — a shop writing fifty invoices a day
  /// adds hundreds of rows — so something has to cap it. Pruning only touches
  /// rows that are already marked sent, so it cannot lose an unsent change.
  Future<int> pruneSent({Duration keep = keepSentFor, DateTime? now}) async {
    final cutoff = (now ?? DateTime.now()).subtract(keep);
    final deleted =
        await (_db.delete(_db.syncQueue)..where(
              (t) =>
                  t.syncedAt.isNotNull() &
                  t.syncedAt.isSmallerThanValue(cutoff),
            ))
            .go();
    return deleted;
  }

  /// Parks rows that can never be sent, so they stop blocking the queue without
  /// being lost.
  ///
  /// "Parked" means: still unsent (`synced_at` untouched), the reason recorded,
  /// and `attempts` left at [maxAttempts] so [_nextBatch] steps over them. The
  /// row stays in the outbox and in `pending`, so the books are never reported
  /// as safe when a change has not left the device.
  ///
  /// It used to mark them `synced_at` instead, on the reasoning that a row the
  /// server will never take is as good as sent. That is the worst possible
  /// assumption in a ledger app: `pruneSent` then deletes the row with the rest
  /// of the sent queue, and the invoice exists on no device and on no server,
  /// while the UI says the sync succeeded. A shop that imports its books,
  /// syncs once against a server that refuses the size, and comes back to an
  /// Android phone to find bills with totals and no items — which is exactly
  /// what a quarantined line row looks like from the other end.
  ///
  /// [rejournalEverything] revives them: the repair resets `attempts` for rows
  /// it finds stuck, so "Re-send all books" is a real recovery and not a no-op
  /// on a device that has already hit this.
  Future<void> _quarantineUnsendable(
    List<SyncQueueEntity> rows,
    String reason,
  ) async {
    if (rows.isEmpty) return;
    final ids = rows.map((r) => r.id).toList(growable: false);
    await _bumpAttempts(ids, reason, sent: false);
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
    // A row that has exhausted its attempts is quarantined: still unsent, still
    // in the outbox, still counted in `pending` — but out of the drain, so one
    // impossible row cannot wedge every change behind it. `rejournalEverything`
    // is what brings it back.
    //
    // This clause is the whole reason a quarantine is safe. The previous
    // behaviour marked such rows `synced_at`, which is a claim that the server
    // holds the change — and it does not. The row was then pruned with the rest
    // of the sent queue and the invoice existed on no device at all, while the
    // UI reported a clean sync.
    //
    // The entity names interpolated here are this class's own compile-time
    // constants, never user input — the same trust PullApplier places in its
    // table allowlist.
    final idRows = await _db
        .customSelect(
          'SELECT id FROM sync_queue WHERE synced_at IS NULL '
          'AND attempts < $maxAttempts '
          'ORDER BY CASE entity $caseWhen '
          'ELSE ${journalOrder.length} END ASC, created_at ASC, id ASC '
          'LIMIT $batchSize',
          readsFrom: {_db.syncQueue},
        )
        .get();
    if (idRows.isEmpty) return const [];
    final ids = idRows.map((row) => row.data['id'] as String).toList();
    final rows = await (_db.select(
      _db.syncQueue,
    )..where((t) => t.id.isIn(ids))).get();
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

    final firm = await (_db.select(
      _db.firms,
    )..where((t) => t.id.equals(firmId))).getSingleOrNull();
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

  /// The wire size of one encoded change, in bytes.
  ///
  /// Measured on the encoded form rather than estimated from column types: the
  /// whole problem is that `notes`, `terms` and item names are unbounded TEXT,
  /// so a per-column guess is exactly the assumption that fails.
  int _encodedSize(Map<String, Object?> encoded) => jsonEncode(encoded).length;

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
          variables: [
            for (final _ in primaryKey) Variable.withString(entityId),
          ],
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

  /// The rows from [ids] that have now failed [maxAttempts] times.
  ///
  /// Read after `_recordFailure` has bumped the count, so a row that has just
  /// crossed the threshold is included.
  Future<List<SyncQueueEntity>> _stuckIn(
    String firmId,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final query = _db.select(_db.syncQueue)
      ..where(
        (t) =>
            t.firmId.equals(firmId) &
            t.attempts.isBiggerOrEqualValue(maxAttempts) &
            t.id.isIn(ids),
      );
    return query.get();
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
