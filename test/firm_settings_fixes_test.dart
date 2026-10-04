import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Firm Profile form used to be unable to clear anything.
///
/// Every optional field on that form was written through a helper that returned
/// `Value.absent()` for an empty box. Drift's generated `copyWith` reads absent
/// as "leave this column at its old value", and `firmRepository.update` writes
/// the result with `db.update(...).replace(...)` — so clearing a box, pressing
/// Save and seeing "Saved" left the old GSTIN (or phone number, or bank IFSC, or
/// logo) in place, with no way anywhere in the app to remove it.
///
/// The fix is a one-word change that is invisible in review, which is exactly
/// why it needs a test: `Value.absent()` and `Value(null)` look almost the same
/// and behave oppositely.
void main() {
  late AppDatabase db;
  late String firmId;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    final firm = await db.firmRepository.create(name: 'Shri Balaji Traders');
    firmId = firm.id;
    await db.firmRepository.update(firm.copyWith(
      legalName: const Value('Shri Balaji Traders LLP'),
      gstin: const Value('29ABCDE1234F1Z5'),
      pan: const Value('ABCDE1234F'),
      phone: const Value('9876543210'),
      email: const Value('hello@balaji.in'),
      bankIfsc: const Value('HDFC0001234'),
      bankAccountNumber: const Value('50100234567890'),
      invoiceNotes: const Value('Thanks for your business.'),
      logoPath: const Value('/tmp/logos/firm_logo.png'),
    ));
  });

  tearDown(() => db.close());

  /// A blank form: every optional box emptied, exactly what the user sees after
  /// selecting the text in each field and pressing delete.
  FirmEntity clearedProfile(FirmEntity firm) => firm.copyWith(
        legalName: const Value(null),
        gstin: const Value(null),
        pan: const Value(null),
        stateCode: const Value(null),
        addressLine1: const Value(null),
        addressLine2: const Value(null),
        city: const Value(null),
        pincode: const Value(null),
        phone: const Value(null),
        email: const Value(null),
        invoiceTerms: const Value(null),
        invoiceNotes: const Value(null),
        signatureName: const Value(null),
        upiId: const Value(null),
        bankName: const Value(null),
        bankAccountName: const Value(null),
        bankAccountNumber: const Value(null),
        bankIfsc: const Value(null),
        bankBranch: const Value(null),
        logoPath: const Value(null),
      );

  test('an emptied optional field is cleared, not silently kept', () async {
    final before = await db.firmRepository.getById(firmId);
    expect(before!.gstin, '29ABCDE1234F1Z5');
    expect(before.phone, '9876543210');
    expect(before.logoPath, isNotNull);

    await db.firmRepository.update(clearedProfile(before));

    final after = await db.firmRepository.getById(firmId);
    expect(after!.gstin, isNull, reason: 'a cleared GSTIN must not print again');
    expect(after.pan, isNull);
    expect(after.legalName, isNull);
    expect(after.phone, isNull);
    expect(after.email, isNull);
    expect(after.bankIfsc, isNull);
    expect(after.bankAccountNumber, isNull);
    expect(after.invoiceNotes, isNull);
    expect(after.stateCode, isNull);
    expect(
      after.logoPath,
      isNull,
      reason: '"Remove" must actually remove the logo',
    );
    // The required columns are untouched by clearing the optional ones.
    expect(after.name, 'Shri Balaji Traders');
    expect(after.invoicePrefix, 'INV');
  });

  test('absent really does mean "keep it" — the bug being guarded against',
      () async {
    // If this ever stops being true the fix above becomes unnecessary and
    // someone may "simplify" `Value(null)` back to `Value.absent()`.
    final firm = await db.firmRepository.getById(firmId);
    await db.firmRepository.update(firm!.copyWith(gstin: const Value.absent()));

    expect(
      (await db.firmRepository.getById(firmId))!.gstin,
      '29ABCDE1234F1Z5',
    );
  });

  group('the columns the profile form writes', () {
    /// Column names, snake_cased, of the ones the form maps an emptied box onto
    /// `Value(null)`. If a future column is NOT nullable it cannot be cleared
    /// and the form must validate it as required instead — this test is how that
    /// would be noticed.
    const clearable = {
      'legal_name',
      'gstin',
      'pan',
      'state_code',
      'address_line1',
      'address_line2',
      'city',
      'pincode',
      'phone',
      'email',
      'logo_path',
      'invoice_terms',
      'invoice_notes',
      'signature_name',
      'upi_id',
      'bank_name',
      'bank_account_name',
      'bank_account_number',
      'bank_ifsc',
      'bank_branch',
    };

    /// Written as plain trimmed strings by the form, so they must NOT be
    /// nullable: an empty box here has to fail validation, not write null.
    const required = {
      'name',
      'invoice_prefix',
      'quotation_prefix',
      'sales_order_prefix',
      'purchase_prefix',
    };

    Future<Map<String, bool>> nullability() async {
      final info =
          await db.customSelect('PRAGMA table_info(firms)').get();
      return {
        for (final row in info)
          row.read<String>('name'): row.read<int>('notnull') == 1,
      };
    }

    test('every one of them is nullable, so an empty box can clear it',
        () async {
      final notNull = await nullability();
      for (final column in clearable) {
        expect(
          notNull,
          contains(column),
          reason: '$column is missing from the firms table',
        );
        expect(
          notNull[column],
          isFalse,
          reason: '$column is NOT NULL, so clearing it would throw — the form '
              'has to validate it as required instead',
        );
      }
    });

    test('and the ones passed as plain strings are genuinely required',
        () async {
      final notNull = await nullability();
      for (final column in required) {
        expect(notNull, contains(column));
        expect(
          notNull[column],
          isTrue,
          reason: '$column became nullable; the form can stop treating it as '
              'required (or must handle the new possibility)',
        );
      }
    });
  });
}