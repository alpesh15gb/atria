import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:decimal/decimal.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/database/repositories/purchase_repository.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// A real native app with disposable books. Never opens the user's database.
late ProviderContainer auditContainer;
final auditFirms = <FirmEntity>[];
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.test(NativeDatabase.memory());
  for (final registered in [false, true]) {
    final firm = await db.firmRepository.create(
      name: registered ? 'GST Registered Shop' : 'Non-GST Shop',
      gstin: registered ? '29ABCDE1234F1Z5' : null,
      stateCode: '29',
    );
    auditFirms.add(firm);
    final customer = await db
        .partyRepositoryFor(firm.id)
        .create(name: 'Walk-in Customer', type: 'customer', stateCode: '27');
    final supplier = await db
        .partyRepositoryFor(firm.id)
        .create(name: 'Supplier', type: 'supplier', gstin: '29ABCDE1234F1Z5');
    final item = await db
        .itemRepositoryFor(firm.id)
        .create(
          name: 'Notebook',
          salePrice: 200,
          purchasePrice: 100,
          gstRate: 18,
        );
    await db
        .purchaseRepositoryFor(firm.id)
        .save(
          PurchaseDraft(
            id: 'purchase-${firm.id}',
            number: 'PUR-001',
            docType: 'bill',
            partyId: supplier.id,
            partyName: supplier.name,
            billDate: DateTime.now(),
            lines: [
              PurchaseLineDraft(
                id: 'purchase-line-${firm.id}',
                itemId: item.id,
                name: item.name,
                quantity: Decimal.fromInt(2),
                unit: 'pcs',
                rate: Decimal.fromInt(100),
                gstRate: 18,
              ),
            ],
          ),
        );
    await db
        .salesRepositoryFor(firm.id)
        .save(
          SalesDraft(
            id: 'sale-${firm.id}',
            number: 'INV-001',
            docType: 'invoice',
            partyId: customer.id,
            partyName: customer.name,
            invoiceDate: DateTime.now(),
            isInterState: registered,
            placeOfSupply: '27',
            lines: [
              SalesLineDraft(
                id: 'sale-line-${firm.id}',
                itemId: item.id,
                name: item.name,
                quantity: Decimal.one,
                unit: 'pcs',
                rate: Decimal.fromInt(200),
                gstRate: 18,
              ),
            ],
          ),
        );
  }
  auditContainer = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
  );
  await auditContainer.read(onboardingDoneProvider.notifier).complete();
  await auditContainer
      .read(activeFirmIdProvider.notifier)
      .select(auditFirms.first.id);
  await auditContainer.read(appInitializationProvider.future);
  runApp(
    UncontrolledProviderScope(
      container: auditContainer,
      child: const _AuditHarness(),
    ),
  );
}

class _AuditHarness extends StatefulWidget {
  const _AuditHarness();
  @override
  State<_AuditHarness> createState() => _AuditHarnessState();
}

class _AuditHarnessState extends State<_AuditHarness> {
  bool mobile = false;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF222B3B),
        body: Column(
          children: [
            Material(
              color: const Color(0xFFE8EDF6),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Expanded(child: Text('GST AUDIT · Disposable books')),
                    TextButton(
                      onPressed: () async {
                        await auditContainer
                            .read(activeFirmIdProvider.notifier)
                            .select(auditFirms.first.id);
                      },
                      child: const Text('Non-GST'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await auditContainer
                            .read(activeFirmIdProvider.notifier)
                            .select(auditFirms.last.id);
                      },
                      child: const Text('GST registered'),
                    ),
                    TextButton(
                      onPressed: () =>
                          auditContainer.read(appRouterProvider).go('/reports'),
                      child: const Text('Reports'),
                    ),
                    TextButton(
                      onPressed: () => auditContainer
                          .read(appRouterProvider)
                          .go('/onboarding/firm-setup'),
                      child: const Text('Setup'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        mobile = false;
                        debugDefaultTargetPlatformOverride =
                            TargetPlatform.windows;
                      }),
                      child: const Text('Desktop'),
                    ),
                    TextButton(
                      onPressed: () => setState(() {
                        mobile = true;
                        debugDefaultTargetPlatformOverride =
                            TargetPlatform.android;
                      }),
                      child: const Text('Mobile'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SizedBox(
                  width: mobile ? 412 : double.infinity,
                  child: AtriaApp(key: ValueKey(mobile)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
