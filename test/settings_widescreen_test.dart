import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/database/repositories/sales_repository.dart';
import 'package:atria/core/engine/gst_engine.dart';
import 'package:atria/core/printer/printer_profile.dart';
import 'package:atria/core/printer/printer_service.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/core/theme/app_typography.dart';
import 'package:atria/features/sales/payment_reminders_screen.dart';
import 'package:atria/features/settings/period_lock_and_audit_screens.dart';
import 'package:atria/features/settings/printer_settings_screen.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pushed settings screens on a maximised Windows window.

/// These four (printer settings, period lock, audit log, payment reminders)
/// used to stretch edge to edge at 1920dp — a printer card and its action row
/// spread so wide the probe buttons sat a full screen from the printer's name.
/// Each is wrapped in [AtriaContentWidth] now; this asks both that nothing
/// errors and that the column really did stop short of the window edge.
///
/// Real rows are seeded, not an empty state: an empty screen's widest content
/// is its centred message, which is narrow by design and would make the width
/// assertion pass for the wrong reason.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  Future<void> loadAppFont() async {
    final loader = FontLoader(AppTypography.family);
    loader.addFont(rootBundle.load('assets/fonts/Inter[opsz,wght].ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Inter-Italic[opsz,wght].ttf'));
    await loader.load();
  }

  Future<(AppDatabase, ProviderContainer)> boot() async {
    await loadAppFont();
    final db = AppDatabase.test(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    final firm = await db.firmRepository.create(name: 'Shri Balaji Traders');
    await container.read(activeFirmIdProvider.notifier).ready;
    await container.read(activeFirmIdProvider.notifier).select(firm.id);

    // One printer profile, so the printer list has a card to lay out.
    await container
        .read(printerRegistryProvider)
        .upsert(
          const PrinterProfile(
            id: 'ptr_counter',
            name: 'Counter TSC',
            host: '192.168.1.50',
          ),
        );

    // One overdue invoice, so payment reminders has a row and the audit log
    // has an entry to show.
    final party = await db.partyRepositoryFor(firm.id).create(name: 'Keystone');
    await db
        .salesRepositoryFor(firm.id)
        .save(
          SalesDraft(
            id: 'inv_overdue',
            number: 'INV/2026/001',
            docType: 'invoice',
            partyId: party.id,
            partyName: party.name,
            invoiceDate: DateTime(2026, 8, 1),
            dueDate: DateTime(2026, 8, 15),
            status: 'confirmed',
            lines: [
              SalesLineDraft(
                id: 'ln_1',
                name: 'Consulting',
                quantity: Decimal.one,
                unit: 'Nos',
                rate: Decimal.fromInt(12000),
                gstRate: 0,
                cessRate: 0,
                taxMode: TaxMode.exclusive,
              ),
            ],
            applyRoundOff: false,
            sequence: 0,
          ),
        );
    return (db, container);
  }

  Future<void> dispose(
    WidgetTester tester,
    AppDatabase db,
    ProviderContainer container,
  ) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await db.close();
  }

  for (final screen in [
    ('printer settings', const PrinterSettingsScreen()),
    ('period lock', const PeriodLockScreen()),
    ('audit log', const AuditLogScreen()),
    ('payment reminders', const PaymentRemindersScreen()),
  ]) {
    testWidgets(
      '${screen.$1} caps its column and does not error at 1920dp',
      timeout: timeout,
      (tester) async {
        final (db, container) = await boot();

        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 1;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              // Declared: `flutter test` defaults `defaultTargetPlatform` to
               // android, and the content cap is now chosen by platform — so
               // without this a 1920dp *desktop* claim is measured against the
               // 560dp phone column and passes for the wrong reason.
               theme: AppTheme.light()
                   .copyWith(platform: TargetPlatform.windows),
              home: Scaffold(body: screen.$2),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        final error = tester.takeException();

        // The outermost Scrollable is the screen's own list — the thing that
        // used to be 1920px wide. A nested scrollable (a dropdown's menu) is
        // narrower, so `first` is the one that carries the cap.
        final scrollWidth = tester.getRect(find.byType(Scrollable).first).width;

        await dispose(tester, db, container);

        expect(error, isNull, reason: '${screen.$1} errors at 1920dp');
        expect(
          scrollWidth,
          lessThan(1500),
          reason: '${screen.$1} stretches edge to edge on a 1920dp window',
        );
        expect(
          scrollWidth,
          greaterThan(600),
          reason: '${screen.$1} column is narrower than its content needs',
        );
      },
    );
  }
}
