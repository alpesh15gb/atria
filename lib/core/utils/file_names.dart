/// Filename safety for documents whose names come from user-facing labels.
///
/// Apex Books numbers documents with slashes — `INV/2026-27/001`, `EST/24-25/07` —
/// because that is how a GST series is written on paper. That string is a
/// label, not a path: handing it straight to `File` makes the OS read each
/// slash as a directory separator, so sharing an invoice looked for
/// `…/Temp/INV/2026-27/001.pdf` and failed with errno 3 (path not found).
/// The same trap exists on Android (`printing`'s `sharePdf` joins the name
/// onto the temp dir before writing).
///
/// Sanitise every name that reaches a filesystem, a share sheet or a print
/// job. The readable number in the UI and the PDF itself is untouched.
library;

/// Only what would genuinely break a path is rewritten: both separators, the
/// rest of the Windows-reserved set (`< > : " | ? *`) and control characters.
/// Deliberately a blacklist — `Sharma & Sons` is a perfectly writable folder
/// name and stripping it to `Sharma _ Sons` would be vandalism for no gain.
final _illegal = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]+');

/// Runs of underscores, so `INV/2026-27/001` reads `INV_2026-27_001` rather
/// than `INV__2026-27__001`.
final _runs = RegExp(r'_{2,}');

/// Leading/trailing dots, spaces and filler underscores. Windows silently
/// strips the first two, which makes a name that "exists" unresolvable later,
/// and a name that is nothing but punctuation reads better as [fallback].
final _edges = RegExp(r'^[.\s_]+|[.\s_]+$');

/// Returns [raw] reduced to a single, safe path component.
///
/// Falls back to [fallback] when nothing usable survives (e.g. a name that was
/// entirely `/`), so callers always get a writable file name.
String sanitizeFileName(String raw, {String fallback = 'document'}) {
  final cleaned = raw
      .trim()
      .replaceAll(_illegal, '_')
      .replaceAll(_runs, '_')
      .replaceAll(_edges, '');
  return cleaned.isEmpty ? fallback : cleaned;
}
