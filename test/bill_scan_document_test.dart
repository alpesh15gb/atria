import 'dart:typed_data';

import 'package:atria/core/services/bill_scan_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final pdf = '%PDF-1.7'.codeUnits;
  test('PDF uploads preserve the original document', () async {
    expect(await prepareBillScanPages(pdf), [pdf]);
  });

  test('renders every PDF page in order', () async {
    final pages = await prepareBillScanPages(
      pdf,
      renderPdf: (_) async* {
        yield Uint8List.fromList([1, 2]);
        yield Uint8List.fromList([3, 4]);
      },
    );
    expect(pages, [
      [1, 2],
      [3, 4],
    ]);
  });

  test('rejects excess pages instead of importing a partial bill', () async {
    await expectLater(
      prepareBillScanPages(
        pdf,
        renderPdf: (_) async* {
          for (var i = 0; i < 11; i++) {
            yield Uint8List.fromList([i]);
          }
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects empty PDFs and oversized rendered uploads', () async {
    await expectLater(
      prepareBillScanPages(pdf, renderPdf: (_) => const Stream.empty()),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      prepareBillScanPages(
        pdf,
        renderPdf: (_) async* {
          yield Uint8List(10 * 1024 * 1024 + 1);
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('image files pass through without PDF rendering', () async {
    final image = [255, 216, 255, 1];
    expect(await prepareBillScanPages(image), [image]);
  });
}
