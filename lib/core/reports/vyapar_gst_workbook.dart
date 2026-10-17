import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import 'package:decimal/decimal.dart';
import 'package:excel/excel.dart';
import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

import '../constants/indian_states.dart';
import 'engine/report_result.dart';
import 'gst_return_builder.dart';
import 'gstr1_report.dart';

/// Reference layouts contain labels and widths only, never customer data.
class VyaparGstWorkbook {
  static const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  String monthYear(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}/${d.year}';
  String uqc(Object? value) {
    final v = '$value'.toUpperCase();
    if (v.contains('-')) return v;
    return switch (v) {
      'PCS' => 'PCS-PIECES',
      'NOS' => 'NOS-NUMBERS',
      'MTR' || 'M' => 'MTR-METERS',
      'KGS' || 'KG' => 'KGS-KILOGRAMS',
      'LTR' || 'L' => 'LTR-LITRES',
      'UNT' => 'UNT-UNITS',
      'BOX' => 'BOX-BOX',
      'SQM' => 'SQM-SQUARE METERS',
      'SET' => 'SET-SETS',
      _ => 'OTH-OTHERS',
    };
  }

  static Future<Map<String, dynamic>>? _layouts;
  final Expando<List<dynamic>> _formats = Expando();
  static const asset = 'assets/templates/vyapar_gst_layouts.json';
  final CellStyle _style = CellStyle(fontFamily: 'Calibri', fontSize: 12);
  Future<Excel> create(String kind) async {
    final layouts = await (_layouts ??= rootBundle
        .loadString(asset)
        .then((s) => jsonDecode(s) as Map<String, dynamic>));
    final definitions = layouts[kind] as List;
    final book = Excel.createExcel();
    _formats[book] = definitions;
    final first = definitions.first['name'] as String;
    book.rename('Sheet1', first);
    book.setDefaultSheet(first);
    for (final definition in definitions) {
      final sheet = book[definition['name'] as String];
      for (final e in (definition['static'] as Map).entries) {
        put(sheet, e.key as String, e.value);
      }
      for (final coordinate in definition['zeros'] as List) {
        put(sheet, coordinate as String, 0);
      }
      for (final e in (definition['widths'] as Map).entries) {
        sheet.setColumnWidth(
          CellIndex.indexByString('${e.key}1').columnIndex,
          (e.value as num).toDouble(),
        );
      }
    }
    return book;
  }

  void put(Sheet sheet, String coordinate, Object? value) {
    if (value == null) return;
    final cell = sheet.cell(CellIndex.indexByString(coordinate));
    if (value is Decimal) value = value.toDouble();
    cell.value = value is num
        ? DoubleCellValue(value.toDouble())
        : TextCellValue('$value');
    cell.cellStyle = _style;
  }

  void row(Sheet sheet, int number, List<Object?> values) {
    for (var i = 0; i < values.length; i++) {
      put(
        sheet,
        CellIndex.indexByColumnRow(columnIndex: i, rowIndex: number - 1).cellId,
        values[i],
      );
    }
  }

  double sum(Iterable<List<Object?>> rows, int index) => double.parse(
    rows
        .fold<double>(
          0,
          (s, r) =>
              s +
              (index < r.length && r[index] is num
                  ? (r[index] as num).toDouble()
                  : 0),
        )
        .toStringAsFixed(2),
  );
  String state(Object? code, {bool includeCode = true}) {
    final c = '$code';
    final name = IndianStates.byCode(c)?.name ?? c;
    return includeCode && name != c ? '$c-$name' : name;
  }

  String date(Object? value, {bool slash = false}) {
    if (value is DateTime) {
      return '${value.day.toString().padLeft(2, '0')}${slash ? '/' : '-'}${slash ? value.month.toString().padLeft(2, '0') : months[value.month - 1].substring(0, 3)}${slash ? '/' : '-'}${value.year}';
    }
    final parts = '$value'.split('-');
    if (parts.length == 3) {
      final parsed = DateTime.tryParse('${parts[2]}-${parts[1]}-${parts[0]}');
      if (parsed != null) return date(parsed, slash: slash);
    }
    return '$value';
  }

  String period(DateTime? from, DateTime? to, String fp) {
    final fallback = DateTime(
      int.parse(fp.substring(2)),
      int.parse(fp.substring(0, 2)),
    );
    final a = from ?? fallback, c = to ?? fallback;
    return '${months[a.month - 1]} ${a.year} - ${months[c.month - 1]} ${c.year}';
  }

  void section(
    Excel book,
    String name,
    List<List<Object?>> data, {
    Map<String, Object?> summary = const {},
  }) {
    final sheet = book[name];
    for (var i = 0; i < data.length; i++) {
      row(sheet, i + 5, data[i]);
    }
    for (final e in summary.entries) {
      put(sheet, e.key, e.value);
    }
  }

  Future<File> save(Excel book, File file) async {
    // Excel's serializer rounds column widths to two decimals. Preserve the
    // reference's original OOXML widths without altering cells or formulas.
    final archive = ZipDecoder().decodeBytes(book.encode()!);
    final definitions = _formats[book]!;
    final output = Archive();
    for (final entry in archive) {
      final match = RegExp(r'^xl/worksheets/sheet(\d+)\.xml$')
          .firstMatch(entry.name);
      if (match == null) {
        output.addFile(entry);
        continue;
      }
      final index = int.parse(match[1]!) - 1;
      if (index >= definitions.length) {
        output.addFile(entry);
        continue;
      }
      final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
      final widths = definitions[index]['widths'] as Map;
      for (final column in xml.findAllElements('col')) {
        final number = int.parse(column.getAttribute('min')!) - 1;
        final key = CellIndex.indexByColumnRow(
          columnIndex: number,
          rowIndex: 0,
        ).cellId.replaceAll(RegExp(r'\d'), '');
        if (widths.containsKey(key)) {
          column.setAttribute('width', '${widths[key]}');
        }
      }
      final bytes = utf8.encode(xml.toXmlString());
      output.addFile(ArchiveFile(entry.name, bytes.length, bytes));
    }
    await file.writeAsBytes(ZipEncoder().encode(output)!, flush: true);
    return file;
  }

  Future<File> gstr1(Gstr1Report report, File file) async {
    final b = await create('GSTR1');
    final main = b['GSTR1 Report'];
    put(main, 'B1', period(report.from, report.to, report.fp));
    put(main, 'B3', report.firmGstin);
    put(main, 'B4', report.firmName);
    final mainRows = <List<Object?>>[];
    for (final r in report.bookRows) {
      mainRows.add([
        r['gstin'],
        r['party'],
        r['type'],
        r['number'],
        date(r['date'], slash: true),
        r['invoiceValue'],
        r['rate'],
        r['cessRate'],
        r['taxable'],
        r['_rcm'] == true ? 'Y' : 'N',
        r['igst'],
        r['cgst'],
        r['sgst'],
        r['cess'],
        state(r['pos'], includeCode: false),
      ]);
    }
    for (var i = 0; i < mainRows.length; i++) {
      row(main, i + 11, mainRows[i]);
    }
    final totalRow = mainRows.length + 12;
    put(main, 'A$totalRow', 'Total');
    for (final c in [5, 8, 10, 11, 12, 13]) {
      put(
        main,
        CellIndex.indexByColumnRow(
          columnIndex: c,
          rowIndex: totalRow - 1,
        ).cellId,
        sum(mainRows, c),
      );
    }
    String party(String gstin, String number) =>
        report.bookRows
            .where((r) => r['gstin'] == gstin && r['number'] == number)
            .map((r) => '${r['party']}')
            .firstOrNull ??
        '';
    final registered = <List<Object?>>[];
    var invoiceValue = 0.0;
    var invoiceCount = 0;
    for (final group in report.b2b) {
      for (final inv in group.invoices) {
        invoiceValue += inv.val.toDouble();
        invoiceCount++;
        for (final i in inv.itms) {
          registered.add([
            group.ctin,
            party(group.ctin, inv.inum),
            inv.inum,
            date(inv.idt),
            inv.val.toDouble(),
            state(inv.pos),
            inv.reverseCharge ? 'Y' : 'N',
            '',
            inv.invoiceType == 'R' ? 'Regular' : inv.invoiceType,
            '',
            i.rate,
            i.taxableValue.toDouble(),
            i.cess.toDouble(),
          ]);
        }
      }
    }
    section(
      b,
      'b2b,sez,de',
      registered,
      summary: {
        'A3': report.b2b.length,
        'C3': invoiceCount,
        'E3': invoiceValue,
        'L3': sum(registered, 11),
        'M3': sum(registered, 12),
      },
    );
    final large = <List<Object?>>[];
    var largeValue = 0.0;
    var largeCount = 0;
    for (final group in report.b2cl) {
      for (final inv in group.invoices) {
        largeCount++;
        largeValue += inv.val.toDouble();
        for (final i in inv.itms) {
          large.add([
            inv.inum,
            date(inv.idt),
            inv.val.toDouble(),
            state(inv.pos),
            '',
            i.rate,
            i.taxableValue.toDouble(),
            i.cess.toDouble(),
            '',
          ]);
        }
      }
    }
    section(
      b,
      'b2cl',
      large,
      summary: {
        'A3': largeCount,
        'C3': largeValue,
        'G3': sum(large, 6),
        'H3': sum(large, 7),
      },
    );
    final small = [
      for (final r in report.b2cs)
        <Object?>[
          'OE',
          state(r.pos),
          '',
          r.rate,
          r.taxableValue.toDouble(),
          r.cess.toDouble(),
          '',
        ],
    ];
    section(
      b,
      'b2cs',
      small,
      summary: {'E3': sum(small, 4), 'F3': sum(small, 5)},
    );
    final notes = <List<Object?>>[];
    var noteValue = 0.0;
    var noteCount = 0;
    for (final group in report.cdnr) {
      for (final n in group.notes) {
        noteCount++;
        noteValue += n.val.toDouble();
        for (final i in n.itms) {
          notes.add([
            group.ctin,
            party(group.ctin, n.ntNum),
            n.ntNum,
            date(n.ntDt),
            n.ntty == 'C' ? 'C-Credit Note' : 'D-Debit Note',
            state(n.pos),
            n.reverseCharge ? 'Y' : 'N',
            'Regular',
            n.val.toDouble(),
            '',
            i.rate,
            i.taxableValue.toDouble(),
            i.cess.toDouble(),
          ]);
        }
      }
    }
    section(
      b,
      'cdnr',
      notes,
      summary: {
        'A3': report.cdnr.length,
        'C3': noteCount,
        'I3': noteValue,
        'L3': sum(notes, 11),
        'M3': sum(notes, 12),
      },
    );
    final ur = <List<Object?>>[];
    var urValue = 0.0;
    for (final n in report.cdnur) {
      urValue += n.val.toDouble();
      final items = n.itms;
      for (final i in items) {
        ur.add([
          n.supplyType,
          n.ntNum,
          date(n.ntDt),
          n.ntty == 'C' ? 'C-Credit Note' : 'D-Debit Note',
          state(n.pos),
          n.val.toDouble(),
          '',
          i.rate,
          i.taxableValue.toDouble(),
          i.cess.toDouble(),
        ]);
      }
    }
    section(
      b,
      'cdnur',
      ur,
      summary: {
        'B3': report.cdnur.length,
        'F3': urValue,
        'I3': sum(ur, 8),
        'J3': sum(ur, 9),
      },
    );
    final exports = <List<Object?>>[];
    var exportValue = 0.0;
    var exportCount = 0;
    for (final e in {'WPAY': report.expwp, 'WOPAY': report.expwop}.entries) {
      for (final g in e.value) {
        for (final inv in g.invoices) {
          exportValue += inv.val.toDouble();
          exportCount++;
          for (final i in inv.itms) {
            exports.add([
              e.key,
              inv.inum,
              date(inv.idt),
              inv.val.toDouble(),
              '',
              '',
              '',
              i.rate,
              i.taxableValue.toDouble(),
            ]);
          }
        }
      }
    }
    section(
      b,
      'exp',
      exports,
      summary: {
        'B3': exportCount,
        'D3': exportValue,
        'F3': 0,
        'I3': sum(exports, 8),
      },
    );
    for (final registered in [true, false]) {
      final h = report.hsn.where((h) => h.isB2b == registered).toList();
      final data = [
        for (final r in h)
          <Object?>[
            r.hsn,
            r.description,
            uqc(r.uqc),
            r.quantity.toDouble(),
            r.totalValue.toDouble(),
            r.rate,
            r.taxableValue.toDouble(),
            r.igst.toDouble(),
            r.cgst.toDouble(),
            r.sgst.toDouble(),
            r.cess.toDouble(),
          ],
      ];
      section(
        b,
        registered ? 'hsn(b2b)' : 'hsn(b2c)',
        data,
        summary: {
          'A3': h.map((h) => h.hsn).toSet().length,
          'E3': sum(data, 4),
          'G3': sum(data, 6),
          'H3': sum(data, 7),
          'I3': sum(data, 8),
          'J3': sum(data, 9),
          'K3': sum(data, 10),
        },
      );
    }
    final itemGroups = <String, List<Object?>>{};
    for (final r in report.bookRows) {
      for (final item in (r['_items'] as List? ?? const [])) {
        final key =
            '${item['hsn']}|${item['name']}|${item['unit']}|${item['rate']}';
        final a = itemGroups.putIfAbsent(
          key,
          () => [
            item['hsn'],
            item['name'],
            uqc(item['unit']),
            0.0,
            0.0,
            item['rate'],
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
          ],
        );
        final fields = {
          3: 'quantity',
          4: 'total',
          6: 'taxable',
          7: 'igst',
          8: 'cgst',
          9: 'sgst',
          10: 'cess',
        };
        for (final e in fields.entries) {
          a[e.key] = (a[e.key] as num) + (item[e.value] as num);
        }
      }
    }
    final itemData = itemGroups.values.toList();
    section(
      b,
      'itemSummary',
      itemData,
      summary: {
        'A3': itemData.map((r) => r[0]).toSet().length,
        'E3': sum(itemData, 4),
        'G3': sum(itemData, 6),
        'H3': sum(itemData, 7),
        'I3': sum(itemData, 8),
        'J3': sum(itemData, 9),
        'K3': sum(itemData, 10),
      },
    );
    final docs = [
      for (final d in report.docIssue)
        <Object?>[
          switch (d.docNum) {
            1 => 'Invoices for outward supply',
            4 => 'Debit Note',
            5 => 'Credit Note',
            _ => 'Document',
          },
          d.from,
          d.to,
          d.total,
          d.cancelled,
        ],
    ];
    section(b, 'docs', docs, summary: {'D3': sum(docs, 3), 'E3': sum(docs, 4)});
    final nil = <int, double>{};
    for (final r in report.bookRows) {
      if (r['rate'] == 0 &&
          r['igst'] == 0 &&
          r['cgst'] == 0 &&
          r['sgst'] == 0) {
        final index =
            (r['gstin'].toString().isNotEmpty ? 5 : 7) +
            (r['_interState'] == true ? 0 : 1);
        nil[index] = (nil[index] ?? 0) + (r['taxable'] as num).toDouble();
      }
    }
    for (final e in nil.entries) {
      put(b['exemp'], 'B${e.key}', e.value);
    }
    put(b['exemp'], 'B3', nil.values.fold<double>(0, (a, c) => a + c));
    return save(b, file);
  }

  Future<File> gstr3b(Gstr3bReport r, File file) async {
    final b = await create('GSTR3B');
    final fallback = DateTime(
      int.parse(r.fp.substring(2)),
      int.parse(r.fp.substring(0, 2)),
    );
    put(b['3.1 Report'], 'B1', monthYear(r.from ?? fallback));
    put(b['3.1 Report'], 'B2', monthYear(r.to ?? fallback));
    row(b['3.1 Report'], 5, [
      null,
      r.outwardTaxable,
      r.outwardIgst,
      r.outwardCgst,
      r.outwardSgst,
      r.outwardCess,
    ]);
    row(b['3.1 Report'], 6, [
      null,
      r.zeroRated,
      r.zeroRatedHeads.igst,
      r.zeroRatedHeads.cgst,
      r.zeroRatedHeads.sgst,
      r.zeroRatedHeads.cess,
    ]);
    row(b['3.1 Report'], 7, [null, r.nilRated, 0, 0, 0, 0]);
    row(b['3.1 Report'], 8, [
      null,
      r.reverseChargeValue,
      r.reverseChargeHeads.igst,
      r.reverseChargeHeads.cgst,
      r.reverseChargeHeads.sgst,
      r.reverseChargeHeads.cess,
    ]);
    var line = 4;
    for (final p in r.interStateByPos) {
      row(b['3.2 Report'], line++, [
        state(p.pos),
        p.taxableValue,
        p.igst,
        0,
        0,
        0,
        0,
      ]);
    }
    row(b['4 Report'], 6, [
      null,
      r.eligibleRcHeads.igst,
      r.eligibleRcHeads.cgst,
      r.eligibleRcHeads.sgst,
      r.eligibleRcHeads.cess,
    ]);
    row(b['4 Report'], 8, [
      null,
      r.otherItcHeads.igst,
      r.otherItcHeads.cgst,
      r.otherItcHeads.sgst,
      r.otherItcHeads.cess,
    ]);
    row(b['5 Report'], 3, [null, r.inwardNilInter, r.inwardNilIntra]);
    return save(b, file);
  }

  Future<File> gstr2(
    ReportResult result,
    File file, {
    String gstin = '',
    String firmName = '',
  }) async {
    final b = await create('GSTR2');
    final rows = [for (final g in result.groups) ...g.rows.map((r) => r.cells)];
    final groups = <String, Map<String, Object?>>{},
        invoices = <String, Map<String, Object?>>{};
    for (final r in rows) {
      final key = '${r['_billId']}|${r['rate']}|${r['cessRate']}';
      for (final e in {key: groups, '${r['_billId']}': invoices}.entries) {
        final target = e.value;
        if (!target.containsKey(e.key)) {
          target[e.key] = Map.of(r);
        } else {
          for (final f in ['taxable', 'igst', 'cgst', 'sgst', 'cess']) {
            target[e.key]![f] = (target[e.key]![f] as num) + (r[f] as num);
          }
          if (target[e.key]!['rate'] != r['rate']) {
            target[e.key]!['rate'] = 'Mixed';
          }
        }
      }
    }
    final main = b['GSTR2 Report'];
    put(
      main,
      'B1',
      period(
        result.window.from,
        result.window.to,
        '${DateTime.now().month.toString().padLeft(2, '0')}${DateTime.now().year}',
      ),
    );
    put(main, 'B3', gstin);
    put(main, 'B4', firmName);
    final sortedInvoices = invoices.values.toList()
      ..sort(
        (a, c) => (a['date'] as DateTime).compareTo(c['date'] as DateTime),
      );
    final mainRows = [
      for (final r in sortedInvoices)
        <Object?>[
          r['gstin'],
          r['party'],
          r['type'],
          r['number'],
          date(r['date'], slash: true),
          r['invoiceValue'],
          r['rate'],
          r['cessRate'],
          r['taxable'],
          r['igst'],
          r['cgst'],
          r['sgst'],
          r['cess'],
          state(r['pos'], includeCode: false),
        ],
    ];
    for (var i = 0; i < mainRows.length; i++) {
      row(main, i + 11, mainRows[i]);
    }
    final end = mainRows.length + 12;
    put(main, 'A$end', 'Total');
    for (final c in [5, 8, 9, 10, 11, 12]) {
      put(
        main,
        CellIndex.indexByColumnRow(columnIndex: c, rowIndex: end - 1).cellId,
        sum(mainRows, c),
      );
    }
    for (final registered in [true, false]) {
      final purchase = groups.values
          .where(
            (r) =>
                r['type'] == 'Purchase' &&
                r['gstin'].toString().trim().isNotEmpty == registered,
          )
          .toList();
      final data = <List<Object?>>[];
      for (final r in purchase) {
        final eligible = registered && r['_itc'] == true;
        final a = <Object?>[
          registered ? r['gstin'] : r['party'],
          r['number'],
          date(r['date']),
          r['invoiceValue'],
          state(r['pos']),
          registered
              ? (r['_rcm'] == true ? 'Y' : 'N')
              : (r['_interState'] == true ? 'Inter State' : 'Intra State'),
          'Regular',
          r['rate'],
          r['taxable'],
          r['igst'],
          r['cgst'],
          r['sgst'],
          r['cess'],
          eligible ? 'Inputs' : 'Ineligible',
          for (final f in ['igst', 'cgst', 'sgst', 'cess']) eligible ? r[f] : 0,
        ];
        if (!registered) a.removeAt(6);
        data.add(a);
      }
      final unique = {for (final r in purchase) r['_billId']: r};
      section(
        b,
        registered ? 'b2b' : 'b2bur',
        data,
        summary: registered
            ? {
                'A3': purchase.map((r) => r['gstin']).toSet().length,
                'B3': unique.length,
                'D3': unique.values.fold<double>(
                  0,
                  (a, r) => a + (r['invoiceValue'] as num).toDouble(),
                ),
                for (final e in {
                  'I3': 8,
                  'J3': 9,
                  'K3': 10,
                  'L3': 11,
                  'M3': 12,
                  'O3': 14,
                  'P3': 15,
                  'Q3': 16,
                  'R3': 17,
                }.entries)
                  e.key: sum(data, e.value),
              }
            : {
                'B3': unique.length,
                'D3': unique.values.fold<double>(
                  0,
                  (a, r) => a + (r['invoiceValue'] as num).toDouble(),
                ),
                for (final e in {
                  'H3': 7,
                  'I3': 8,
                  'J3': 9,
                  'K3': 10,
                  'L3': 11,
                  'N3': 13,
                  'O3': 14,
                  'P3': 15,
                  'Q3': 16,
                }.entries)
                  e.key: sum(data, e.value),
              },
      );
      final returns = groups.values
          .where(
            (r) =>
                r['type'] == 'Purchase Return' &&
                r['gstin'].toString().trim().isNotEmpty == registered,
          )
          .toList();
      final notes = <List<Object?>>[];
      for (final r in returns) {
        final a = <Object?>[
          r['gstin'],
          r['number'],
          date(r['date']),
          '',
          '',
          'N',
          'C',
          'Sales Return',
          r['_interState'] == true ? 'Inter State' : 'Intra State',
          (r['invoiceValue'] as num).abs(),
          r['rate'],
          (r['taxable'] as num).abs(),
          (r['igst'] as num).abs(),
          (r['cgst'] as num).abs(),
          (r['sgst'] as num).abs(),
          (r['cess'] as num).abs(),
          registered && r['_itc'] == true ? 'Inputs' : 'Ineligible',
          for (final f in ['igst', 'cgst', 'sgst', 'cess'])
            registered && r['_itc'] == true ? (r[f] as num).abs() : 0,
        ];
        if (!registered) {
          a.removeAt(0);
          a.insert(8, 'Regular');
        }
        notes.add(a);
      }
      final uniqueNotes = {for (final r in returns) r['_billId']: r};
      section(
        b,
        registered ? 'cdnr' : 'cdnur',
        notes,
        summary: {
          if (registered) 'A3': returns.map((r) => r['gstin']).toSet().length,
          registered ? 'B3' : 'A3': uniqueNotes.length,
          'J3': uniqueNotes.values.fold<double>(
            0,
            (a, r) => a + (r['invoiceValue'] as num).abs(),
          ),
          for (final e in {
            'L3': 11,
            'M3': 12,
            'N3': 13,
            'O3': 14,
            'P3': 15,
            'R3': 17,
            'S3': 18,
            'T3': 19,
            'U3': 20,
          }.entries)
            e.key: sum(notes, e.value),
        },
      );
    }
    for (final itemWise in [false, true]) {
      final hsns = <String, List<Object?>>{};
      for (final r in rows) {
        final key = '${r['_hsn']}|${r['_unit']}|${itemWise ? r['_name'] : ''}';
        final a = hsns.putIfAbsent(
          key,
          () => [
            r['_hsn'],
            itemWise ? r['_name'] : '',
            uqc(r['_unit']),
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
          ],
        );
        final fields = [
          '_qty',
          '_total',
          'taxable',
          'igst',
          'cgst',
          'sgst',
          'cess',
        ];
        for (var i = 0; i < fields.length; i++) {
          a[i + 3] = (a[i + 3] as num) + (r[fields[i]] as num);
        }
      }
      final data = hsns.values.toList();
      section(
        b,
        itemWise ? 'itemSummary' : 'hsnsum',
        data,
        summary: {
          'A3': data.map((r) => r[0]).toSet().length,
          for (final e in {
            'E3': 4,
            'F3': 5,
            'G3': 6,
            'H3': 7,
            'I3': 8,
            'J3': 9,
          }.entries)
            e.key: sum(data, e.value),
        },
      );
    }
    return save(b, file);
  }
}
