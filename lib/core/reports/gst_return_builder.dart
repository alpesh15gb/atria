import '../domain/gst_registration.dart';

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
    final firm = await (db.select(
      db.firms,
    )..where((t) => t.id.equals(firmId))).getSingleOrNull();
    if (firm?.isGstRegistered != true) {
      throw StateError('GST returns require a GST-registered business.');
    }
    final sales = db.salesRepositoryFor(firmId);
    final docs = await sales.list(
      docType: 'invoice',
      from: from,
      to: to,
      limit: 1000000,
    );
    final creditNotes = await sales.list(
      docType: 'credit_note',
      from: from,
      to: to,
      limit: 1000000,
    );

    final activeDocs = docs
        .where((d) => d.status != 'cancelled')
        .toList(growable: false);

    // ---- B2B (registered customers, Table 4) -----------------------------
    final b2bByGstin = <String, List<SalesInvoiceEntity>>{};
    final b2clInvoices = <SalesInvoiceEntity>[];
    final b2csInvoices = <SalesInvoiceEntity>[];
    // Tables 13A / 13B: zero-rated exports, grouped by place of supply.
    final expwpByPos = <String, List<SalesInvoiceEntity>>{};
    final expwopByPos = <String, List<SalesInvoiceEntity>>{};

    for (final doc in activeDocs) {
      final gstin = (doc.partyGstin ?? '').trim().toUpperCase();
      // Zero-rated supplies (exports / SEZ with the supplied-to-SEZ flag) have
      // their OWN tables. They used to be dropped here, which left an exporter
      // filing a GSTR-1 that reported no outward supply at all while GSTR-3B
      // reported the very same invoices under 3.1(b).
      if (doc.isExport) {
        // Tables 13A / 13B are grouped by place of supply, and for an export
        // that place is always '96' — "Outside India". It is NOT the document's
        // own `placeOfSupply`: that column holds the domestic state (the
        // exporter's own state, or the state the counterparty sits in), and a
        // state code is not a legal POS in 13A/13B. The old code used '96' only
        // as a fallback for a blank POS, which meant every export that DID carry
        // a POS — in practice all of them — was filed under a state the goods
        // never went to.
        const exportPos = '96';
        // exportType: 'wp' = paid (EXPWP, 13A), 'wop' = unpaid (EXPWOP, 13B).
        // Untagged exports are filed with payment, the conservative reading.
        final bucket = (doc.exportType ?? '').trim().toLowerCase() == 'wop'
            ? expwopByPos
            : expwpByPos;
        bucket.putIfAbsent(exportPos, () => []).add(doc);
        continue;
      }
      final interState = doc.isInterState;
      // B2CL rule: inter-state supply to an unregistered buyer where the
      // TAXABLE value exceeds ₹2.5 lakh (the old check compared the GROSS
      // total incl. tax with >=, bucketing invoices the portal would deny).
      final threshold = doc.invoiceDate.isBefore(DateTime(2024, 8, 1))
          ? 250000
          : 100000;
      final large = doc.grandTotal > threshold && interState && gstin.isEmpty;
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
    // Full note rows (number, date, value, type) with line item tax rates.
    final cdnur = <Gstr1Cdnur>[];
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      final gstin = (cn.partyGstin ?? '').trim().toUpperCase();
      if (gstin.isNotEmpty) continue; // registered → CDNR
      // B2CL-large unregistered notes must be flagged; 'B2CL' requires the
      // same ₹2.5L taxable rule as the invoice bucket above, so only that
      // qualifies (same strict >, not >=, or the portal rejects the row).
      final threshold = cn.invoiceDate.isBefore(DateTime(2024, 8, 1))
          ? 250000
          : 100000;
      final isB2cl = cn.isInterState && cn.grandTotal > threshold;
      final items = await sales.itemsFor(cn.id);
      final itms = items.isEmpty
          ? [
              Gstr1Item(
                num: 1,
                rate: 0,
                taxableValue: _d(cn.taxableValue),
                igst: _d(cn.igst),
                cgst: _d(cn.cgst),
                sgst: _d(cn.sgst),
                cess: _d(cn.cess),
              ),
            ]
          : [
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
      cdnur.add(
        Gstr1Cdnur(
          ntNum: cn.number,
          ntDt: _fmtDate(cn.invoiceDate),
          val: _d(cn.grandTotal),
          ntty: 'C',
          pos: cn.placeOfSupply ?? '',
          supplyType: isB2cl ? 'B2CL' : 'B2CS',
          itms: itms,
        ),
      );
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

    // ---- EXPWP / EXPWOP (Tables 13A / 13B): zero-rated exports ------------
    final expwp = [
      for (final e in expwpByPos.entries)
        Gstr1Export(
          pos: e.key,
          invoices: [
            for (final doc in e.value)
              await _invoice(doc, e.key, invoiceType: 'SEWP'),
          ],
        ),
    ];
    final expwop = [
      for (final e in expwopByPos.entries)
        Gstr1Export(
          pos: e.key,
          invoices: [
            for (final doc in e.value)
              await _invoice(doc, e.key, invoiceType: 'SEWOP'),
          ],
        ),
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
      cdnrByGstin
          .putIfAbsent(gstin, () => [])
          .add(
            Gstr1Note(
              ntNum: cn.number,
              ntDt: _fmtDate(cn.invoiceDate),
              val: _d(cn.grandTotal),
              ntty: 'C',
              pos: cn.placeOfSupply ?? '',
              reverseCharge: cn.reverseCharge,
              itms: itms,
            ),
          );
    }
    final cdnr = [
      for (final e in cdnrByGstin.entries)
        Gstr1Cdnr(ctin: e.key, notes: e.value),
    ];

    // ---- HSN summary (Table 12) ------------------------------------------
    // Credit notes are part of the HSN table: outward supplies net of the
    // notes (a note carries the HSN of the goods it reverses).
    final hsnKeyed = <String, _HsnAccum>{};
    void accumulateHsn(
      Iterable<SalesInvoiceItemEntity> items, {
      bool negative = false,
      bool isB2b = true,
    }) {
      final sign = negative ? -1.0 : 1.0;
      for (final l in items) {
        final code = (l.hsn ?? '').trim();
        if (code.isEmpty) continue;
        // Keyed on (HSN, RATE): Table 12 is a rate-wise summary, so the same
        // HSN sold at 5% and at 18% is TWO rows. Keyed on the code alone they
        // collapsed into one row holding one arbitrary rate's tax — and with no
        // rate field on the model `rt` was never emitted at all, which the
        // offline utility rejects.
        final acc = hsnKeyed.putIfAbsent(
          '$code|${l.gstRate.toStringAsFixed(2)}|${_uqc(l.unit)}|$isB2b',
          () => _HsnAccum(
            hsn: code,
            rate: l.gstRate,
            description: l.name,
            unit: l.unit,
            isB2b: isB2b,
          ),
        );
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
      accumulateHsn(
        await sales.itemsFor(doc.id),
        isB2b: (doc.partyGstin ?? '').trim().isNotEmpty,
      );
    }
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      accumulateHsn(
        await sales.itemsFor(cn.id),
        negative: true,
        isB2b: (cn.partyGstin ?? '').trim().isNotEmpty,
      );
    }
    final hsn =
        [
          for (final a in hsnKeyed.values)
            Gstr1Hsn(
              isB2b: a.isB2b,
              hsn: a.hsn,
              rate: a.rate,
              description: a.description,
              uqc: _uqc(a.unit),
              // Quantity is a POSITIVE total, never a negative: Table 12 has no
              // sign column for it and the portal rejects a negative `qty`. The
              // credit note's effect therefore lives in the value columns (val /
              // txval / iamt / camt / samt / csamt), which all stay net of the
              // note — the summary is still honest about the return while the
              // quantity stays fileable. A month whose returns exceed its sales of
              // that HSN floors at zero rather than claiming stock that was never
              // invoiced out.
              quantity: _d(a.qty < 0 ? 0 : a.qty),
              totalValue: _d(a.total),
              taxableValue: _d(a.taxable),
              igst: _d(a.igst),
              cgst: _d(a.cgst),
              sgst: _d(a.sgst),
              cess: _d(a.cess),
            ),
        ]..sort((a, b) {
          final byCode = a.hsn.compareTo(b.hsn);
          return byCode != 0 ? byCode : a.rate.compareTo(b.rate);
        });

    // ---- Document issue summary (Table 13) --------------------------------
    // All sales-side doc classes that carry a serial number, not just
    // invoices — the portal asks for every document series in the period.
    // Sales debit notes are a numbered series too (doc_num 4) and were never
    // declared, so the series the user had used stayed invisible.
    final docIssue = [
      ...await _docIssue(docType: 'invoice', docNum: 1, from: from, to: to),
      ...await _docIssue(docType: 'debit_note', docNum: 4, from: from, to: to),
      ...await _docIssue(docType: 'credit_note', docNum: 5, from: from, to: to),
    ];

    final bookRows = <Map<String, Object?>>[];
    final bookDocs = [
      ...activeDocs,
      ...creditNotes.where((d) => d.status != 'cancelled'),
    ];
    final bookItems = await sales.itemsForMany(
      bookDocs.map((d) => d.id).toList(),
    );
    for (final d in bookDocs) {
      final items = bookItems[d.id] ?? <SalesInvoiceItemEntity>[];
      final rates = items.map((i) => i.gstRate).toSet();
      final sign = d.docType == 'credit_note' ? -1.0 : 1.0;
      bookRows.add({
        'gstin': d.partyGstin ?? '',
        'party': d.partyName ?? '',
        'type': d.docType == 'credit_note' ? 'Sale Return' : 'Sale',
        'number': d.number,
        'date': d.invoiceDate,
        'invoiceValue': sign * d.grandTotal,
        'rate': rates.length == 1 ? rates.first : (rates.isEmpty ? 0 : 'Mixed'),
        'cessRate': items.map((i) => i.cessRate).toSet().length == 1
            ? items.first.cessRate
            : 0,
        'taxable': sign * d.taxableValue,
        'igst': sign * d.igst,
        'cgst': sign * d.cgst,
        'sgst': sign * d.sgst,
        'cess': sign * d.cess,
        'pos': d.placeOfSupply ?? '',
        '_id': d.id,
        '_rcm': d.reverseCharge,
        '_interState': d.isInterState,
        '_items': [
          for (final i in items)
            {
              'hsn': i.hsn ?? '',
              'name': i.name,
              'unit': i.unit,
              'rate': i.gstRate,
              'quantity': sign * i.quantity,
              'total': sign * i.total,
              'taxable': sign * i.taxableValue,
              'igst': sign * i.igst,
              'cgst': sign * i.cgst,
              'sgst': sign * i.sgst,
              'cess': sign * i.cessAmount,
            },
        ],
      });
    }
    bookRows.sort(
      (a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime),
    );
    final report = Gstr1Report(
      from: from,
      to: to,
      firmName: firm?.name ?? '',
      bookRows: bookRows,
      firmGstin: (firm?.gstin ?? '').toUpperCase(),
      fp: '${to.month.toString().padLeft(2, '0')}${to.year.toString()}',
      b2b: b2b,
      b2cl: b2cl,
      b2cs: b2cs,
      expwp: expwp,
      expwop: expwop,
      cdnr: cdnr,
      cdnur: cdnur,
      hsn: hsn,
      docIssue: docIssue,
    );
    return Gstr1Report(
      from: report.from,
      to: report.to,
      firmName: report.firmName,
      bookRows: report.bookRows,
      firmGstin: report.firmGstin,
      fp: report.fp,
      b2b: report.b2b,
      b2cl: report.b2cl,
      b2cs: report.b2cs,
      expwp: report.expwp,
      expwop: report.expwop,
      cdnr: report.cdnr,
      cdnur: report.cdnur,
      hsn: report.hsn,
      docIssue: report.docIssue,
      hash: computeGstr1Hash(report.toJson()),
    );
  }

  Future<Gstr1Invoice> _invoice(
    SalesInvoiceEntity doc,
    String pos, {
    String invoiceType = 'R',
  }) async {
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
      invoiceType: invoiceType,
      itms: byRate.values.toList()..sort((a, b) => a.num.compareTo(b.num)),
    );
  }

  Future<List<Gstr1DocIssue>> _docIssue({
    required String docType,
    required int docNum,
    required DateTime from,
    required DateTime to,
  }) async {
    final docs = await db
        .salesRepositoryFor(firmId)
        .list(docType: docType, from: from, to: to, limit: 1000000);
    if (docs.isEmpty) return const [];
    // Numeric-aware sort: INV-9 vs INV-10 must order numerically once the
    // common prefix is stripped, not lexicographically.
    String key(String n) => n.replaceAll(RegExp(r'[^0-9]'), '');
    final series = <String, List<SalesInvoiceEntity>>{};
    for (final doc in docs) {
      final prefix =
          RegExp(r'^(.*?)(\d+)$').firstMatch(doc.number)?.group(1) ??
          doc.number;
      series.putIfAbsent(prefix, () => []).add(doc);
    }
    final result = <Gstr1DocIssue>[];
    for (final group in series.values) {
      final numbers = group.map((d) => d.number).toList()
        ..sort((a, b) {
          final ka = key(a), kb = key(b);
          final na = int.tryParse(ka), nb = int.tryParse(kb);
          if (na != null && nb != null) return na.compareTo(nb);
          return a.compareTo(b);
        });
      final cancelled = group.where((d) => d.status == 'cancelled').length;
      result.add(
        Gstr1DocIssue(
          docNum: docNum,
          from: numbers.first,
          to: numbers.last,
          total: group.length,
          cancelled: cancelled,
        ),
      );
    }
    return result;
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
    required this.rate,
    required this.description,
    required this.unit,
    required this.isB2b,
  });

  final String hsn;

  /// GST rate this (HSN, rate) bucket reports as Table 12's `rt`.
  final double rate;
  final String description;
  final String unit;
  final bool isB2b;
  double qty = 0;
  double total = 0;
  double taxable = 0;
  double igst = 0;
  double cgst = 0;
  double sgst = 0;
  double cess = 0;
}

class GstTaxHeads {
  const GstTaxHeads({
    this.igst = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.cess = 0,
  });
  final double igst, cgst, sgst, cess;
  double get total => igst + cgst + sgst + cess;
  GstTaxHeads operator +(GstTaxHeads b) => GstTaxHeads(
    igst: igst + b.igst,
    cgst: cgst + b.cgst,
    sgst: sgst + b.sgst,
    cess: cess + b.cess,
  );
  GstTaxHeads operator -(GstTaxHeads b) => GstTaxHeads(
    igst: igst - b.igst,
    cgst: cgst - b.cgst,
    sgst: sgst - b.sgst,
    cess: cess - b.cess,
  );
  Map<String, Object> toJson() => {
    'iamt': double.parse(igst.toStringAsFixed(2)),
    'camt': double.parse(cgst.toStringAsFixed(2)),
    'samt': double.parse(sgst.toStringAsFixed(2)),
    'csamt': double.parse(cess.toStringAsFixed(2)),
  };
}

/// Computed GSTR-3B for one filing period (Tables 3.1, 3.2, 4, 5).
class Gstr3bReport {
  const Gstr3bReport({
    this.from,
    this.to,
    this.otherItcHeads = const GstTaxHeads(),
    this.reverseChargeHeads = const GstTaxHeads(),
    this.reverseChargeItcHeads,
    this.zeroRatedHeads = const GstTaxHeads(),
    this.reverseChargeValue = 0,
    this.unallocatedExpenseItc = 0,
    this.inwardNilInter = 0,
    this.inwardNilIntra = 0,
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
  final DateTime? from, to;
  final GstTaxHeads otherItcHeads, reverseChargeHeads, zeroRatedHeads;
  final GstTaxHeads? reverseChargeItcHeads;
  GstTaxHeads get eligibleRcHeads =>
      reverseChargeItcHeads ?? reverseChargeHeads;
  final double inwardNilInter, inwardNilIntra;
  final double reverseChargeValue, unallocatedExpenseItc;

  /// GST save-data structure; a preparation draft until portal checks pass.
  Map<String, Object?> toPortalJson(String gstin) => {
    'gstin': gstin,
    'ret_period': fp,
    'sup_details': {
      'osup_det': {
        'txval': _n(outwardTaxable),
        'iamt': _n(outwardIgst),
        'camt': _n(outwardCgst),
        'samt': _n(outwardSgst),
        'csamt': _n(outwardCess),
      },
      'osup_zero': {'txval': _n(zeroRated), ...zeroRatedHeads.toJson()},
      'osup_nil_exmp': {'txval': _n(nilRated)},
      'isup_rev': {'txval': reverseChargeValue, ...reverseChargeHeads.toJson()},
      'osup_nongst': {'txval': 0},
    },
    'inter_sup': {
      'unreg_details': [
        for (final s in interStateByPos)
          {'pos': s.pos, 'txval': _n(s.taxableValue), 'iamt': _n(s.igst)},
      ],
      'comp_details': [],
      'uin_details': [],
    },
    'itc_elg': {
      'itc_avl': [
        for (final type in ['IMPG', 'IMPS', 'ISRC', 'ISD', 'OTH'])
          {
            'ty': type,
            ...(type == 'OTH'
                    ? otherItcHeads
                    : type == 'ISRC'
                    ? eligibleRcHeads
                    : const GstTaxHeads())
                .toJson(),
          },
      ],
      'itc_net': (otherItcHeads + eligibleRcHeads).toJson(),
      'itc_rev': [
        for (final type in ['RUL', 'OTH'])
          {'ty': type, ...const GstTaxHeads().toJson()},
      ],
    },
    'inward_sup': {
      'isup_details': [
        {'ty': 'GST', 'inter': inwardNilInter, 'intra': inwardNilIntra},
        {'ty': 'NONGST', 'inter': 0, 'intra': _n(inwardNonGst)},
      ],
    },
  };

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

  /// Table 5(A)(2): inward supplies that are NOT liable to GST at all.
  ///
  /// Always zero from the books: an inward bill carries either a supplier
  /// GSTIN (credit, 4(A)(5)), no GSTIN (nil-rated, 5(A)(1)) or the reverse
  /// charge (3.1(d)/4(A)(3)) — there is no column anywhere in the schema that
  /// marks a bill as a non-GST inward supply, so nothing can populate this.
  /// It is therefore OMITTED from the emitted Table 5 rather than filed as a
  /// hard zero: a false 0 asserts "this firm had no non-GST inward supplies",
  /// which the books cannot know. The moment a capture path exists, a non-zero
  /// value starts appearing in the JSON.
  final Decimal inwardNonGst;

  /// Net tax payable = outward tax payable after eligible ITC (floored at 0)
  /// plus reverse charge liability which under Section 49(4) of the CGST Act
  /// must be discharged in cash through the electronic cash ledger.
  Decimal get netPayable {
    final outwardTax = outwardIgst + outwardCgst + outwardSgst + outwardCess;
    final itcForOutward = netItc - itcReverseCharge;
    final netOutward = outwardTax - itcForOutward;
    final regularPayable = netOutward < Decimal.zero
        ? Decimal.zero
        : netOutward;
    return regularPayable + reverseChargeTax;
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
        {'pos': s.pos, 'txval': _n(s.taxableValue), 'igst': _n(s.igst)},
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
      // See [inwardNonGst]: nothing in the books can populate this, so it
      // is left out rather than filed as an invented zero.
      if (inwardNonGst != Decimal.zero) 'non_gst': _n(inwardNonGst),
    },
  };

  static Object _n(Decimal d) => double.tryParse(d.toStringAsFixed(2)) ?? 0;
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
  final firm = await db.firmRepository.getById(firmId);
  if (firm?.isGstRegistered != true) {
    throw StateError('GST returns require a GST-registered business.');
  }
  final sales = db.salesRepositoryFor(firmId);
  final purchases = db.purchaseRepositoryFor(firmId);
  final docs = await sales
      .list(docType: 'invoice', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());
  final creditNotes = await sales
      .list(docType: 'credit_note', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());
  final bills = await purchases
      .list(docType: 'bill', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());
  final debitNotes = await purchases
      .list(docType: 'debit_note', from: from, to: to, limit: 1000000)
      .then((d) => d.where((d) => d.status != 'cancelled').toList());

  double taxable = 0, oigst = 0, ocgst = 0, osgst = 0, ocess = 0;
  double zeroRated = 0;
  var zeroRatedHeads = const GstTaxHeads();
  double nilRated = 0;
  final interByPos = <String, Gstr3bInterState>{};

  // Table 3.1(a) vs 3.1(c) is a RATE split, so it can only be made from the
  // line rows: `sales_invoice_items.gst_rate` is the only record of which part
  // of a document is exempt. One batched read for the period (the per-document
  // `itemsFor` inside a loop was an N+1 on a firm with a thousand invoices).
  // Exports are excluded — they are 3.1(b) zero-rated and have no rate split.
  final outwardLines = await sales.itemsForMany([
    for (final d in [...docs, ...creditNotes])
      if (!d.isExport) d.id,
  ]);

  void addOutward(SalesInvoiceEntity doc, {double sign = 1.0}) {
    if (doc.isExport) {
      // Zero-rated supplies report TAXABLE value, not the gross total.
      zeroRated += sign * doc.taxableValue;
      zeroRatedHeads += GstTaxHeads(
        igst: sign * doc.igst,
        cgst: sign * doc.cgst,
        sgst: sign * doc.sgst,
        cess: sign * doc.cess,
      );
      return;
    }
    // Split the document's taxable value by LINE rate. The stored per-line
    // `taxableValue` is what the editor apportioned (line discount + the
    // invoice-level discount by largest remainder), so summing the lines
    // reproduces `doc.taxableValue` exactly — which is the whole point: 3.1(a)
    // + 3.1(c) keeps adding up to the document total, so the return still
    // reconciles with Table 4.1.
    var taxablePart = 0.0;
    var nilPart = 0.0;
    final lines = outwardLines[doc.id] ?? const <SalesInvoiceItemEntity>[];
    for (final l in lines) {
      if (l.gstRate == 0) {
        nilPart += l.taxableValue;
      } else {
        taxablePart += l.taxableValue;
      }
    }
    if (lines.isEmpty) {
      // No line rows (an imported or legacy document): fall back to the
      // document totals, which can only classify the WHOLE document — the
      // behaviour that existed before the line-level split.
      taxablePart = doc.taxableValue;
      nilPart = 0;
    }
    if (doc.cgst == 0 && doc.sgst == 0 && doc.igst == 0 && doc.cess == 0) {
      // No tax anywhere on the document. At 0% GST a line carries no tax, so
      // the whole document is nil-rated/exempt: Table 3.1(c). Read off the
      // document total (not the line split) so the invariant above holds even
      // if the stored lines do not add up.
      nilRated += sign * doc.taxableValue;
      return;
    }
    // A nil-rated line carries no tax, so the document's own tax totals are
    // already exactly the tax on the 3.1(a) portion — only the VALUE has to be
    // split by rate.
    taxable += sign * taxablePart;
    nilRated += sign * nilPart;
    oigst += sign * doc.igst;
    ocgst += sign * doc.cgst;
    osgst += sign * doc.sgst;
    ocess += sign * doc.cess;
    if (doc.isInterState && (doc.partyGstin ?? '').isEmpty) {
      final pos = doc.placeOfSupply ?? '';
      final existing = interByPos[pos];
      interByPos[pos] = Gstr3bInterState(
        pos: pos,
        // Table 3.2 details the 3.1(a) outward value, so the exempt portion
        // stays out of it — reporting the document total here would not add up
        // against 3.1(a).
        taxableValue:
            (existing?.taxableValue ?? Decimal.zero) + _d(sign * taxablePart),
        igst: (existing?.igst ?? Decimal.zero) + _d(sign * doc.igst),
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
  var otherHeads = const GstTaxHeads();
  var rcHeads = const GstTaxHeads();
  var rcItcHeads = const GstTaxHeads();
  double inwardNilInter = 0, inwardNilIntra = 0;
  double rcValue = 0;
  void addInward(PurchaseBillEntity b, {double sign = 1.0}) {
    if (b.reverseCharge || b.isInwardSupplyFromUnregistered) {
      // Table 3.1(d) & Table 4(A3) reverse-charge inward:
      // tax liability is payable by recipient in cash under Section 49(4).
      if (b.itcEligible) {
        itcRc += sign * (b.cgst + b.sgst + b.igst + b.cess);
        rcItcHeads += GstTaxHeads(
          igst: sign * b.igst,
          cgst: sign * b.cgst,
          sgst: sign * b.sgst,
          cess: sign * b.cess,
        );
      }
      rcValue += sign * b.taxableValue;
      rcHeads += GstTaxHeads(
        igst: sign * b.igst,
        cgst: sign * b.cgst,
        sgst: sign * b.sgst,
        cess: sign * b.cess,
      );
      return;
    }
    final gstin = (b.partyGstin ?? '').trim();
    if (gstin.isEmpty || b.igst + b.cgst + b.sgst + b.cess == 0) {
      // Regular purchases from unregistered suppliers (Table 5 nil-rated/exempt)
      inwardNil += sign * b.taxableValue;
      if (b.isInterState) {
        inwardNilInter += sign * b.taxableValue;
      } else {
        inwardNilIntra += sign * b.taxableValue;
      }
      return;
    }
    if (!b.itcEligible) return;
    itcAll += sign * (b.cgst + b.sgst + b.igst + b.cess);
    otherHeads += GstTaxHeads(
      igst: sign * b.igst,
      cgst: sign * b.cgst,
      sgst: sign * b.sgst,
      cess: sign * b.cess,
    );
  }

  for (final b in bills) {
    addInward(b);
  }
  for (final dn in debitNotes) {
    addInward(dn, sign: -1.0);
  }

  // The GST inside the firm's own expenses (rent, software, professional fees)
  // is credit like any other inward supply and belongs in 4(A)(5). It used to
  // be missing entirely: the return only ever read purchase bills, so the tax
  // on an expense quietly became payable. An expense carries one GST figure
  // and no place of supply, so the amount cannot be split across heads — which
  // is also why it is added to the "all other ITC" total rather than to a
  // per-head column.
  final expenseGst = await db
      .expenseRepositoryFor(firmId)
      .list(type: 'expense', from: from, to: to, limit: 1000000)
      .then(
        (rows) => rows.fold<double>(
          0,
          (sum, e) =>
              sum +
              (e.itcEligible ? e.gstAmount.clamp(0, e.amount).toDouble() : 0),
        ),
      );
  itcAll += expenseGst;

  // Supplier notes are netted in 4(A)(5), including a negative period total.
  // They do not establish a Rule 42/43 reversal; that requires separate review.

  return Gstr3bReport(
    from: from,
    to: to,
    otherItcHeads: otherHeads,
    reverseChargeHeads: rcHeads,
    reverseChargeItcHeads: rcItcHeads,
    zeroRatedHeads: zeroRatedHeads,
    reverseChargeValue: rcValue,
    unallocatedExpenseItc: expenseGst,
    inwardNilInter: inwardNilInter,
    inwardNilIntra: inwardNilIntra,
    fp: '${to.month.toString().padLeft(2, '0')}${to.year.toString()}',
    outwardTaxable: _d(taxable),
    outwardIgst: _d(oigst),
    outwardCgst: _d(ocgst),
    outwardSgst: _d(osgst),
    outwardCess: _d(ocess),
    zeroRated: _d(zeroRated < 0 ? 0 : zeroRated),
    nilRated: _d(nilRated < 0 ? 0 : nilRated),
    reverseChargeTax: _d(rcHeads.total),
    interStateByPos: interByPos.values.toList()
      ..sort((a, b) => a.pos.compareTo(b.pos)),
    itcImport: Decimal.zero,
    itcReverseCharge: _d(itcRc),
    itcInwardIsd: Decimal.zero,
    // Supplier notes net in 4(A)(5); they are not evidence of a Rule 42/43 reversal.
    itcAllOther: _d(itcAll),
    itcReversedRule4243: Decimal.zero,
    itcReversedOther: Decimal.zero,
    // Table 5 is a disclosure of supply VALUE, not a liability, and the portal
    // has no reversal row for it — so a debit note that exceeds nil-rated bills
    // in the period leaves this at zero. Nothing is lost: nil-rated inward
    // supplies generate no ITC, so the excess is not a credit reversal and has
    // no home in Table 4(B) either. It is only the value figure that floors.
    inwardNilRated: _d(inwardNil < 0 ? 0 : inwardNil),
    // Never populated from the books — see [Gstr3bReport.inwardNonGst]. The
    // declaration is kept out of the file rather than filed as a false zero.
    inwardNonGst: Decimal.zero,
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
      invoices.add(
        Gstr2aInvoice(
          number: (m['inum'] ?? '').toString(),
          date: (m['idt'] ?? '').toString(),
          value: _asDouble(m['val']),
          taxableValue: txval,
          igst: igst,
          cgst: cgst,
          sgst: sgst,
          cess: cess,
        ),
      );
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
    this.supplierGstin = '',
    this.invoiceDate = '',
    required this.invoiceNumber,
    required this.status,
    this.booksTaxable,
    this.booksTax,
    this.portalTaxable,
    this.portalTax,
  });

  final String invoiceNumber;
  final String supplierGstin, invoiceDate;

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
  int get mismatch => rows.where((r) => r.status == 'value_mismatch').length;

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
    final recipient = (json['gstin'] ?? '').toString().trim().toUpperCase();
    if (recipient.isNotEmpty &&
        firmGstin.isNotEmpty &&
        recipient != firmGstin.toUpperCase()) {
      throw const FormatException('This GSTR-2A belongs to another GSTIN.');
    }
    final period = (json['fp'] ?? json['ret_period'] ?? '').toString();
    final expectedPeriod =
        '${from.month.toString().padLeft(2, '0')}${from.year}';
    if (period.isNotEmpty && period != expectedPeriod) {
      throw const FormatException(
        'This GSTR-2A belongs to another return period.',
      );
    }
    final portal = <String, List<Gstr2aInvoice>>{};
    final books = <String, List<Gstr2aInvoice>>{};
    void add(
      Map<String, List<Gstr2aInvoice>> target,
      String gstin,
      Gstr2aInvoice invoice, {
      bool note = false,
    }) {
      final key = '${_key(gstin, invoice.number)}|${note ? 'note' : 'invoice'}';
      target.putIfAbsent(key, () => []).add(invoice);
    }

    for (final block in (json['b2b'] as List? ?? const [])) {
      final supplier = Gstr2aSupplier.fromJson(
        Map<String, dynamic>.from(block as Map),
      );
      for (final invoice in supplier.invoices) {
        add(portal, supplier.gstin, invoice);
      }
    }
    // Portal supplier credit/debit notes are separate documents, not adjustments
    // silently applied to the invoice bearing a similar number.
    for (final block in (json['cdn'] ?? json['cdnr'] ?? const []) as List) {
      final supplierGstin = '${block['ctin'] ?? ''}';
      for (final note in (block['nt'] as List? ?? const [])) {
        final sign = note['ntty'] == 'C' ? -1.0 : 1.0;
        final parsed = Gstr2aSupplier.fromJson({
          'ctin': supplierGstin,
          'inv': [
            {
              ...Map<String, dynamic>.from(note as Map),
              'inum': note['nt_num'],
              'idt': note['nt_dt'],
            },
          ],
        }).invoices.single;
        add(
          portal,
          supplierGstin,
          Gstr2aInvoice(
            number: parsed.number,
            date: parsed.date,
            value: sign * parsed.value,
            taxableValue: sign * parsed.taxableValue,
            igst: sign * parsed.igst,
            cgst: sign * parsed.cgst,
            sgst: sign * parsed.sgst,
            cess: sign * parsed.cess,
          ),
          note: true,
        );
      }
    }
    final repo = db.purchaseRepositoryFor(firmId);
    for (final type in ['bill', 'debit_note']) {
      for (final b in await repo.list(
        docType: type,
        from: from,
        to: to,
        limit: 1000000,
      )) {
        if (b.status == 'cancelled' ||
            b.isDeleted ||
            (b.partyGstin ?? '').trim().isEmpty) {
          continue;
        }
        final sign = type == 'debit_note' ? -1.0 : 1.0;
        final reference = (b.supplierInvoiceNumber ?? '').trim();
        add(
          books,
          b.partyGstin!,
          Gstr2aInvoice(
            number: reference.isEmpty ? b.number : reference,
            date: _fmtDate(b.billDate),
            value: sign * b.grandTotal,
            taxableValue: sign * b.taxableValue,
            igst: sign * b.igst,
            cgst: sign * b.cgst,
            sgst: sign * b.sgst,
            cess: sign * b.cess,
          ),
          note: type == 'debit_note',
        );
      }
    }
    double tax(Gstr2aInvoice invoice) =>
        invoice.igst + invoice.cgst + invoice.sgst + invoice.cess;
    var portalTax = 0.0, booksTax = 0.0;
    final rows = <Gstr2aMatchRow>[];
    for (final key in {...portal.keys, ...books.keys}) {
      final portalInvoices = portal[key] ?? <Gstr2aInvoice>[];
      final bookInvoices = books[key] ?? <Gstr2aInvoice>[];
      portalInvoices.sort((a, b) => a.date.compareTo(b.date));
      bookInvoices.sort((a, b) => a.date.compareTo(b.date));
      final count = portalInvoices.length > bookInvoices.length
          ? portalInvoices.length
          : bookInvoices.length;
      for (var i = 0; i < count; i++) {
        final p = i < portalInvoices.length ? portalInvoices[i] : null;
        final b = i < bookInvoices.length ? bookInvoices[i] : null;
        if (p != null) portalTax += tax(p);
        if (b != null) booksTax += tax(b);
        final match =
            p != null &&
            b != null &&
            (p.taxableValue - b.taxableValue).abs() < 1 &&
            (p.igst - b.igst).abs() < 1 &&
            (p.cgst - b.cgst).abs() < 1 &&
            (p.sgst - b.sgst).abs() < 1 &&
            (p.cess - b.cess).abs() < 1;
        rows.add(
          Gstr2aMatchRow(
            supplierGstin: key.split('|').first,
            invoiceNumber: (p ?? b)!.number,
            invoiceDate: (p ?? b)!.date,
            status: p == null
                ? 'books_only'
                : b == null
                ? 'portal_only'
                : match
                ? 'matched'
                : 'value_mismatch',
            booksTaxable: b?.taxableValue,
            booksTax: b == null ? null : tax(b),
            portalTaxable: p?.taxableValue,
            portalTax: p == null ? null : tax(p),
          ),
        );
      }
    }
    rows.sort(
      (a, b) => '${a.supplierGstin}|${a.invoiceNumber}'.compareTo(
        '${b.supplierGstin}|${b.invoiceNumber}',
      ),
    );
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
