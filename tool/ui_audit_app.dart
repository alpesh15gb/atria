import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/services/demo_seeder.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// A real native app with disposable books. Never opens the user's database.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = AppDatabase.test(NativeDatabase.memory());
  await DemoSeeder(db).seedIfNeeded();
  final firm = (await db.firmRepository.all()).first;
  final container = ProviderContainer(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
  );
  await container.read(onboardingDoneProvider.notifier).complete();
  await container.read(activeFirmIdProvider.notifier).select(firm.id);
  await container.read(appInitializationProvider.future);
  runApp(
    UncontrolledProviderScope(
      container: container,
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
                    const Expanded(
                      child: Text('UI AUDIT · Disposable sample books'),
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
