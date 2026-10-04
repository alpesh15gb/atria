import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';

/// UPI deep-link QR codes for invoice PDFs (Bharat / UPI QR standard).
///
/// `pdf` has no built-in QR encoder, so this wraps the pure-Dart `qr`
/// package: build the module matrix, paint it into a `pw` widget.
class UpiQr {
  UpiQr._();

  /// Builds a UPI intent URI — what UPI apps on the payer's phone parse.
  static String upiUri({
    required String payeeVpa,
    required String payeeName,
    required String amount,
    String? note,
    String? invoiceNumber,
  }) {
    final query = <String, String>{
      'pa': payeeVpa,
      'pn': payeeName,
      'am': amount,
      'cu': 'INR',
      if (note != null && note.isNotEmpty) 'tn': note,
      if (invoiceNumber != null && invoiceNumber.isNotEmpty)
        'tr': invoiceNumber,
    };
    return 'upi://pay?${query.entries.map((e) =>
        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}';
  }

  /// QR widget for the given [data], or null when the data can't be encoded
  /// (too long / empty) — callers just omit the QR then.
  static pw.Widget? widget(String data, {double size = 92}) {
    if (data.isEmpty) return null;
    try {
      final qr = QrCode.fromData(
        data: data,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      final image = QrImage(qr);
      final modules = image.moduleCount;
      return pw.CustomPaint(
        size: PdfPoint(size, size),
        painter: (PdfGraphics canvas, PdfPoint box) {
          final cell = size / modules;
          canvas.setColor(PdfColor.fromInt(0xFF161A18));
          for (var y = 0; y < modules; y++) {
            for (var x = 0; x < modules; x++) {
              if (image.isDark(y, x)) {
                canvas.drawRect(
                  x * cell,
                  size - (y + 1) * cell,
                  cell,
                  cell,
                );
              }
            }
          }
          // `drawRect` only *appends* to the current path — it does not paint.
          // Without this fill the module rectangles stayed pending and were
          // flushed by whichever unrelated widget next called `fillPath()`,
          // which happens under that widget's transform: the QR came out as a
          // grey block on top of the terms and "Receiver's Signature" instead
          // of beside the "Scan to pay" caption. `_BarcodeWidget` in `pdf`
          // fills its own path for exactly this reason.
          canvas.fillPath();
        },
      );
    } on Exception {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
