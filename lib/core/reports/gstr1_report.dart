import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:decimal/decimal.dart';

/// Computed GSTR-1 for one filing period — the tables the offline tool's
/// JSON (v1.1) expects. Amounts are Decimal, rounded to 2dp at the edges.
class Gstr1Report {
  const Gstr1Report({
    required this.firmGstin,
    required this.fp,
    required this.b2b,
    required this.b2cl,
    required this.b2cs,
    required this.cdnr,
    required this.cdnur,
    required this.hsn,
    required this.docIssue,
    this.expwp = const [],
    this.expwop = const [],
    this.hash = '',
    this.firmName = '',
    this.from,
    this.to,
    this.bookRows = const [],
  });

  final String firmGstin;
  final String firmName;
  final DateTime? from, to;
  final List<Map<String, Object?>> bookRows;

  /// Envelope hash — the offline utility checks this over the payload. We
  /// emit the SHA-256 of the canonical JSON of the tables, hex-encoded; the
  /// utility recomputes it on import.
  final String hash;

  /// Filing period, MMYYYY (e.g. '042026').
  final String fp;
  final List<Gstr1B2b> b2b;
  final List<Gstr1B2cl> b2cl;
  final List<Gstr1B2cs> b2cs;
  final List<Gstr1Cdnr> cdnr;
  final List<Gstr1Cdnur> cdnur;
  final List<Gstr1Hsn> hsn;
  final List<Gstr1DocIssue> docIssue;

  /// Tables 13A / 13B: zero-rated exports, grouped by place of supply.
  ///
  /// Export invoices used to be skipped outright (`if (doc.isExport) continue`)
  /// so an exporter filed a GSTR-1 that reported no outward supply at all,
  /// while GSTR-3B reported the same invoices under 3.1(b).
  final List<Gstr1Export> expwp;
  final List<Gstr1Export> expwop;

  Map<String, Object?> toJson() => {
    // Preparation data. The current GSTN utility owns its upload envelope;
    // a locally calculated SHA-256 must not impersonate GSTN's hash/version.
    'gstin': firmGstin,
    'fp': fp,
    'b2b': [for (final g in b2b) g.toJson()],
    'b2cl': [for (final g in b2cl) g.toJson()],
    'b2cs': [for (final g in b2cs) g.toJson()],
    'exp': [
      for (final entry in {'WP': expwp, 'WOP': expwop}.entries)
        if (entry.value.isNotEmpty)
          {
            'exp_typ': entry.key,
            'inv': [
              for (final group in entry.value)
                for (final inv in group.invoices)
                  {
                    'inum': inv.inum,
                    'idt': inv.idt,
                    'val': _num(inv.val),
                    'itms': [
                      for (final item in inv.itms)
                        {
                          'rt': item.rate,
                          'txval': _num(item.taxableValue),
                          'iamt': _num(item.igst),
                          'csamt': _num(item.cess),
                        },
                    ],
                  },
            ],
          },
    ],
    'cdnr': [for (final g in cdnr) g.toJson()],
    'cdnur': [for (final g in cdnur) g.toJson()],
    'hsn': {
      if (int.parse(fp.substring(2) + fp.substring(0, 2)) < 202505)
        'data': [for (var i = 0; i < hsn.length; i++) _hsnJson(hsn[i], i)]
      else ...{
        'hsn_b2b': _hsnGroup(true),
        'hsn_b2c': _hsnGroup(false),
      },
    },
    'doc_issue': {
      'doc_det': [
        for (final type in docIssue.map((d) => d.docNum).toSet())
          {
            'doc_num': type,
            'docs': [
              for (final e in docIssue.where((d) => d.docNum == type).indexed)
                {
                  'num': e.$1 + 1,
                  'from': e.$2.from,
                  'to': e.$2.to,
                  'totnum': e.$2.total,
                  'cancel': e.$2.cancelled,
                  'net_issue': e.$2.netIssue,
                },
            ],
          },
      ],
    },
  };

  static Map<String, Object?> _hsnJson(Gstr1Hsn h, int index) => {
    'num': index + 1,
    'hsn_sc': h.hsn,
    'desc': h.description,
    'uqc': h.uqc,
    // Table 12 is rate-wise: the same HSN sold at 5% and at 18% is two
    // rows, and without `rt` the utility rejects the file (every other
    // table in this payload emits it — see Gstr1Item.toJson).
    'rt': h.rate,
    'qty': _num(h.quantity),
    'val': _num(h.totalValue),
    'txval': _num(h.taxableValue),
    'iamt': _num(h.igst),
    'camt': _num(h.cgst),
    'samt': _num(h.sgst),
    'csamt': _num(h.cess),
  };

  List<Map<String, Object?>> _hsnGroup(bool b2b) {
    final rows = hsn.where((row) => row.isB2b == b2b).toList();
    return [for (var i = 0; i < rows.length; i++) _hsnJson(rows[i], i)];
  }

  static Object _num(Decimal d) => double.tryParse(d.toStringAsFixed(2)) ?? 0;

  static Object _numPublic(Decimal d) => _num(d);
}

class Gstr1B2b {
  const Gstr1B2b({required this.ctin, required this.invoices});

  /// Customer GSTIN.
  final String ctin;
  final List<Gstr1Invoice> invoices;

  Map<String, Object?> toJson() => {
    'ctin': ctin,
    'inv': [for (final i in invoices) i.toJson()],
  };
}

class Gstr1Invoice {
  const Gstr1Invoice({
    required this.inum,
    required this.idt,
    required this.val,
    required this.pos,
    required this.reverseCharge,
    required this.invoiceType,
    required this.itms,
  });

  final String inum;

  /// Invoice date, DD-MM-YYYY (the portal's format — NOT ISO).
  final String idt;
  final Decimal val;
  final String pos;
  final bool reverseCharge;

  /// R (regular) | SEWOP | SEWP | DE | CBW.
  final String invoiceType;
  final List<Gstr1Item> itms;

  Map<String, Object?> toJson() => {
    'inum': inum,
    'idt': idt,
    'val': Gstr1Report._numPublic(val),
    'pos': pos,
    'rchrg': reverseCharge ? 'Y' : 'N',
    'inv_typ': invoiceType,
    'itms': [for (final i in itms) i.toJson()],
  };
}

class Gstr1B2cl {
  const Gstr1B2cl({required this.pos, required this.invoices});

  final String pos;
  final List<Gstr1Invoice> invoices;

  Map<String, Object?> toJson() => {
    'pos': pos,
    'inv': [for (final i in invoices) i.toJson()],
  };
}

/// Tables 13A (EXPWP) and 13B (EXPWOP): zero-rated exports grouped by place of
/// supply. There is only ever one group: '96' — "Outside India". A state code
/// is not a legal POS in either table.
///
/// Same row shape as B2CL (`pos` + `inv`), which is what the offline utility
/// expects for both tables.
class Gstr1Export {
  const Gstr1Export({required this.pos, required this.invoices});

  final String pos;
  final List<Gstr1Invoice> invoices;

  Map<String, Object?> toJson() => {
    'pos': pos,
    'inv': [for (final i in invoices) i.toJson()],
  };
}

class Gstr1B2cs {
  const Gstr1B2cs({
    required this.supplyType,
    required this.pos,
    required this.rate,
    required this.taxableValue,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
  });

  /// INTRA | INTER.
  final String supplyType;
  final String pos;
  final double rate;
  final Decimal taxableValue;
  final Decimal igst;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal cess;

  Map<String, Object?> toJson() => {
    'sply_tp': supplyType,
    'pos': pos,
    'typ': 'OE',
    'rt': rate,
    'txval': Gstr1Report._numPublic(taxableValue),
    'iamt': Gstr1Report._numPublic(igst),
    'camt': Gstr1Report._numPublic(cgst),
    'samt': Gstr1Report._numPublic(sgst),
    'csamt': Gstr1Report._numPublic(cess),
  };
}

class Gstr1Cdnr {
  const Gstr1Cdnr({required this.ctin, required this.notes});

  final String ctin;
  final List<Gstr1Note> notes;

  Map<String, Object?> toJson() => {
    'ctin': ctin,
    'nt': [for (final n in notes) n.toJson()],
  };
}

/// Table 10: unregistered / overseas note row. The portal wants the note's
/// own number, date, value and supply bucket at the row level, plus the
/// rate-wise item detail nested under `itms` as
/// `{ "num": 1, "itm_det": { rt, txval, iamt, camt, samt, csamt } }` — the
/// SAME wrapper every invoice and note table in this payload uses.
///
/// The old doc comment here claimed raw rate rows were rejected and that the
/// note's own figures had to stand in for them. That was wrong twice over: the
/// `itm_det` wrapper IS the accepted shape, and the note's number/date/value/
/// `typ` are emitted unconditionally. What is rejected is a bare list of rate
/// fields with no `num`/`itm_det` wrapper — so [toJson] now always serialises
/// through [Gstr1Item.toJson] and builds the no-lines fallback as a real
/// [Gstr1Item] instead of an inline map that happened to look identical.
class Gstr1Cdnur {
  const Gstr1Cdnur({
    required this.ntNum,
    required this.ntDt,
    required this.val,
    required this.ntty,
    required this.pos,
    required this.supplyType,
    this.itms = const [],
    this.customRate,
    this.customTaxableValue,
    this.customIgst,
    this.customCgst,
    this.customSgst,
    this.customCess,
  });

  final String ntNum;
  final String ntDt;
  final Decimal val;

  /// C = credit note, D = debit note.
  final String ntty;
  final String pos;

  /// B2CL | B2CS | EXPWP | EXPWOP — an export note is filed in the export
  /// tables, so a zero-rated note carries the same `typ` as its invoice.
  final String supplyType;

  final List<Gstr1Item> itms;

  final double? customRate;
  final Decimal? customTaxableValue;
  final Decimal? customIgst;
  final Decimal? customCgst;
  final Decimal? customSgst;
  final Decimal? customCess;

  double get rate => customRate ?? (itms.isNotEmpty ? itms.first.rate : 0.0);
  Decimal get taxableValue =>
      customTaxableValue ??
      itms.fold(Decimal.zero, (s, i) => s + i.taxableValue);
  Decimal get igst =>
      customIgst ?? itms.fold(Decimal.zero, (s, i) => s + i.igst);
  Decimal get cgst =>
      customCgst ?? itms.fold(Decimal.zero, (s, i) => s + i.cgst);
  Decimal get sgst =>
      customSgst ?? itms.fold(Decimal.zero, (s, i) => s + i.sgst);
  Decimal get cess =>
      customCess ?? itms.fold(Decimal.zero, (s, i) => s + i.cess);

  Map<String, Object?> toJson() {
    // A note whose line rows have gone missing still has to file: the
    // document totals become one aggregate item. Built as a [Gstr1Item] so
    // there is exactly one place in this file that knows the item shape.
    final rows = itms.isNotEmpty
        ? itms
        : [
            Gstr1Item(
              num: 1,
              rate: rate,
              taxableValue: taxableValue,
              igst: igst,
              cgst: cgst,
              sgst: sgst,
              cess: cess,
            ),
          ];
    return {
      'nt_num': ntNum,
      'nt_dt': ntDt,
      'val': Gstr1Report._numPublic(val),
      'ntty': ntty,
      'pos': pos,
      'typ': supplyType,
      'itms': [for (final i in rows) i.toJson()],
    };
  }
}

class Gstr1Note {
  const Gstr1Note({
    required this.ntNum,
    required this.ntDt,
    required this.val,
    required this.ntty,
    required this.pos,
    required this.reverseCharge,
    required this.itms,
  });

  final String ntNum;
  final String ntDt;
  final Decimal val;

  /// C = credit note, D = debit note.
  final String ntty;
  final String pos;
  final bool reverseCharge;
  final List<Gstr1Item> itms;

  Map<String, Object?> toJson() => {
    'nt_num': ntNum,
    'nt_dt': ntDt,
    'val': Gstr1Report._numPublic(val),
    'ntty': ntty,
    'pos': pos,
    'rchrg': reverseCharge ? 'Y' : 'N',
    'inv_typ': 'R',
    'itms': [for (final i in itms) i.toJson()],
  };
}

class Gstr1Item {
  const Gstr1Item({
    required this.num,
    required this.rate,
    required this.taxableValue,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
  });

  final int num;
  final double rate;
  final Decimal taxableValue;
  final Decimal igst;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal cess;

  Map<String, Object?> toJson() => {
    'num': num,
    'itm_det': {
      'rt': rate,
      'txval': Gstr1Report._numPublic(taxableValue),
      'iamt': Gstr1Report._numPublic(igst),
      'camt': Gstr1Report._numPublic(cgst),
      'samt': Gstr1Report._numPublic(sgst),
      'csamt': Gstr1Report._numPublic(cess),
    },
  };
}

class Gstr1Hsn {
  const Gstr1Hsn({
    this.isB2b = true,
    required this.hsn,
    required this.rate,
    required this.description,
    required this.uqc,
    required this.quantity,
    required this.totalValue,
    required this.taxableValue,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
  });

  final String hsn;
  final bool isB2b;

  /// GST rate of the row, in whole percent (Table 12 is rate-wise).
  final double rate;
  final String description;
  final String uqc;

  /// Quantity in [uqc]. Never negative — see the builder for why a credit
  /// note's negative quantity is not filed.
  final Decimal quantity;
  final Decimal totalValue;
  final Decimal taxableValue;
  final Decimal igst;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal cess;
}

class Gstr1DocIssue {
  const Gstr1DocIssue({
    required this.docNum,
    required this.from,
    required this.to,
    required this.total,
    required this.cancelled,
  });

  /// GST doc-type code: 1 invoices, 4 debit notes, 5 credit notes.
  final int docNum;
  final String from;
  final String to;
  final int total;
  final int cancelled;

  int get netIssue => total - cancelled;
}

/// Computes the GSTR-1 envelope hash over the canonical table JSON
/// (everything except the hash field itself), hex SHA-256.
String computeGstr1Hash(Map<String, Object?> payload) {
  final withoutHash = {
    for (final e in payload.entries)
      if (e.key != 'hash') e.key: e.value,
  };
  final canonical = jsonEncode(withoutHash);
  final digest = sha256.convert(utf8.encode(canonical));
  return digest.toString();
}
