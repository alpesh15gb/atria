import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ItemRepository.watchAll finds items when searching by barcode', () async {
    final db = AppDatabase.test(NativeDatabase.memory());
    addTearDown(() => db.close());

    final firm = await db.firmRepository.create(name: 'Test Firm');
    final repo = db.itemRepositoryFor(firm.id);

    await repo.create(
      name: 'Wireless Mouse',
      barcode: '8901234567890',
      salePrice: 500,
    );

    // Query stream searching by barcode
    final results = await repo.watchAll(search: '8901234567890').first;
    expect(results, hasLength(1));
    expect(results.first.name, 'Wireless Mouse');
    expect(results.first.barcode, '8901234567890');
  });
}
