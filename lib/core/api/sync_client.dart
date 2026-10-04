import 'api_config.dart';
import 'server_http.dart';

/// What the server did with a batch: how much of it was new, and how much was
/// already there.
///
/// Duplicates are reported rather than treated as an error because the most
/// common cause is a retry after a timeout — the device did the right thing and
/// must not be told it failed.
class PushOutcome {
  const PushOutcome({required this.received, required this.duplicates});

  final int received;
  final int duplicates;

  int get total => received + duplicates;
}

/// The change-journal endpoint.
///
/// Two methods, on purpose: push drains the local outbox, pull replays what
/// other devices journalled. Everything a multi-device shop needs flows through
/// exactly these two calls, so both stay symmetric in shape and error
/// semantics — which is what makes the engine that calls them readable.
class SyncClient {
  SyncClient(this._config, {this.timeout = const Duration(seconds: 30)});

  final ApiConfig _config;

  /// Longer than the auth timeout: a full batch of 200 changes is a bigger
  /// request than a login, and on a shop's connection it is the one call that
  /// legitimately takes a while.
  final Duration timeout;

  /// Pushes [changes] for [firmId], authenticated as the given access token.
  ///
  /// Each change is `{id, entity, entityId, operation, payload, createdAt}` —
  /// the outbox row, with the entity's current state attached as `payload`.
  /// Throws [ServerRequestException] for anything that is not a success;
  /// see [ServerHttp] for what the caller can tell apart.
  Future<PushOutcome> pushChanges({
    required String firmId,
    required String accessToken,
    required List<Map<String, Object?>> changes,
  }) async {
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/firms/$firmId/changes'),
      accessToken: accessToken,
      timeout: timeout,
      body: {'changes': changes},
      timeoutMessage: 'Apex Books did not answer within ${timeout.inSeconds} '
          'seconds, so nothing left this device. It will be sent again on the '
          'next sync.',
    );

    int asInt(Object? value) =>
        value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

    return PushOutcome(
      received: asInt(json['received']),
      duplicates: asInt(json['duplicates']),
    );
  }

  /// Reads the firm's journal from [afterSeq], oldest first.
  ///
  /// The cursor is the per-firm sequence the server stamps on every change: a
  /// device stores the highest it has applied and asks for everything after it.
  /// The answer is one page plus [PullPage.hasMore], so a first sync replays
  /// the whole journal in pages of the server's cap (500) and a steady-state
  /// sync usually gets one.
  Future<PullPage> pullChanges({
    required String firmId,
    required String accessToken,
    required int afterSeq,
  }) async {
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint(
        '/v1/firms/$firmId/changes?afterSeq=$afterSeq',
      ),
      method: 'GET',
      accessToken: accessToken,
      timeout: timeout,
      timeoutMessage: 'Apex Books did not answer within ${timeout.inSeconds} '
          'seconds while fetching changes. Nothing was applied; try again.',
    );

    final rawChanges = json['changes'];
    final changes = <JournaledChange>[];
    if (rawChanges is List) {
      for (final raw in rawChanges) {
        if (raw is! Map) continue;
        final seq = raw['seq'];
        final id = raw['id'];
        final entity = raw['entity'];
        final entityId = raw['entityId'];
        final operation = raw['operation'];
        if (seq is! num || id is! String || entity is! String) continue;
        if (entityId is! String || operation is! String) continue;
        changes.add(JournaledChange(
          seq: seq.toInt(),
          changeId: id,
          entity: entity,
          entityId: entityId,
          operation: operation,
          payload:
              raw['payload'] is Map ? (raw['payload'] as Map).cast<String, Object?>() : null,
          createdAt: DateTime.tryParse('${raw['createdAt'] ?? ''}')?.toUtc(),
        ));
      }
    }

    return PullPage(
      changes: changes,
      hasMore: json['hasMore'] == true,
    );
  }
}

/// One page of the firm's journal.
class PullPage {
  const PullPage({required this.changes, required this.hasMore});

  /// Ordered by the server's per-firm sequence, oldest first. Applying in any
  /// other order would replay a document's update before its insert.
  final List<JournaledChange> changes;

  /// True when another page follows this one.
  final bool hasMore;
}

/// One change as the server journalled it.
class JournaledChange {
  const JournaledChange({
    required this.seq,
    required this.changeId,
    required this.entity,
    required this.entityId,
    required this.operation,
    this.payload,
    this.createdAt,
  });

  /// Position in the firm's journal — the pull cursor.
  final int seq;

  /// The origin device's outbox id. A device skips changes carrying its own
  /// ids: it already has that state locally, and re-applying them would fight
  /// whatever the user did since.
  final String changeId;

  /// App table name: `sales_invoices`, `payments`, `items`, ...
  final String entity;

  final String entityId;

  /// insert | update | delete.
  final String operation;

  /// The row as the origin device had it, or null when it was deleted.
  final Map<String, Object?>? payload;

  /// The origin device's timestamp, or null when it did not record one.
  final DateTime? createdAt;
}
