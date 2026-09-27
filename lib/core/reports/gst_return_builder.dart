import 'package:decimal/decimal.dart';

import '../database/app_database.dart';
import '../database/repositories/repository_extensions.dart';
import 'gstr1_report.dart';

Decimal _d(double v) => Decimal.parse(v.toStringAsFixed(2));

String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year.toString()}';

/// Builds GSTR-1 and GSTR-3B payloads from the books for one filing period.
/// All non-cancelled, non-deleted documents in [from, to].
class GstReturnBuilder {
  GstReturnBuilder(this.db, this.firmId);

  final AppDatabase db;
  final String firmId;

  Future<Gstr1Report> buildGstr1({
    required DateTime from,
    required DateTime to,
  }) async {
    final firm = await (db.select(db.firms)
          ..where((t) => t.id.equals(firmId)))
        .getSingleOrNull();
    final sales = db.salesRepositoryFor(firmId);
    final docs = await sales.list(docType: 'invoice', from: from, to: to, limit: 1000000);
    final creditNotes = await sales.list(
        docType: 'credit_note', from: from, to: to, limit: 1000000);

    final activeDocs =
        docs.where((d) => d.status != 'cancelled').toList(growable: false);

    // ---- B2B (registered customers, Table 4) -----------------------------
    final b2bByGstin = <String, List<SalesInvoiceEntity>>{};
    final b2clInvoices = <SalesInvoiceEntity>[];
    final b2csInvoices = <SalesInvoiceEntity>[];

    for (final doc in activeDocs) {
      final gstin = (doc.partyGstin ?? '').trim().toUpperCase();
      // Zero-rated supplies (exports / SEZ with supplied-to-SEZ flag) are
      // reported separately from B2CS/B2CL; a GSTR-1 exporter reports them
      // in the export tables, so keep them out of the domestic buckets.
      if (doc.isExport) continue;
      final interState = doc.isInterState;
      // B2CL rule: inter-state supply to an unregistered buyer where the
      // TAXABLE value exceeds ₹2.5 lakh (the old check compared the GROSS
      // total incl. tax with >=, bucketing invoices the portal would deny).
      final large = doc.taxableValue > 250000 && interState && gstin.isEmpty;
      if (gstin.isNotEmpty) {
        b2bByGstin.putIfAbsent(gstin, () => []).add(doc);
      } else if (large) {
        b2clInvoices.add(doc);
      } else {
        b2csInvoices.add(doc);
      }
    }

    final b2b = <Gstr1B2b>[];
    for (final entry in b2bByGstin.entries) {
      final invoices = <Gstr1Invoice>[];
      for (final doc in entry.value) {
        invoices.add(await _invoice(doc, doc.placeOfSupply ?? ''));
      }
      b2b.add(Gstr1B2b(ctin: entry.key, invoices: invoices));
    }

    // ---- CDNUR (Table 10): unregistered/overseas notes --------------------
    // Full note rows (number, date, value, type) — raw rate rows were an
    // invalid table.
    final cdnur = <Gstr1Cdnur>[];
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;      final gstin = (cn.partyGstin ?? '').trim().toUpperCase();
      if (gstin.isNotEmpty) continue; // registered → CDNR
      // B2CL-large unregistered notes must be flagged; 'B2CL' requires the
      // same ₹2.5L taxable rule, so only that qualifies.
      final isB2cl = cn.isInterState && cn.taxableValue >= 250000;
      cdnur.add(Gstr1Cdnur(
        ntNum: cn.number,
        ntDt: _fmtDate(cn.invoiceDate),
        val: _d(cn.grandTotal),
        ntty: 'C',
        pos: cn.placeOfSupply ?? '',
        rate: 0,
        taxableValue: _d(cn.taxableValue),
        igst: _d(cn.igst),
        cgst: _d(cn.cgst),
        sgst: _d(cn.sgst),
        cess: _d(cn.cess),
        supplyType: isB2cl ? 'B2CL' : 'B2CS',
      ));
    }

    // ---- B2CL (Table 5): inter-state > ₹2.5L, unregistered ---------------
    final b2clByPos = <String, List<Gstr1Invoice>>{};
    for (final doc in b2clInvoices) {
      final pos = doc.placeOfSupply ?? '';
      b2clByPos.putIfAbsent(pos, () => []).add(await _invoice(doc, pos));
    }
    final b2cl = [
      for (final e in b2clByPos.entries)
        Gstr1B2cl(pos: e.key, invoices: e.value),
    ];

    // ---- B2CS (Table 7): aggregates by (supply type, POS, rate) ----------
    final b2csKeyed = <String, Gstr1B2cs>{};
    for (final doc in b2csInvoices) {
      final items = await sales.itemsFor(doc.id);
      final inter = doc.isInterState;
      final pos = doc.placeOfSupply ?? '';
      for (final l in items) {
        final key = '${inter ? 'INTER' : 'INTRA'}|$pos|${l.gstRate}';
        final existing = b2csKeyed[key];
        final txv = _d(l.taxableValue);
        final ig = _d(l.igst);
        final cg = _d(l.cgst);
        final sg = _d(l.sgst);
        final cs = _d(l.cessAmount);
        b2csKeyed[key] = Gstr1B2cs(
          supplyType: inter ? 'INTER' : 'INTRA',
          pos: pos,
          rate: l.gstRate,
          taxableValue: (existing?.taxableValue ?? Decimal.zero) + txv,
          igst: (existing?.igst ?? Decimal.zero) + ig,
          cgst: (existing?.cgst ?? Decimal.zero) + cg,
          sgst: (existing?.sgst ?? Decimal.zero) + sg,
          cess: (existing?.cess ?? Decimal.zero) + cs,
        );
      }
    }
    final b2cs = b2csKeyed.values.toList()
      ..sort((a, b) => a.pos.compareTo(b.pos));

    // ---- CDNR (Table 9B): credit/debit notes to registered ---------------
    final cdnrByGstin = <String, List<Gstr1Note>>{};
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      final gstin = (cn.partyGstin ?? '').trim().toUpperCase();
      if (gstin.isEmpty) continue; // unregistered → CDNUR (built above)
      final items = await sales.itemsFor(cn.id);
      final itms = [
        for (var i = 0; i < items.length; i++)
          Gstr1Item(
            num: i + 1,
            rate: items[i].gstRate,
            taxableValue: _d(items[i].taxableValue),
            igst: _d(items[i].igst),
            cgst: _d(items[i].cgst),
            sgst: _d(items[i].sgst),
            cess: _d(items[i].cessAmount),
          ),
      ];
      cdnrByGstin.putIfAbsent(gstin, () => []).add(Gstr1Note(
            ntNum: cn.number,
            ntDt: _fmtDate(cn.invoiceDate),
            val: _d(cn.grandTotal),
            ntty: 'C',
            pos: cn.placeOfSupply ?? '',
            reverseCharge: cn.reverseCharge,
            itms: itms,
          ));
    }
    final cdnr = [
      for (final e in cdnrByGstin.entries)
        Gstr1Cdnr(ctin: e.key, notes: e.value),
    ];

    // ---- HSN summary (Table 12) ------------------------------------------
    // Credit notes are part of the HSN table: outward supplies net of the
    // notes (a note carries the HSN of the goods it reverses).
    final hsnKeyed = <String, _HsnAccum>{};
    void accumulateHsn(Iterable<SalesInvoiceItemEntity> items,
        {bool negative = false}) {
      final sign = negative ? -1.0 : 1.0;
      for (final l in items) {
        final code = (l.hsn ?? '').trim();
        if (code.isEmpty) continue;
        final acc = hsnKeyed.putIfAbsent(
            code,
            () => _HsnAccum(
                  hsn: code,
                  description: l.name,
                  unit: l.unit,
                ));
        acc.qty += sign * l.quantity;
        acc.taxable += sign * l.taxableValue;
        acc.total += sign * l.total;
        acc.igst += sign * l.igst;
        acc.cgst += sign * l.cgst;
        acc.sgst += sign * l.sgst;
        acc.cess += sign * l.cessAmount;
      }
    }

    for (final doc in activeDocs) {
      accumulateHsn(await sales.itemsFor(doc.id));
    }
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      accumulateHsn(await sales.itemsFor(cn.id), negative: true);
    }
    final hsn = [
      for (final a in hsnKeyed.values)
        Gstr1Hsn(
          hsn: a.hsn,
          description: a.description,
          uqc: _uqc(a.unit),
          quantity: _d(a.qty),
          totalValue: _d(a.total),
          taxableValue: _d(a.taxable),
          igst: _d(a.igst),
          cgst: _d(a.cgst),
          sgst: _d(a.sgst),
          cess: _d(a.cess),
        ),
    ]..sort((a, b) => a.hsn.compareTo(b.hsn));

    // ---- Document issue summary (Table 13) --------------------------------
    // All sales-side doc classes that carry a serial number, not just
    // invoices — the portal asks for every document series in the period.
    final docIssue = [
      ...await _docIssue(docType: 'invoice', docNum: 1, from: from, to: to),
      ...await _docIssue(docType: 'credit_note', docNum: 5, from: from, to: to),
    ];

    final report = Gstr1Report(
      firmGstin: (firm?.gstin ?? '').toUpperCase(),
      fp:
          '${from.month.toString().padLeft(2, '0')}${from.year.toString()}',
      b2b: b2b,
      b2cl: b2cl,
      b2cs: b2cs,
      cdnr: cdnr,
      cdnur: cdnur,
      hsn: hsn,
      docIssue: docIssue,
    );
    return Gstr1Report(
      firmGstin: report.firmGstin,
      fp: report.fp,
      b2b: report.b2b,
      b2cl: report.b2cl,
      b2cs: report.b2cs,
      cdnr: report.cdnr,
      cdnur: report.cdnur,
      hsn: report.hsn,
      docIssue: report.docIssue,
      hash: computeGstr1Hash(report.toJson()),
    );
  }

  Future<Gstr1Invoice> _invoice(SalesInvoiceEntity doc, String pos) async {
    final items = await db.salesRepositoryFor(firmId).itemsFor(doc.id);
    final byRate = <double, Gstr1Item>{};
    var num = 1;
    for (final l in items) {
      final existing = byRate[l.gstRate];
      if (existing != null) {
        byRate[l.gstRate] = Gstr1Item(
          num: existing.num,
          rate: l.gstRate,
          taxableValue: existing.taxableValue + _d(l.taxableValue),
          igst: existing.igst + _d(l.igst),
          cgst: existing.cgst + _d(l.cgst),
          sgst: existing.sgst + _d(l.sgst),
          cess: existing.cess + _d(l.cessAmount),
        );
        continue;
      }
      byRate[l.gstRate] = Gstr1Item(
        num: num++,
        rate: l.gstRate,
        taxableValue: _d(l.taxableValue),
        igst: _d(l.igst),
        cgst: _d(l.cgst),
        sgst: _d(l.sgst),
        cess: _d(l.cessAmount),
      );
    }
    return Gstr1Invoice(
      inum: doc.number,
      idt: _fmtDate(doc.invoiceDate),
      val: _d(doc.grandTotal),
      pos: pos,
      reverseCharge: doc.reverseCharge,
      invoiceType: 'R',
      itms: byRate.values.toList()..sort((a, b) => a.num.compareTo(b.num)),
    );
  }

  Future<List<Gstr1DocIssue>> _docIssue({
    required String docType,
    required int docNum,
    required DateTime from,
    required DateTime to,
  }) async {
    final docs = await db.salesRepositoryFor(firmId).list(
        docType: docType, from: from, to: to, limit: 1000000);
    if (docs.isEmpty) return const [];
    // Numeric-aware sort: INV-9 vs INV-10 must order numerically once the
    // common prefix is stripped, not lexicographically.
    String key(String n) => n.replaceAll(RegExp(r'[^0-9]'), '');
    final numbers = docs.map((d) => d.number).toList()
      ..sort((a, b) {
        final ka = key(a), kb = key(b);
        final na = int.tryParse(ka), nb = int.tryParse(kb);
        if (na != null && nb != null) return na.compareTo(nb);
        return a.compareTo(b);
      });
    final cancelled = docs.where((d) => d.status == 'cancelled').length;
    return [
      Gstr1DocIssue(
        docNum: docNum,
        from: numbers.first,
        to: numbers.last,
        total: docs.length,
        cancelled: cancelled,
      ),
    ];
  }

  /// Maps an internal unit id to a GST UQC code (Table 12's `uqc`).
  String _uqc(String unit) => switch (unit) {
        'pcs' => 'NOS',
        'kg' => 'KGS',
        'g' => 'GMS',
        'l' || 'ltr' => 'LTR',
        'm' || 'mtr' => 'MTR',
        'ton' => 'TON',
        'sqm' => 'SQM',
        'cbm' => 'CBM',
        'box' => 'BOX',
        'bdl' => 'BDL',
        _ => 'OTH',
      };
}

class _HsnAccum {
  _HsnAccum({
    required this.hsn,
    required this.description,
    required this.unit,
  });

  final String hsn;
  final String description;
  final String unit;
  double qty = 0;
  double total = 0;
  double taxable = 0;
  double igst = 0;
  double cgst = 0;
  double sgst = 0;
  double cess = 0;
}

/// Computed GSTR-3B for one filing period (Tables 3.1, 3.2, 4, 5).
class Gstr3bReport {
  const Gstr3bReport({
    required this.fp,
    required this.outwardTaxable,
    required this.outwardIgst,
    required this.outwardCgst,
    required this.outwardSgst,
    required this.outwardCess,
    required this.zeroRated,
    required this.nilRated,
    required this.reverseChargeTax,
    required this.interStateByPos,
    required this.itcImport,
    required this.itcReverseCharge,
    required this.itcInwardIsd,
    required this.itcAllOther,
    required this.itcReversedRule4243,
    required this.itcReversedOther,
    required this.inwardNilRated,
    required this.inwardNonGst,
  });

  final String fp;

  // Table 3.1(a)
  final Decimal outwardTaxable;
  final Decimal outwardIgst;
  final Decimal outwardCgst;
  final Decimal outwardSgst;
  final Decimal outwardCess;

  /// Table 3.1(b): zero-rated (exports/SEZ) supply value.
  final Decimal zeroRated;

  /// Table 3.1(c): nil-rated / exempt.
  final Decimal nilRated;

  /// Table 3.1(d): inward supplies liable to reverse charge (tax amount).
  final Decimal reverseChargeTax;

  /// Table 3.2: unregistered inter-state supplies, place-of-supply-wise
  /// (details of the 3.1(a) outward value).
  final List<Gstr3bInterState> interStateByPos;

  // Table 4(A)
  final Decimal itcImport; // (A1) import of goods
  final Decimal itcReverseCharge; // (A3)
  final Decimal itcInwardIsd; // (A4)
  final Decimal itcAllOther; // (A5)

  // Table 4(B)
  final Decimal itcReversedRule4243;
  final Decimal itcReversedOther;

  Decimal get itcAvailable =>
      itcImport + itcReverseCharge + itcInwardIsd + itcAllOther;
  Decimal get itcReversed => itcReversedRule4243 + itcReversedOther;
  Decimal get netItc => itcAvailable - itcReversed;

  // Table 5
  final Decimal inwardNilRated;
  final Decimal inwardNonGst;

  /// Net tax payable = 3.1 output tax − net ITC (floored at 0; credit carry
  /// is the user's decision, not ours).
  Decimal get netPayable {
    final output = outwardIgst + outwardCgst + outwardSgst + outwardCess;
    final net = output - netItc;
    return net < Decimal.zero ? Decimal.zero : net;
  }

  Map<String, Object?> toJson() => {
        'fp': fp,
        '3.1': {
          'a_outward_taxable': {
            'txval': _n(outwardTaxable),
            'igst': _n(outwardIgst),
            'cgst': _n(outwardCgst),
            'sgst': _n(outwardSgst),
            'cess': _n(outwardCess),
          },
          'b_zero_rated': _n(zeroRated),
          'c_nil_exempt': _n(nilRated),
          'd_reverse_charge_tax': _n(reverseChargeTax),
        },
        '3.2': [
          for (final s in interStateByPos)
            {
              'pos': s.pos,
              'txval': _n(s.taxableValue),
              'igst': _n(s.igst),
            },
        ],
        '4': {
          'a_available': {
            'import_goods': _n(itcImport),
            'reverse_charge': _n(itcReverseCharge),
            'inward_isd': _n(itcInwardIsd),
            'all_other': _n(itcAllOther),
          },
          'b_reversed': {
            'rule_42_43': _n(itcReversedRule4243),
            'others': _n(itcReversedOther),
          },
          'c_net': _n(netItc),
        },
        '5': {
          'nil_exempt_composition': _n(inwardNilRated),
          'non_gst': _n(inwardNonGst),
        },
      };

  static Object _n(Decimal d) =>
      double.tryParse(d.toStringAsFixed(2)) ?? 0;
}

class Gstr3bInterState {
  const Gstr3bInterState({
    required this.pos,
    required this.taxableValue,
    required this.igst,
  });

  final String pos;
  final Decimal taxableValue;
  final Decimal igst;
}

/// GSTR-3B computation. Reads the same books as [GstReturnBuilder.buildGstr1]
/// but aggregates into the 3B tables.
Future<Gstr3bReport> buildGstr3b(
  AppDatabase db,
  String firmId, {
  required DateTime from,
  required DateTime to,
}) async {
  final sales = db.salesRepositoryFor(firmId);
  final purchases = db.purchaseRepositoryFor(firmId);
  final docs = await sales
      .list(docType: 'invoice', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());
  final creditNotes = await sales
      .list(docType: 'credit_note', from: from, to: to, limit: 1000000)
      .then((d) =>
          d.where((d) => d.status != 'cancelled').toList());
  final bills = await purchases
      .list(docType: 'bill', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());
  final debitNotes = await purchases
      .list(docType: 'debit_note', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());

  double taxable = 0, oigst = 0, ocgst = 0, osgst = 0, ocess = 0;
  double zeroRated = 0;
  double nilRated = 0;
  final interByPos = <String, Gstr3bInterState>{};

  void addOutward(SalesInvoiceEntity doc, {double sign = 1.0}) {
    if (doc.isExport) {
      // Zero-rated supplies report TAXABLE value, not the gross total.
      zeroRated += sign * doc.taxableValue;
      return;
    }
    taxable += sign * doc.taxableValue;
    oigst += sign * doc.igst;
    ocgst += sign * doc.cgst;
    osgst += sign * doc.sgst;
    ocess += sign * doc.cess;
    if (doc.isInterState && (doc.partyGstin ?? '').isEmpty) {
      final pos = doc.placeOfSupply ?? '';
      final existing = interByPos[pos];
      interByPos[pos] = Gstr3bInterState(
        pos: pos,
        taxableValue: (existing?.taxableValue ?? Decimal.zero) +
            _d(sign * doc.taxableValue),
        igst:
            (existing?.igst ?? Decimal.zero) + _d(sign * doc.igst),
      );
    }
  }

  for (final doc in docs) {
    addOutward(doc);
  }
  // Credit notes reduce outward supplies in the period they were issued.
  for (final cn in creditNotes) {
    addOutward(cn, sign: -1.0);
  }

  // Table 4: ITC. Purchases from GSTIN-registered suppliers are "all other
  // ITC"; reverse-charge inward uses the document's own reverseCharge flag;
  // imports would need a flag the books do not carry yet and stay zero.
  double itcAll = 0;
  double itcRc = 0;
  double inwardNil = 0;
  double inwardNonGst = 0;
  void addInward(PurchaseBillEntity b, {double sign = 1.0}) {
    final gstin = (b.partyGstin ?? '').trim();
    if (gstin.isEmpty) {
      if (b.isInwardSupplyFromUnregistered) {
        // Table 3.1(d) reverse-charge inward from an unregistered supplier:
        // the tax is payable by the recipient, not creditable here.
        itcRc += sign * (b.cgst + b.sgst + b.igst + b.cess);
      } else {
        // Purchases from unregistered suppliers under the regular scheme
        // are NOT nil-rated: they are either non-GST or composition inward.
        // Composition inward is nil-rated/exempt for the recipient.
        inwardNil += sign * b.taxableValue;
      }
      return;
    }
    if (b.reverseCharge) {
      itcRc += sign * (b.cgst + b.sgst + b.igst + b.cess);
      return;
    }
    itcAll += sign * (b.cgst + b.sgst + b.igst + b.cess);
  }

  for (final b in bills) {
    addInward(b);
  }
  for (final dn in debitNotes) {
    addInward(dn, sign: -1.0);
  }

  return Gstr3bReport(
    fp: '${from.month.toString().padLeft(2, '0')}${from.year.toString()}',
    outwardTaxable: _d(taxable),
    outwardIgst: _d(oigst),
    outwardCgst: _d(ocgst),
    outwardSgst: _d(osgst),
    outwardCess: _d(ocess),
    zeroRated: _d(zeroRated < 0 ? 0 : zeroRated),
    nilRated: _d(nilRated < 0 ? 0 : nilRated),
    reverseChargeTax: _d(itcRc),
    interStateByPos: interByPos.values.toList()
      ..sort((a, b) => a.pos.compareTo(b.pos)),
    itcImport: Decimal.zero,
    itcReverseCharge: _d(itcRc),
    itcInwardIsd: Decimal.zero,
    itcAllOther: _d(itcAll < 0 ? 0 : itcAll),
    itcReversedRule4243: Decimal.zero,
    itcReversedOther: Decimal.zero,
    inwardNilRated: _d(inwardNil < 0 ? 0 : inwardNil),
    inwardNonGst: _d(inwardNonGst),
  );
}

/// One supplier row from an imported GSTR-2A JSON (what the portal hands
/// back), and the reconciliation result against the purchase books.
class Gstr2aSupplier {
  const Gstr2aSupplier({
    required this.gstin,
    required this.tradeName,
    required this.invoices,
  });

  final String gstin;
  final String tradeName;
  final List<Gstr2aInvoice> invoices;

  static Gstr2aSupplier fromJson(Map<String, dynamic> json) {
    final invoices = <Gstr2aInvoice>[];
    for (final inv in (json['inv'] as List<dynamic>? ?? [])) {
      final m = inv as Map<String, dynamic>;
      double txval = 0, igst = 0, cgst = 0, sgst = 0, cess = 0;
      for (final itm in (m['itms'] as List<dynamic>? ?? [])) {
        final det =
            (itm as Map<String, dynamic>)['itm_det'] as Map<String, dynamic>;
        txval += _asDouble(det['txval']);
        igst += _asDouble(det['iamt']);
        cgst += _asDouble(det['camt']);
        sgst += _asDouble(det['samt']);
        cess += _asDouble(det['csamt']);
      }
      invoices.add(Gstr2aInvoice(
        number: (m['inum'] ?? '').toString(),
        date: (m['idt'] ?? '').toString(),
        value: _asDouble(m['val']),
        taxableValue: txval,
        igst: igst,
        cgst: cgst,
        sgst: sgst,
        cess: cess,
      ));
    }
    return Gstr2aSupplier(
      gstin: (json['ctin'] ?? '').toString(),
      tradeName: (json['trdnm'] ?? '').toString(),
      invoices: invoices,
    );
  }

  static double _asDouble(Object? v) =>
      v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
}

class Gstr2aInvoice {
  const Gstr2aInvoice({
    required this.number,
    required this.date,
    required this.value,
    required this.taxableValue,
    required this.igst,
    required this.cgst,
    required this.sgst,
    required this.cess,
  });

  final String number;
  final String date;
  final double value;
  final double taxableValue;
  final double igst;
  final double cgst;
  final double sgst;
  final double cess;
}

/// Row-level reconciliation: GSTR-2A (what the supplier filed) vs the books
/// (what you recorded). Matched on invoice number (normalized).
class Gstr2aMatchRow {
  const Gstr2aMatchRow({
    required this.invoiceNumber,
    required this.status,
    this.booksTaxable,
    this.booksTax,
    this.portalTaxable,
    this.portalTax,
  });

  final String invoiceNumber;

  /// matched | books_only | portal_only | value_mismatch
  final String status;
  final double? booksTaxable;
  final double? booksTax;
  final double? portalTaxable;
  final double? portalTax;
}

class Gstr2aReconciliation {
  const Gstr2aReconciliation({
    required this.rows,
    required this.portalTotalTax,
    required this.booksTotalTax,
    this.firmGstin = '',
  });

  final List<Gstr2aMatchRow> rows;
  final double portalTotalTax;
  final double booksTotalTax;

  /// The firm's GSTIN the reconciliation was run for (used to key the
  /// export folder).
  final String firmGstin;

  int get matched => rows.where((r) => r.status == 'matched').length;
  int get booksOnly => rows.where((r) => r.status == 'books_only').length;
  int get portalOnly => rows.where((r) => r.status == 'portal_only').length;
  int get mismatch =>
      rows.where((r) => r.status == 'value_mismatch').length;

  /// Parses a portal GSTR-2A JSON file (the `b2b` array of supplier blocks)
  /// and reconciles it against the purchase books for the period.
  static Future<Gstr2aReconciliation> fromPortalJson(
    Map<String, dynamic> json, {
    required AppDatabase db,
    required String firmId,
    required DateTime from,
    required DateTime to,
    String firmGstin = '',
  }) async {
    final suppliers = <Gstr2aSupplier>[];
    for (final s in (json['b2b'] as List<dynamic>? ?? [])) {
      suppliers.add(Gstr2aSupplier.fromJson(s as Map<String, dynamic>));
    }

    // Key both sides by (supplier GSTIN, normalized invoice number): two
    // suppliers can (and do) issue the same invoice number; matching on the
    // number alone cross-matched their invoices.
    final portal = <String, List<Gstr2aInvoice>>{};
    var portalTax = 0.0;
    for (final s in suppliers) {
      for (final i in s.invoices) {
        portal.putIfAbsent(_key(s.gstin, i.number), () => []).add(i);
        portalTax += i.igst + i.cgst + i.sgst + i.cess;
      }
    }

    // Books: purchases in the period from registered suppliers.
    final books = <String, List<PurchaseBillEntity>>{};
    var booksTax = 0.0;
    final purchaseRepo = db.purchaseRepositoryFor(firmId);
    final bills = await purchaseRepo
        .list(docType: 'bill', from: from, to: to, limit: 1000000);
    for (final b in bills) {
      if (b.status == 'cancelled' || b.isDeleted) continue;
      if ((b.partyGstin ?? '').trim().isEmpty) continue;
      books.putIfAbsent(
          _key((b.partyGstin ?? '').trim().toUpperCase(), b.number), () => [])
          .add(b);
      booksTax += b.cgst + b.sgst + b.igst + b.cess;
    }

    final rows = <Gstr2aMatchRow>[];
    final seen = <String>{};
    portal.forEach((key, portalInvoices) {
      seen.add(key);
      final bookBills = books[key] ?? const <PurchaseBillEntity>[];
      final count = portalInvoices.length > bookBills.length
          ? portalInvoices.length
          : bookBills.length;
      for (var i = 0; i < count; i++) {
        final p = i < portalInvoices.length ? portalInvoices[i] : null;
        final b = i < bookBills.length ? bookBills[i] : null;
        if (p == null) {
          rows.add(Gstr2aMatchRow(
            invoiceNumber: b!.number,
            status: 'books_only',
            booksTaxable: b.taxableValue,
            booksTax: b.cgst + b.sgst + b.igst + b.cess,
          ));
          continue;
        }
        if (b == null) {
          rows.add(Gstr2aMatchRow(
            invoiceNumber: p.number,
            status: 'portal_only',
            portalTaxable: p.taxableValue,
            portalTax: p.igst + p.cgst + p.sgst + p.cess,
          ));
          continue;
        }
        final bTax = b.cgst + b.sgst + b.igst + b.cess;
        final pTax = p.igst + p.cgst + p.sgst + p.cess;
        final ok = (b.taxableValue - p.taxableValue).abs() < 1 &&
            (bTax - pTax).abs() < 1;
        rows.add(Gstr2aMatchRow(
          invoiceNumber: p.number,
          status: ok ? 'matched' : 'value_mismatch',
          booksTaxable: b.taxableValue,
          booksTax: bTax,
          portalTaxable: p.taxableValue,
          portalTax: pTax,
        ));
      }
    });
    books.forEach((key, bookBills) {
      if (seen.contains(key)) return;
      for (final b in bookBills) {
        rows.add(Gstr2aMatchRow(
          invoiceNumber: b.number,
          status: 'books_only',
          booksTaxable: b.taxableValue,
          booksTax: b.cgst + b.sgst + b.igst + b.cess,
        ));
      }
    });
    rows.sort((a, b) => a.invoiceNumber.compareTo(b.invoiceNumber));
    return Gstr2aReconciliation(
      rows: rows,
      portalTotalTax: portalTax,
      booksTotalTax: booksTax,
      firmGstin: firmGstin,
    );
  }

  static String _key(String gstin, String number) =>
      '${gstin.trim().toUpperCase()}|${_normalize(number)}';

  static String _normalize(String number) =>
      number.trim().toUpperCase().replaceAll(RegExp(r'[\s\-/]'), '');
}
