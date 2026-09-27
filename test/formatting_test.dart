import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/utils/formatters.dart';
import 'package:atria/core/utils/money.dart';
import 'package:atria/core/utils/validators.dart';
import 'package:atria/shared/widgets/money_text.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guards for the money layer. `indianGroup` mis-grouped every
/// amount over ₹999 (1234 rendered as "12,34"), `money` did not pad 2dp, and
/// `SettingsRepository.set` appended a duplicate row for global keys instead
/// of replacing — which then crashed the next read.
void main() {
  group('indianGroup', () {
    test('rightmost group of 3, then groups of 2', () {
      expect(Formatters.indianGroup('999'), '999');
      expect(Formatters.indianGroup('1000'), '1,000');
      expect(Formatters.indianGroup('1234'), '1,234');
      expect(Formatters.indianGroup('12345'), '12,345');
      expect(Formatters.indianGroup('123456'), '1,23,456');
      expect(Formatters.indianGroup('1234567'), '12,34,567');
      expect(Formatters.indianGroup('12345678'), '1,23,45,678');
      expect(Formatters.indianGroup('1234567.89'), '12,34,567.89');
    });

    test('keeps the minus sign on negative integer parts', () {
      expect(Formatters.indianGroup('-1234'), '-1,234');
    });
  });

  group('Formatters.money', () {
    test('always shows exactly 2 decimals and the Indian grouping', () {
      expect(Formatters.money(Decimal.parse('100')), '₹100.00');
      expect(Formatters.money(Decimal.parse('1.5')), '₹1.50');
      expect(Formatters.money(Decimal.parse('1234567.89')), '₹12,34,567.89');
    });

    test('renders negatives with a leading minus', () {
      expect(Formatters.money(Decimal.parse('-1234')), '-₹1,234.00');
    });
  });

  group('Formatters.number', () {
    test('pads to the requested decimals', () {
      expect(Formatters.number(Decimal.parse('100')), '100.00');
      expect(Formatters.number(Decimal.parse('1234567')), '12,34,567.00');
    });
  });

  group('MoneyText', () {
    testWidgets('shows the minus sign for a negative amount by default',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MoneyText(Decimal.fromInt(-500))),
        ),
      );
      expect(find.text('-₹500.00'), findsOneWidget);
    });

    testWidgets('signed mode renders + and - prefixes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Column(
            children: [
              MoneyText(Decimal.fromInt(500), signMode: MoneySignMode.always),
              MoneyText(Decimal.fromInt(-500), signMode: MoneySignMode.always),
            ],
          ),
        ),
      );
      expect(find.text('+₹500.00'), findsOneWidget);
      expect(find.text('-₹500.00'), findsOneWidget);
    });
  });

  group('Money arithmetic', () {
    test('div rounds rather than truncating', () {
      // 200 / 3 = 66.666... -> must round to 66.67, not truncate to 66.66.
      expect(Money.div(Decimal.fromInt(200), Decimal.fromInt(3)),
          Decimal.parse('66.67'));
    });
  });

  group('SettingsRepository', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.test(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('writing a global key twice does not duplicate the row', () async {
      final settings = SettingsRepository(db);
      await settings.setBool(SettingsRepository.kThemeMode, true);
      await settings.setBool(SettingsRepository.kThemeMode, false);
      await settings.setBool(SettingsRepository.kThemeMode, true);

      // The historical failure: duplicates made getSingleOrNull() throw.
      expect(await settings.getBool(SettingsRepository.kThemeMode), isTrue);
      final rows = await db.select(db.appSettings).get();
      expect(rows.where((r) => r.key == SettingsRepository.kThemeMode).length,
          1);
    });
  });

  group('GSTIN validation', () {
    test('a required GSTIN is rejected when empty', () {
      expect(Validators.gstin('', required: true), 'GSTIN is required');
      expect(Validators.gstin(null, required: true), 'GSTIN is required');
      // Optional by default, so an unregistered party still saves.
      expect(Validators.gstin(''), isNull);
    });

    test('the state prefix must match the selected state', () {
      // 29 is Karnataka. The party form accepted both before, and the invoice
      // built on it would then file against the wrong state.
      expect(Validators.gstinStateMismatch('29AAACR1234F1Z5', '29'), isNull);
      expect(Validators.gstinStateMismatch('29AAACR1234F1Z5', '27'),
          'State code does not match the selected state');
    });

    test('the state check stays quiet when there is nothing to compare', () {
      expect(Validators.gstinStateMismatch(null, '29'), isNull);
      expect(Validators.gstinStateMismatch('29AAACR1234F1Z5', null), isNull);
      // A half-typed GSTIN would otherwise block the field with a misleading
      // message about the state.
      expect(Validators.gstinStateMismatch('29', '29'), isNull);
    });
  });
}
