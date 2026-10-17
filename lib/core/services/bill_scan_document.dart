import 'dart:typed_data';

/// Keep PDFs intact for native document input; optional rendering is a fallback.
Future<List<List<int>>> prepareBillScanPages(
  List<int> bytes, {
  Stream<Uint8List> Function(Uint8List)? renderPdf,
}) async {
  const maxBytes = 10 * 1024 * 1024;
  if (bytes.isEmpty || bytes.length > maxBytes) {
    throw const FormatException('Choose a bill file smaller than 10 MB.');
  }
  final isPdf =
      bytes.length >= 5 && String.fromCharCodes(bytes.take(5)) == '%PDF-';
  if (!isPdf) return [bytes];
  if (renderPdf == null) return [bytes];
  final pages = <List<int>>[];
  var total = 0;
  final render = renderPdf;
  await for (final page in render(Uint8List.fromList(bytes))) {
    if (pages.length == 10) {
      throw const FormatException(
        'This PDF has more than 10 pages. Split it into individual bills first.',
      );
    }
    total += page.length;
    if (total > maxBytes) {
      throw const FormatException(
        'The rendered PDF exceeds 10 MB. Choose a smaller PDF or split the bill.',
      );
    }
    pages.add(page);
  }
  if (pages.isEmpty) {
    throw const FormatException('This PDF has no readable pages.');
  }
  return pages;
}
