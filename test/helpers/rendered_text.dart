import 'dart:convert';
import 'dart:io';

/// Decodes the text a PDF actually paints.
///
/// dart_pdf writes text as `[(word)]TJ` inside a content stream that is
/// Flate-compressed, so the words are not greppable in the file itself. Every
/// assertion about what a document *says* has to go through here.
///
/// Asserting on bytes instead would be the obvious alternative and is worse:
/// dart_pdf stamps the cross-reference trailer with the time of day, so two
/// runs of the same builder differ in ~110 bytes of the tail no matter what.
/// Extracting the drawn text is stable across those and is also the thing the
/// assertion is actually about — that a label reaches the page.
Future<String> renderedText(List<int> bytes) async {
  final raw = bytes;
  final streams = <String>[];
  final text = String.fromCharCodes(raw);
  final pattern = RegExp(r'stream\r?\n');
  for (final match in pattern.allMatches(text)) {
    final start = match.end;
    final end = text.indexOf('endstream', start);
    if (end < 0) continue;
    // Content streams are the only ones that inflate; font files do not.
    try {
      streams.add(_inflate(raw.sublist(start, end)));
    } catch (_) {
      continue;
    }
  }
  final buffer = StringBuffer();
  for (final stream in streams) {
    for (final t in RegExp(r'\[\((.*?)\)\]TJ').allMatches(stream)) {
      buffer.write(t
          .group(1)!
          .replaceAll(r'\(', '(')
          .replaceAll(r'\)', ')'));
      buffer.write(' ');
    }
  }
  return buffer.toString();
}

/// Flate-decodes one PDF stream.
String _inflate(List<int> compressed) =>
    utf8.decode(ZLibCodec(level: 6).decode(compressed), allowMalformed: true);