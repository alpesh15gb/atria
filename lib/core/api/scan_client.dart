import 'dart:convert';

import 'api_config.dart';
import 'server_client.dart' show ServerRequestException;
import 'server_http.dart';

/// One scanned line as the server's model read it off the bill.
class ScannedLine {
  const ScannedLine({
    required this.name,
    this.hsn,
    required this.quantity,
    required this.rate,
    this.unit = 'pcs',
    this.discountPercent = 0,
    this.gstRate = 0,
    this.cessRate = 0,
  });

  final String name;
  final String? hsn;
  final double quantity;
  final double rate;
  final String unit;
  final double discountPercent;
  final double gstRate;
  final double cessRate;

  static double _num(Object? value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? fallback;
    return fallback;
  }

  static ScannedLine fromJson(Map<String, Object?> json) {
    return ScannedLine(
      // A line without a name is useless to the review screen; the model is
      // told to include every printed line, so an empty name means the row
      // was noise and is dropped rather than shown blank.
      name: (json['name'] as String? ?? '').trim(),
      hsn: (json['hsn'] as String?)?.trim(),
      quantity: _num(json['quantity'], 1).abs(),
      rate: _num(json['rate']).abs(),
      unit: (json['unit'] as String? ?? 'pcs').trim(),
      discountPercent: _num(json['discountPercent']).abs(),
      gstRate: _num(json['gstRate']).abs(),
      cessRate: _num(json['cessRate']).abs(),
    );
  }
}

/// One scanned bill, as the server returned it. Every field is a *suggestion*
/// the review screen pre-fills; nothing here is trusted enough to save
/// without a person reading it.
class ScannedBill {
  const ScannedBill({
    required this.lines,
    required this.model,
    this.supplierName,
    this.supplierGstin,
    this.supplierPhone,
    this.supplierAddress,
    this.supplierInvoiceNumber,
    this.billDate,
    this.dueDate,
    this.placeOfSupply,
    this.shippingCharge = 0,
    this.otherCharges = 0,
    this.confidence = 'medium',
    this.warnings = const [],
  });

  final String? supplierName;
  final String? supplierGstin;
  final String? supplierPhone;
  final String? supplierAddress;
  final String? supplierInvoiceNumber;
  final DateTime? billDate;
  final DateTime? dueDate;

  /// Two-letter state code, when the model could read one.
  final String? placeOfSupply;
  final List<ScannedLine> lines;
  final double shippingCharge;
  final double otherCharges;

  /// high | medium | low, straight from the model. Drives the review screen's
  /// headline ("Read confidently" / "Check this carefully").
  final String confidence;

  /// The model's own caveats (inclusive pricing, unreadable totals).
  final List<String> warnings;

  /// Which backend model produced this, shown for provenance.
  final String model;

  static double _num(Object? value) {
    if (value is num) return value.toDouble().abs();
    if (value is String) return double.tryParse(value.trim())?.abs() ?? 0;
    return 0;
  }

  static DateTime? _date(Object? value) {
    if (value is! String) return null;
    final raw = value.trim();
    if (raw.isEmpty) return null;
    // The schema asks for YYYY-MM-DD; parse that directly rather than letting
    // DateTime.tryParse read ambiguous formats differently across locales.
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match != null) {
      return DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
      );
    }
    return DateTime.tryParse(raw);
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static ScannedBill fromJson(Map<String, Object?> json) {
    final rawLines = json['lines'];
    final lines = <ScannedLine>[];
    if (rawLines is List) {
      for (final entry in rawLines) {
        if (entry is Map) {
          final line = ScannedLine.fromJson(entry.cast<String, Object?>());
          if (line.name.isNotEmpty) lines.add(line);
        }
      }
    }
    return ScannedBill(
      supplierName: _string(json['supplierName']),
      supplierGstin: _string(json['supplierGstin'])?.toUpperCase(),
      supplierPhone: _string(json['supplierPhone']),
      supplierAddress: _string(json['supplierAddress']),
      supplierInvoiceNumber: _string(json['supplierInvoiceNumber']),
      billDate: _date(json['billDate']),
      dueDate: _date(json['dueDate']),
      placeOfSupply: _string(json['placeOfSupply']),
      lines: lines,
      shippingCharge: _num(json['shippingCharge']),
      otherCharges: _num(json['otherCharges']),
      confidence: _string(json['confidence']) ?? 'medium',
      warnings: [
        for (final w in (json['warnings'] is List ? json['warnings'] as List : const []))
          if (w is String && w.trim().isNotEmpty) w.trim(),
      ],
      model: _string(json['model']) ?? 'vision model',
    );
  }
}

/// The server's bill-scan endpoint.
///
/// One method: send a photo, get the model's reading. The vendor key lives on
/// the server; this client authenticates with the same Atria session every
/// other call uses.
class ScanClient {
  ScanClient(this._config, {this.timeout = const Duration(seconds: 90)});

  final ApiConfig _config;

  /// Long enough for a vision model to actually read a dense bill; the
  /// request shows its own waiting UI.
  final Duration timeout;

  /// Uploads [imageBytes] and returns the structured reading.
  Future<ScannedBill> scanBill({
    required String firmId,
    required List<int> imageBytes,
    required String mimeType,
    required String accessToken,
  }) async {
    final json = await ServerHttp.requestJson(
      uri: await _config.endpoint('/v1/firms/$firmId/scan-bill'),
      accessToken: accessToken,
      timeout: timeout,
      body: {
        'imageBase64': base64Encode(imageBytes),
        // The server sniffs magic bytes and ignores this, but sending it
        // documents intent and helps future server-side logging.
        'mimeType': mimeType,
      },
      timeoutMessage: 'Scanning took longer than ${timeout.inSeconds} '
          'seconds. Nothing was read; try again.',
    );

    final bill = json['bill'];
    if (bill is! Map) {
      throw const ServerRequestException(
        'The server answered, but not with a bill reading.',
      );
    }
    final merged = <String, Object?>{
      ...bill.cast<String, Object?>(),
      'model': json['model'],
    };
    return ScannedBill.fromJson(merged);
  }
}
