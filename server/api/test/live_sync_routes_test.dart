import 'dart:convert';
import 'package:atria_api/src/auth/token_issuer.dart';
import 'package:atria_api/src/database.dart';
import 'package:atria_api/src/http/middleware.dart';
import 'package:atria_api/src/routes/sync_routes.dart';
import 'package:atria_api/src/sync/sync_repository.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:test/test.dart';
import 'support.dart';

class WaitingJournal extends SyncRepository {
  WaitingJournal(super.database);
  int reads = 0;
  @override
  Future<PullResult> pullChanges(
      {required String userId,
      required String firmId,
      required int afterSeq,
      int limit = maxChangesPerPull}) async {
    reads++;
    expect(userId, 'user-1');
    return PullResult(
        changes: reads < 2
            ? []
            : [
                JournaledChange(
                    seq: 1,
                    changeId: 'change',
                    entity: 'parties',
                    entityId: 'party',
                    operation: 'insert',
                    payload: const {'id': 'party'})
              ],
        hasMore: false);
  }
}

void main() {
  test('authenticated long poll wakes when another device journals a change',
      () async {
    final config = testConfig();
    final pool = Pool.withUrl(config.databaseUrl);
    final repository = WaitingJournal(Database(pool));
    final issuer = TokenIssuer(
        secret: config.jwtSecret,
        issuer: config.jwtIssuer,
        ttl: config.accessTokenTtl);
    final router = Router();
    addSyncRoutes(router,
        repository: repository, config: config, guard: authenticate(issuer));
    final handler = jsonErrors(silentLogger())(router.call);
    final response = await handler(Request(
        'GET',
        Uri.parse(
            'http://localhost/v1/firms/00000000-0000-4000-8000-000000000001/changes?afterSeq=0&waitSeconds=1'),
        headers: {
          'authorization': 'Bearer ${issuer.issue(userId: 'user-1')}'
        }));
    expect(response.statusCode, 200);
    final json = jsonDecode(await response.readAsString()) as Map;
    expect(json['changes'], hasLength(1));
    expect(repository.reads, 2);
    await pool.close();
  });
}
