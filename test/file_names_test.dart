import 'package:atria/core/utils/file_names.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Document numbers are series labels written with slashes (`INV/2026-27/001`).
/// Handing one straight to `File` made the OS read each slash as a directory
/// separator, so sharing an invoice failed with
/// `PathNotFoundException: …/Temp/INV/2026-27/001.pdf (errno = 3)`.
///
/// These tests pin the property that matters for every filesystem, share-sheet
/// and print call site: the sanitised name is a *single* path component.
void main() {
  group('sanitizeFileName', () {
    test('turns an invoice number into one path component', () {
      final name = sanitizeFileName('INV/2026-27/001');

      expect(name, 'INV_2026-27_001');
      expect(p.basename(name), name, reason: 'must not introduce folders');
      expect(
        p.dirname(p.join(r'C:\Temp', '$name.pdf')),
        r'C:\Temp',
        reason: 'joining must stay inside the temp directory',
      );
    });

    test('strips every separator and Windows-reserved character', () {
      expect(sanitizeFileName(r'ACME\Retail/2026:Q1*"?<>|'), 'ACME_Retail_2026_Q1');
      expect(sanitizeFileName('a\u0000b'), isNot(contains('\u0000')));
    });

    test('is safe for the names users actually type', () {
      expect(sanitizeFileName('Sharma Traders & Sons'), 'Sharma Traders & Sons');
      expect(sanitizeFileName('Ram/Shyam Stores'), 'Ram_Shyam Stores');
      expect(sanitizeFileName('  spaces  '), 'spaces');
    });

    test('collapses runs and trims dots/spaces on the edges', () {
      expect(sanitizeFileName('A///B'), 'A_B');
      expect(sanitizeFileName('.hidden.'), 'hidden');
    });

    test('falls back when nothing usable survives', () {
      expect(sanitizeFileName('///'), 'document');
      expect(sanitizeFileName('   '), 'document');
      expect(sanitizeFileName('///', fallback: 'atria-backup'), 'atria-backup');
    });
  });
}
