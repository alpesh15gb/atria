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
    this.hash = '',
  });

  final String firmGstin;

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

  Map<String, Object?> toJson() => {
        // The offline utility requires the envelope fields on every upload.
        'version': '1.1',
        'hash': hash,
        'gstin': firmGstin,
        'fp': fp,
        'gtin': firmGstin,
        'b2b': [for (final g in b2b) g.toJson()],
        'b2cl': [for (final g in b2cl) g.toJson()],
        'b2cs': [for (final g in b2cs) g.toJson()],
        'cdnr': [for (final g in cdnr) g.toJson()],
        'cdnur': [for (final g in cdnur) g.toJson()],
        'hsn': {
          'data': [for (var i = 0; i < hsn.length; i++) _hsnJson(hsn[i], i)],
        },
        'doc_issue': {
          'doc_det': docIssue.asMap().entries.map((e) => {
                'doc_num': e.value.docNum,
                'docs': [
                  {
                    'num': 1,
                    'from': e.value.from,
                    'to': e.value.to,
                    'totnum': e.value.total,
                    'cancel': e.value.cancelled,
                    'net_issue': e.value.netIssue,
                  }
                ],
              }).toList(),
        },
      };

  static Map<String, Object?> _hsnJson(Gstr1Hsn h, int index) => {
        'num': index + 1,
        'hsn_sc': h.hsn,
        'desc': h.description,
        'uqc': h.uqc,
        'qty': _num(h.quantity),
        'val': _num(h.totalValue),
        'txval': _num(h.taxableValue),
        'iamt': _num(h.igst),
        'camt': _num(h.cgst),
        'samt': _num(h.sgst),
        'csamt': _num(h.cess),
      };

  static Object _num(Decimal d) => double.tryParse(d.toStringAsFixed(2)) ?? 0;

  static Object _numPublic(Decimal d) => _num(d);
}

class Gstr1B2b {
  const Gstr1B2b({
    required this.ctin,
    required this.invoices,
  });

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
  const Gstr1B2cl({
    required this.pos,
    required this.invoices,
  });

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
  const Gstr1Cdnr({
    required this.ctin,
    required this.notes,
  });

  final String ctin;
  final List<Gstr1Note> notes;

  Map<String, Object?> toJson() => {
        'ctin': ctin,
        'nt': [for (final n in notes) n.toJson()],
      };
}

/// Table 10: unregistered / overseas note row. The portal wants the note's
/// own number, date, value and supply bucket — raw rate rows are rejected.
class Gstr1Cdnur {
  const Gstr1Cdnur({
    required this.ntNum,
    required this.ntDt,
    required this.val,
    required this.ntty,
    required this.pos,
    required this.rate,
    required this.taxableValue,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
    required this.supplyType,
  });

  final String ntNum;
  final String ntDt;
  final Decimal val;

  /// C = credit note, D = debit note.
  final String ntty;
  final String pos;
  final double rate;
  final Decimal taxableValue;
  final Decimal igst;
  final Decimal cgst;
  final Decimal sgst;
  final Decimal cess;

  /// B2CL | B2CS (export-with-payment uses EXPWP, without EXPWOP).
  final String supplyType;

  Map<String, Object?> toJson() => {
        'nt_num': ntNum,
        'nt_dt': ntDt,
        'val': Gstr1Report._numPublic(val),
        'ntty': ntty,
        'pos': pos,
        'typ': supplyType,
        'itms': [
          {
            'num': 1,
            'itm_det': {
              'rt': rate,
              'txval': Gstr1Report._numPublic(taxableValue),
              'iamt': Gstr1Report._numPublic(igst),
              'camt': Gstr1Report._numPublic(cgst),
              'samt': Gstr1Report._numPublic(sgst),
              'csamt': Gstr1Report._numPublic(cess),
            },
          }
        ],
      };
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
    required this.hsn,
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
  final String description;
  final String uqc;
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
