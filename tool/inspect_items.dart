// Read-only diagnostic: dump firms / active-firm setting / items / sync queue
// from the live Windows app database. Opens the file read-only so the running
// app (WAL mode) is never blocked. Run with the project's own flutter dart:
//   cmd /c "C:\flutter\bin\flutter.bat" dart run tool/inspect_items.dart
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

void dump(Database db, String label, String sql) {
  stdout.writeln('\n== $label ==');
  try {
    final rows = db.select(sql);
    if (rows.isEmpty) stdout.writeln('(no rows)');
    for (final row in rows) {
      stdout.writeln(row.entries.map((e) => '${e.key}=${e.value}').join(' | '));
    }
  } catch (e) {
    stdout.writeln('ERROR: $e');
  }
}

void main() {
  final appData = Platform.environment['APPDATA'] ?? '';
  final dbPath = '$appData\\com.atria\\atria\\atria\\atria.db';
  final file = File(dbPath);
  stdout.writeln('db: $dbPath exists=${file.existsSync()}');
  if (!file.existsSync()) return;

  final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);

  dump(db, 'firms', 'SELECT id, name, state_code, gstin FROM firms ORDER BY created_at');
  dump(db, 'app_settings (active firm lives here)',
      'SELECT * FROM app_settings');
  dump(db, 'item counts per firm (incl. soft-deleted)',
      'SELECT firm_id, COUNT(*) AS n, '
      'SUM(CASE WHEN is_deleted THEN 1 ELSE 0 END) AS deleted FROM items GROUP BY firm_id');
  dump(db, 'items (newest 25 first)',
      'SELECT name, tax_mode, stock_type, firm_id, is_deleted, sale_price, current_stock, '
      'created_at, updated_at FROM items ORDER BY created_at DESC LIMIT 25');
  dump(db, 'sync_queue backlog by entity/operation',
      'SELECT entity, operation, COUNT(*) AS n FROM sync_queue GROUP BY entity, operation');
  dump(db, 'sync_queue newest 15',
      'SELECT entity, entity_id, operation, created_at FROM sync_queue '
      'ORDER BY rowid DESC LIMIT 15');

  // ignore: deprecated_member_use
  db.dispose();
}
