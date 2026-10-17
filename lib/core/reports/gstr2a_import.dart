import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

/// Read portal JSON/ZIP or invoice-level Excel downloads without changing books.
Map<String, dynamic> decodeGstr2a(List<int> bytes) {
  if (bytes.length > 50 * 1024 * 1024) {
    throw const FormatException(
      'The statement exceeds the 50 MB import limit.',
    );
  }
  if (bytes.length >= 2 && bytes[0] == 80 && bytes[1] == 75) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.any((f) => f.name == 'xl/workbook.xml')) {
      return _fromExcel(bytes);
    }
    final files = archive.where(
      (f) => f.isFile && f.name.toLowerCase().endsWith('.json'),
    );
    if (files.isEmpty) {
      throw const FormatException('ZIP contains no GSTR-2A JSON.');
    }
    final merged = <String, dynamic>{'b2b': <dynamic>[]};
    var expanded = 0;
    for (final file in files) {
      expanded += file.size;
      if (expanded > 50 * 1024 * 1024) {
        throw const FormatException('Expanded statement exceeds 50 MB.');
      }
      final part = decodeGstr2a(file.content as List<int>);
      for (final key in ['gstin', 'fp']) {
        if (merged[key] != null &&
            part[key] != null &&
            merged[key] != part[key]) {
          throw const FormatException(
            'ZIP contains different GSTINs or return periods.',
          );
        }
        if (part[key] != null) merged[key] = part[key];
      }
      (merged['b2b'] as List).addAll(part['b2b'] as List);
      for (final section in ['cdn', 'cdnr']) {
        if (part[section] is List) {
          (merged.putIfAbsent(section, () => <dynamic>[]) as List).addAll(
            part[section] as List,
          );
        }
      }
    }
    return merged;
  }
  final decoded = jsonDecode(utf8.decode(bytes).replaceFirst('\uFEFF', ''));
  if (decoded is! Map) {
    throw const FormatException('Expected a GSTR-2A JSON object.');
  }
  var result = Map<String, dynamic>.from(decoded);
  if (result['data'] is Map) {
    result = Map<String, dynamic>.from(result['data'] as Map);
  }
  if (result['b2b'] is! List &&
      result['cdn'] is! List &&
      result['cdnr'] is! List) {
    throw const FormatException(
      'No B2B invoice section found in this GSTR-2A statement.',
    );
  }
  result.putIfAbsent('b2b', () => <dynamic>[]);
  return result;
}

Map<String, dynamic> _fromExcel(List<int> bytes) {
  final workbook = Excel.decodeBytes(bytes);
  final suppliers = <String, Map<String, dynamic>>{};
  String norm(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  for (final sheet in workbook.tables.values) {
    Map<String, int>? columns;
    for (final row in sheet.rows) {
      final text = [
        for (final cell in row) cell?.value?.toString().trim() ?? '',
      ];
      if (columns == null) {
        final candidate = <String, int>{};
        for (var i = 0; i < text.length; i++) {
          final h = norm(text[i]);
          if (h.contains('gstin') &&
              (h.contains('supplier') || h.contains('seller'))) {
            candidate['gstin'] = i;
          }
          if (h.contains('invoice') &&
              (h.contains('number') || h.contains('no'))) {
            candidate['number'] = i;
          }
          if (h.contains('invoice') && h.contains('date')) {
            candidate['date'] = i;
          }
          if (h.contains('taxable') && h.contains('value')) {
            candidate['taxable'] = i;
          }
          if (h.contains('integratedtax') || h == 'igst') candidate['igst'] = i;
          if (h.contains('centraltax') || h == 'cgst') candidate['cgst'] = i;
          if (h.contains('statetax') ||
              h.contains('stateuttax') ||
              h == 'sgst') {
            candidate['sgst'] = i;
          }
          if (h.contains('cess')) candidate['cess'] = i;
          if (h.contains('invoicevalue')) candidate['value'] = i;
        }
        if (['gstin', 'number', 'taxable'].every(candidate.containsKey)) {
          columns = candidate;
        }
        continue;
      }
      String get(String key) =>
          columns![key] == null || columns[key]! >= text.length
          ? ''
          : text[columns[key]!];
      double num(String key) =>
          double.tryParse(get(key).replaceAll(',', '')) ?? 0;
      final gstin = get('gstin').toUpperCase();
      if (!RegExp(r'^\d{2}[A-Z0-9]{13}$').hasMatch(gstin) ||
          get('number').isEmpty) {
        continue;
      }
      final supplier = suppliers.putIfAbsent(
        gstin,
        () => {'ctin': gstin, 'inv': <dynamic>[]},
      );
      final invoices = supplier['inv'] as List;
      final existing = invoices.where(
        (i) => i['inum'] == get('number') && i['idt'] == get('date'),
      );
      final invoice = existing.isEmpty
          ? <String, dynamic>{
              'inum': get('number'),
              'idt': get('date'),
              'val': num('value'),
              'itms': <dynamic>[],
            }
          : existing.first as Map<String, dynamic>;
      if (existing.isEmpty) invoices.add(invoice);
      (invoice['itms'] as List).add({
        'itm_det': {
          'txval': num('taxable'),
          'iamt': num('igst'),
          'camt': num('cgst'),
          'samt': num('sgst'),
          'csamt': num('cess'),
        },
      });
    }
  }
  if (suppliers.isEmpty) {
    throw const FormatException(
      'No invoice-level GSTR-2A rows found. Choose the portal B2B detail workbook.',
    );
  }
  return {'b2b': suppliers.values.toList()};
}
