import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import '../../engine/gst_engine.dart';
import '../app_database.dart';
import 'repository_extensions.dart';
import 'sync_mixin.dart';

/// Aggregated dashboard KPIs.
class DashboardSummary {
  final Decimal totalSales;
  final Decimal totalPurchases;
  final Decimal totalExpenses;
  final Decimal totalIncome;
  final Decimal totalReceived;
  final Decimal totalPaid;

  /// Lifetime money in / money out. "Cash in hand" is a balance, not a
  /// period figure, so it must not be derived from the windowed totals.
  final Decimal cashIn;
  final Decimal cashOut;
  final Decimal receivable; // customers owe us
  final Decimal payable; // we owe suppliers
  final Decimal stockValue;
  final Decimal gstPayable;
  final Decimal grossProfit;
  final int invoiceCount;
  final int lowStockCount;
  final int overdueCount;

  const DashboardSummary({
    required this.totalSales,
    required this.totalPurchases,
    required this.totalExpenses,
    required this.totalIncome,
    required this.totalReceived,
    required this.totalPaid,
    required this.cashIn,
    required this.cashOut,
    required this.receivable,
    required this.payable,
    required this.stockValue,
    required this.gstPayable,
    required this.grossProfit,
    required this.invoiceCount,
    required this.lowStockCount,
    required this.overdueCount,
  });

  /// `Decimal.zero` is not a compile-time constant, so this cannot be `const`.
  static DashboardSummary empty() => DashboardSummary(
    totalSales: Decimal.zero,
    totalPurchases: Decimal.zero,
    totalExpenses: Decimal.zero,
    totalIncome: Decimal.zero,
    totalReceived: Decimal.zero,
    totalPaid: Decimal.zero,
    cashIn: Decimal.zero,
    cashOut: Decimal.zero,
    receivable: Decimal.zero,
    payable: Decimal.zero,
    stockValue: Decimal.zero,
    gstPayable: Decimal.zero,
    grossProfit: Decimal.zero,
    invoiceCount: 0,
    lowStockCount: 0,
    overdueCount: 0,
  );
}

class MonthlyPoint {
  final DateTime month;
  final Decimal sales;
  final Decimal purchases;

  const MonthlyPoint(this.month, this.sales, this.purchases);
}

/// GST liability summary, rate-wise (the GSTR-1 / 3B shape).
class GstSummary {
  final Decimal taxableValue;
  final Decimal outputCgst;
  final Decimal outputSgst;
  final Decimal outputIgst;
  final Decimal cess;
  final Decimal inputCgst;
  final Decimal inputSgst;
  final Decimal inputIgst;

  /// Input credit on expenses (rent, software, professional fees) — GST the
  /// firm paid on its own bills rather than on goods for resale.
  ///
  /// Kept as one amount because an expense carries a single GST figure and no
  /// place of supply, so there is nothing to split it CGST/SGST/IGST by. It is
  /// still credit: leaving it out of the summary understated net payable, and
  /// it belongs in 3B Table 4(A)(5) "all other ITC" with the rest.
  final Decimal inputFromExpenses;

  final List<RateWiseTax> outwardByRate;

  const GstSummary({
    required this.taxableValue,
    required this.outputCgst,
    required this.outputSgst,
    required this.outputIgst,
    required this.cess,
    required this.inputCgst,
    required this.inputSgst,
    required this.inputIgst,
    // Deliberately not defaulted: `Decimal.zero` is not a compile-time
    // constant, and every caller has to think about whether it has expense
    // credit to report.
    required this.inputFromExpenses,
    required this.outwardByRate,
  });

  Decimal get outputTax => outputCgst + outputSgst + outputIgst + cess;
  Decimal get inputTax => inputCgst + inputSgst + inputIgst;

  /// Everything creditable: purchase bills plus the GST inside expenses.
  Decimal get totalInputCredit => inputTax + inputFromExpenses;

  /// GST payable for the period — the same floor-at-zero rule a filed return
  /// applies (see `Gstr3bReport.netPayable`).
  ///
  /// A return never declares a negative liability. When input credit exceeds
  /// output tax the excess is carried forward and set off against later
  /// periods; it is not a refund and it is certainly not a negative payable.
  /// This was a raw `outputTax - totalInputCredit`, so the dashboard could
  /// print "GST payable −₹1,800" for a month in which the GSTR-3B built from
  /// these same books said ₹0.00. Clamped rather than carried in a column of
  /// its own because this struct has nowhere to put a credit-forward balance;
  /// the return builder remains the authority for the filed figure.
  Decimal get netPayable {
    final net = outputTax - totalInputCredit;
    return net < Decimal.zero ? Decimal.zero : net;
  }

  factory GstSummary.empty() => GstSummary(
    taxableValue: Decimal.zero,
    outputCgst: Decimal.zero,
    outputSgst: Decimal.zero,
    outputIgst: Decimal.zero,
    cess: Decimal.zero,
    inputCgst: Decimal.zero,
    inputSgst: Decimal.zero,
    inputIgst: Decimal.zero,
    inputFromExpenses: Decimal.zero,
    outwardByRate: [],
  );
}

/// TDS and TCS for a period.
///
/// Kept apart from [GstSummary] because neither is GST: both are income-tax
/// liabilities a shop deposits with a challan (ITNS-281, by the 7th of the
/// following month), and mixing them into "GST payable" would make the number
/// the operator files against wrong.
class TaxAtSourceSummary {
  final Decimal tdsDeducted;
  final Decimal tcsCollected;
  final int billsWithTds;
  final int invoicesWithTcs;

  const TaxAtSourceSummary({
    required this.tdsDeducted,
    required this.tcsCollected,
    required this.billsWithTds,
    required this.invoicesWithTcs,
  });

  Decimal get total => tdsDeducted + tcsCollected;

  bool get isEmpty =>
      tdsDeducted == Decimal.zero && tcsCollected == Decimal.zero;

  /// `Decimal.zero` is a `static final`, not a `const`, so this cannot be a
  /// const constructor call — same reason every other empty value in this file
  /// is built at runtime.
  factory TaxAtSourceSummary.empty() => TaxAtSourceSummary(
    tdsDeducted: Decimal.zero,
    tcsCollected: Decimal.zero,
    billsWithTds: 0,
    invoicesWithTcs: 0,
  );
}

/// One row of the profit & loss statement.
class PnLRow {
  final String label;
  final Decimal amount;

  const PnLRow(this.label, this.amount);
}

class ProfitAndLoss {
  final DateTime from;
  final DateTime to;
  final List<PnLRow> incomeRows;
  final List<PnLRow> expenseRows;
  final Decimal totalIncome;
  final Decimal totalExpenses;
  final Decimal grossProfit;
  final Decimal netProfit;

  /// Stock on hand at cost when the period opened, and when it closed.
  ///
  /// Treating every purchase as a cost of the period it was bought in is only
  /// right when nothing is left on the shelf: a shop that bought ₹10L of goods
  /// in March and sold ₹2L of them looks like it lost ₹8L. The opening and
  /// closing valuation turn purchases into cost of goods *sold*. Zero for a
  /// firm that does not track stock, so a services business reads exactly as
  /// it did before.
  final Decimal openingStock;
  final Decimal closingStock;

  /// Purchases adjusted for the stock movement: opening stock + purchases −
  /// closing stock. This is what gross profit is measured against.
  final Decimal costOfGoodsSold;

  const ProfitAndLoss({
    required this.from,
    required this.to,
    required this.incomeRows,
    required this.expenseRows,
    required this.totalIncome,
    required this.totalExpenses,
    required this.grossProfit,
    required this.netProfit,
    // Not defaulted: `Decimal.zero` is not a compile-time constant, and a
    // caller that forgot these would silently report purchases as cost of
    // sales.
    required this.openingStock,
    required this.closingStock,
    required this.costOfGoodsSold,
    // Not defaulted for the same reason as the stock figures: a caller that
    // forgot this would render an empty firm as though it had a nil statement.
    required this.hasActivity,
  });

  /// True when the period's result was worked out through a stock adjustment
  /// rather than by treating every purchase as a cost.
  bool get hasStockAdjustment =>
      openingStock != Decimal.zero || closingStock != Decimal.zero;

  /// True when at least one live document, expense or stock movement fell in
  /// the period.
  ///
  /// **This is deliberately not "any total is non-zero".** A firm that sold
  /// ₹1,000 and returned all of it has zero income, zero expenses and zero net
  /// — but it certainly traded, and a P&L that refused to print would hide the
  /// only thing that happened. The distinction is between *nothing happened* and
  /// *things happened that cancelled out*.
  ///
  /// A caller that renders this statement needs it: printing a four-line sheet
  /// of zeros for a firm that has never traded reads as a result — a nil P&L is
  /// a statement, an empty one is not.
  final bool hasActivity;
}

/// One line of a party ledger / statement of account.
class LedgerLine {
  final DateTime date;
  final String particulars;
  final String reference;
  final Decimal debit;
  final Decimal credit;
  final Decimal balance;

  const LedgerLine({
    required this.date,
    required this.particulars,
    required this.reference,
    required this.debit,
    required this.credit,
    required this.balance,
  });
}

class PartyStatement {
  final String partyId;
  final String partyName;
  final Decimal opening;
  final Decimal closing;
  final List<LedgerLine> lines;

  const PartyStatement({
    required this.partyId,
    required this.partyName,
    required this.opening,
    required this.closing,
    required this.lines,
  });

  /// Period totals for the statement exports (opening row excluded — it is
  /// a carry-forward, not activity).
  Decimal get totalDebit {
    var total = Decimal.zero;
    for (final line in lines) {
      if (line.particulars != 'Opening Balance') total += line.debit;
    }
    return total;
  }

  Decimal get totalCredit {
    var total = Decimal.zero;
    for (final line in lines) {
      if (line.particulars != 'Opening Balance') total += line.credit;
    }
    return total;
  }
}

/// One row of the day book.
class DayBookLine {
  final DateTime date;
  final String type;
  final String number;
  final String party;
  final Decimal amount;

  const DayBookLine({
    required this.date,
    required this.type,
    required this.number,
    required this.party,
    required this.amount,
  });
}

/// All report queries in one place. Reads only; never mutates.
class ReportRepository {
  ReportRepository(this.db, this.firmId);

  final AppDatabase db;
  final String firmId;

  Decimal _d(double v) => Decimal.parse(v.toStringAsFixed(2));

  // ---------------- Dashboard ----------------

  Future<DashboardSummary> dashboard({DateTime? from, DateTime? to}) async {
    final range = DateRangeFilter(
      start: from ?? DateTime(DateTime.now().year, DateTime.now().month, 1),
      end: to ?? DateTime.now(),
    );

    final sales = await db
        .salesRepositoryFor(firmId)
        .list(
          docType: 'invoice',
          from: range.start,
          to: range.end,
          limit: 1000000,
        );
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(
          docType: 'bill',
          from: range.start,
          to: range.end,
          limit: 1000000,
        );
    final expenses = await db
        .expenseRepositoryFor(firmId)
        .list(
          type: 'expense',
          from: range.start,
          to: range.end,
          limit: 1000000,
        );
    final income = await db
        .expenseRepositoryFor(firmId)
        .list(type: 'income', from: range.start, to: range.end, limit: 1000000);
    final paymentsIn = await db
        .paymentRepositoryFor(firmId)
        .list(
          type: 'payment_in',
          from: range.start,
          to: range.end,
          limit: 1000000,
        );
    final paymentsOut = await db
        .paymentRepositoryFor(firmId)
        .list(
          type: 'payment_out',
          from: range.start,
          to: range.end,
          limit: 1000000,
        );
    // Cash is a balance: the windowed receipts above answer "what came in this
    // month", not "what is in hand". Netted under the "Cash in hand" label
    // they read ₹0.00 for anyone who simply had not been paid this month.
    final allPaymentsIn = await db
        .paymentRepositoryFor(firmId)
        .list(type: 'payment_in', limit: 1000000);
    final allPaymentsOut = await db
        .paymentRepositoryFor(firmId)
        .list(type: 'payment_out', limit: 1000000);
    final allSales = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'invoice', limit: 1000000);
    final allPurchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', limit: 1000000);
    final items = await db.itemRepositoryFor(firmId).all();
    final lowStock = await db.itemRepositoryFor(firmId).lowStock();

    double salesTotal = 0;
    double taxableTotal = 0;
    int overdue = 0;
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      salesTotal += s.grandTotal;
      taxableTotal += s.taxableValue;
      if (s.balanceDue > 0.001 &&
          s.dueDate != null &&
          s.dueDate!.isBefore(DateTime.now())) {
        overdue++;
      }
    }
    double purchasesTotal = 0;
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      purchasesTotal += p.grandTotal;
    }
    double expenseTotal = 0;
    for (final e in expenses) {
      expenseTotal += e.amount;
    }
    double incomeTotal = 0;
    for (final i in income) {
      incomeTotal += i.amount;
    }
    double received = 0;
    for (final p in paymentsIn) {
      received += p.amount;
    }
    double paid = 0;
    for (final p in paymentsOut) {
      paid += p.amount;
    }
    double cashIn = 0;
    for (final p in allPaymentsIn) {
      cashIn += p.amount;
    }
    double cashOut = 0;
    for (final p in allPaymentsOut) {
      cashOut += p.amount;
    }
    double receivable = 0;
    for (final s in allSales) {
      if (s.status == 'cancelled') continue;
      receivable += s.balanceDue;
    }
    double payable = 0;
    for (final p in allPurchases) {
      if (p.status == 'cancelled') continue;
      payable += p.balanceDue;
    }
    double stockValue = 0;
    for (final i in items) {
      // Services aren't counted in stock — see ItemRepository.stockValue.
      if (i.isService || i.stockType != 'tracked') continue;
      stockValue += i.currentStock * i.salePrice;
    }

    // GST payable this period (output less input).
    final gst = await gstSummary(from: range.start, to: range.end);

    // Gross profit approximation: sales taxable minus purchase taxable for
    // the same period (a trading-account view, before expenses).
    double purchaseTaxable = 0;
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      purchaseTaxable += p.taxableValue;
    }
    final grossProfit = taxableTotal - purchaseTaxable;

    return DashboardSummary(
      totalSales: _d(salesTotal),
      totalPurchases: _d(purchasesTotal),
      totalExpenses: _d(expenseTotal),
      totalIncome: _d(incomeTotal),
      totalReceived: _d(received),
      totalPaid: _d(paid),
      cashIn: _d(cashIn),
      cashOut: _d(cashOut),
      receivable: _d(receivable),
      payable: _d(payable),
      stockValue: _d(stockValue),
      gstPayable: gst.netPayable,
      grossProfit: _d(grossProfit),
      invoiceCount: sales.where((s) => s.status != 'cancelled').length,
      lowStockCount: lowStock.length,
      overdueCount: overdue,
    );
  }

  /// 6-month sales vs purchases series for the dashboard chart.
  Future<List<MonthlyPoint>> monthlyTrend({int months = 6}) async {
    final points = <MonthlyPoint>[];
    final now = DateTime.now();
    for (var i = months - 1; i >= 0; i--) {
      final start = DateTime(now.year, now.month - i, 1);
      final end = DateTime(now.year, now.month - i + 1, 0, 23, 59, 59);
      final sales = await db
          .salesRepositoryFor(firmId)
          .list(docType: 'invoice', from: start, to: end, limit: 1000000);
      final purchases = await db
          .purchaseRepositoryFor(firmId)
          .list(docType: 'bill', from: start, to: end, limit: 1000000);
      double s = 0;
      for (final x in sales) {
        if (x.status != 'cancelled') s += x.grandTotal;
      }
      double p = 0;
      for (final x in purchases) {
        if (x.status != 'cancelled') p += x.grandTotal;
      }
      points.add(MonthlyPoint(start, _d(s), _d(p)));
    }
    return points;
  }

  // ---------------- GST ----------------

  Future<GstSummary> gstSummary({
    required DateTime from,
    required DateTime to,
  }) async {
    final sales = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: from, to: to, limit: 1000000);
    // Sales CREDIT NOTES reduce outward supplies in the period they are issued
    // and purchase DEBIT NOTES reduce inward credit — GSTR-3B subtracts both
    // (`addOutward(cn, sign:-1)`, `addInward(dn, sign:-1)`). Reading invoices
    // and bills only is why this summary and the return disagreed about the
    // same month by the value of every note issued in it.
    final creditNotes = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'credit_note', from: from, to: to, limit: 1000000);
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: from, to: to, limit: 1000000);
    final debitNotes = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'debit_note', from: from, to: to, limit: 1000000);

    // One query for every line of every invoice in the period. This used to
    // call itemsFor(s.id) inside the loop above — an N+1 that took a visible
    // pause on a firm with a thousand invoices in the month, for exactly the
    // same numbers.
    final invoiceIds = [
      for (final s in [...sales, ...creditNotes])
        if (s.status != 'cancelled' && !s.isExport) s.id,
    ];
    final linesByInvoice = await db
        .salesRepositoryFor(firmId)
        .itemsForMany(invoiceIds);

    double taxable = 0, ocgst = 0, osgst = 0, oigst = 0, cess = 0;
    final byRate = <double, RateWiseTax>{};

    /// Money is accumulated as `double` (the column type) and converted once
    /// at the edge by [_d], the same way the rest of this file does it.
    Decimal accumulate(Decimal current, double delta) =>
        Decimal.parse((current.toDouble() + delta).toStringAsFixed(2));

    /// [sign] is -1 for a credit note, so outward supplies are net of notes.
    /// Export invoices are excluded on both sides: they are zero-rated and go
    /// to GSTR-3B 3.1(b), not to the taxable outward figures here.
    void addOutward(SalesInvoiceEntity s, double sign) {
      if (s.status == 'cancelled' || s.isExport) return;
      taxable += sign * s.taxableValue;
      ocgst += sign * s.cgst;
      osgst += sign * s.sgst;
      oigst += sign * s.igst;
      cess += sign * s.cess;
      final items = linesByInvoice[s.id] ?? const <SalesInvoiceItemEntity>[];
      for (final l in items) {
        final existing = byRate[l.gstRate];
        byRate[l.gstRate] = RateWiseTax(
          rate: l.gstRate,
          taxableValue: accumulate(
            existing?.taxableValue ?? Decimal.zero,
            sign * l.taxableValue,
          ),
          cgst: accumulate(existing?.cgst ?? Decimal.zero, sign * l.cgst),
          sgst: accumulate(existing?.sgst ?? Decimal.zero, sign * l.sgst),
          igst: accumulate(existing?.igst ?? Decimal.zero, sign * l.igst),
          cess: accumulate(existing?.cess ?? Decimal.zero, sign * l.cessAmount),
          // A note reverses a supply rather than adding one, so it is not
          // counted as a line of outward supply — only its amounts are netted.
          lineCount: (existing?.lineCount ?? 0) + (sign > 0 ? 1 : 0),
        );
      }
    }

    for (final s in sales) {
      addOutward(s, 1);
    }
    for (final cn in creditNotes) {
      addOutward(cn, -1);
    }

    double icgst = 0, isgst = 0, iigst = 0;
    for (final p in [...purchases, ...debitNotes]) {
      if (p.status == 'cancelled') continue;
      final sign = p.docType == 'debit_note' ? -1.0 : 1.0;
      icgst += sign * p.cgst;
      isgst += sign * p.sgst;
      iigst += sign * p.igst;
    }

    // GST paid on the firm's own expenses was never claimed as credit: the
    // summary only ever looked at purchase bills, so the tax inside a rent or
    // software bill silently increased GST payable. The amount is a component
    // of the expense total, not an extra cost, which is why the P&L is
    // unaffected by claiming it.
    final expenseCredit = await db
        .ledgerRepositoryFor(firmId)
        .inputTaxFromExpenses(from: from, to: to);

    // Known, deliberate divergence from GSTR-3B: this summary counts
    // reverse-charge tax on a bill as creditable, while the return treats it as
    // a cash liability payable under Section 49(4) and gives no credit for it
    // (itcForOutward = netItc − itcReverseCharge). Splitting it here would
    // change the Input CGST/SGST/IGST columns the reports card and dashboard
    // both display, which is a bigger change than this fix is allowed to make;
    // the return builder stays the authority for a filed month.

    final rateWise = byRate.values.toList()
      ..sort((a, b) => a.rate.compareTo(b.rate));

    return GstSummary(
      taxableValue: _d(taxable),
      outputCgst: _d(ocgst),
      outputSgst: _d(osgst),
      outputIgst: _d(oigst),
      cess: _d(cess),
      inputCgst: _d(icgst),
      inputSgst: _d(isgst),
      inputIgst: _d(iigst),
      inputFromExpenses: _d(expenseCredit),
      outwardByRate: rateWise,
    );
  }

  /// Tax deducted at source on purchases, and collected at source on sales.
  ///
  /// Read from the document totals the editor stored, not recomputed from the
  /// rates: a document whose rate was changed after it was issued must report
  /// what was actually deducted at the time, and the total is the figure the
  /// challan is filled in from.
  Future<TaxAtSourceSummary> taxAtSource({
    required DateTime from,
    required DateTime to,
  }) async {
    final bills = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: from, to: to, limit: 1000000);
    final invoices = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: from, to: to, limit: 1000000);

    var tds = 0.0;
    var billsWithTds = 0;
    for (final bill in bills) {
      if (bill.status == 'cancelled') continue;
      if (bill.tds.abs() <= 0.0001) continue;
      tds += bill.tds;
      billsWithTds++;
    }

    var tcs = 0.0;
    var invoicesWithTcs = 0;
    for (final invoice in invoices) {
      if (invoice.status == 'cancelled') continue;
      if (invoice.tcs.abs() <= 0.0001) continue;
      tcs += invoice.tcs;
      invoicesWithTcs++;
    }

    return TaxAtSourceSummary(
      tdsDeducted: _d(tds),
      tcsCollected: _d(tcs),
      billsWithTds: billsWithTds,
      invoicesWithTcs: invoicesWithTcs,
    );
  }

  // ---------------- Profit & Loss ----------------

  Future<ProfitAndLoss> profitAndLoss({
    required DateTime from,
    required DateTime to,
  }) async {
    final sales = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: from, to: to, limit: 1000000);
    // A credit note reduces income in the period it is issued and a debit note
    // reduces expenses — the same direction GSTR-3B gives them. Reading only
    // invoices and bills overstated income by every credit note and expenses
    // by every debit note, so the P&L did not agree with the return filed from
    // the same books for the same month.
    final creditNotes = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'credit_note', from: from, to: to, limit: 1000000);
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: from, to: to, limit: 1000000);
    final debitNotes = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'debit_note', from: from, to: to, limit: 1000000);
    final expenses = await db
        .expenseRepositoryFor(firmId)
        .list(type: 'expense', from: from, to: to, limit: 1000000);
    final income = await db
        .expenseRepositoryFor(firmId)
        .list(type: 'income', from: from, to: to, limit: 1000000);

    double salesTaxable = 0;
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      salesTaxable += s.taxableValue;
    }
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      salesTaxable -= cn.taxableValue;
    }
    double purchaseTaxable = 0;
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      purchaseTaxable += p.taxableValue;
    }
    for (final dn in debitNotes) {
      if (dn.status == 'cancelled') continue;
      purchaseTaxable -= dn.taxableValue;
    }
    final expenseByCat = <String, double>{};
    for (final e in expenses) {
      expenseByCat[e.category] = (expenseByCat[e.category] ?? 0) + e.amount;
    }
    final incomeByCat = <String, double>{};
    for (final i in income) {
      incomeByCat[i.category] = (incomeByCat[i.category] ?? 0) + i.amount;
    }

    // Stock in hand at the two ends of the period, at cost. Closing stock is
    // an asset, not an expense — without this line a firm that bought for the
    // season showed a loss until the stock sold.
    final openingStock = await stockAtCost(
      asOf: from.subtract(const Duration(days: 1)),
    );
    final closingStock = await stockAtCost(asOf: to);
    final costOfGoodsSold = purchaseTaxable + openingStock - closingStock;
    final grossProfit = salesTaxable - costOfGoodsSold;
    final expenseRows =
        expenseByCat.entries.map((e) => PnLRow(e.key, _d(e.value))).toList()
          ..sort((a, b) => b.amount.compareTo(a.amount));
    final incomeRows =
        incomeByCat.entries.map((e) => PnLRow(e.key, _d(e.value))).toList()
          ..sort((a, b) => b.amount.compareTo(a.amount));

    final totalExpenses = expenseByCat.values.fold<double>(0, (a, b) => a + b);
    final totalIncome = incomeByCat.values.fold<double>(0, (a, b) => a + b);

    return ProfitAndLoss(
      from: from,
      to: to,
      incomeRows: [
        PnLRow('Sales (net of tax)', _d(salesTaxable)),
        ...incomeRows,
      ],
      expenseRows: [
        PnLRow('Cost of goods purchased', _d(purchaseTaxable)),
        ...expenseRows,
      ],
      totalIncome: _d(salesTaxable + totalIncome),
      // Purchases are replaced by cost of goods sold, so the stock adjustment
      // is not counted twice.
      totalExpenses: _d(costOfGoodsSold + totalExpenses),
      grossProfit: _d(grossProfit),
      openingStock: _d(openingStock),
      closingStock: _d(closingStock),
      costOfGoodsSold: _d(costOfGoodsSold),
      // Net profit = total income − total expenses, where income already
      // includes sales and expenses already include purchases. The old
      // `grossProfit + totalIncome − totalExpenses` expanded to
      // 2·sales − 2·purchases + income − expenses, overstating profit by
      // exactly the gross profit.
      netProfit: _d(
        salesTaxable + totalIncome - costOfGoodsSold - totalExpenses,
      ),
      // Counted from the documents themselves, before they net off, so a sale
      // and its matching return still read as activity. `list` has already
      // dropped soft-deleted rows; cancelled ones are excluded here with the
      // same check the arithmetic below uses, or a cancelled invoice would
      // resurrect an otherwise empty firm.
      hasActivity:
          sales.any((s) => s.status != 'cancelled') ||
          creditNotes.any((s) => s.status != 'cancelled') ||
          purchases.any((p) => p.status != 'cancelled') ||
          debitNotes.any((p) => p.status != 'cancelled') ||
          expenses.isNotEmpty ||
          income.isNotEmpty ||
          openingStock != 0 ||
          closingStock != 0,
    );
  }

  /// Stock on hand, valued at cost, as of the end of [asOf].
  ///
  /// Read from the stock ledger rather than the item's cached balance, because
  /// a P&L needs the value at a *date* — the closing stock of June is the
  /// opening stock of July, and the difference is what the period consumed.
  /// Quantities are signed movements, so summing them to a date is the balance
  /// at that date.
  Future<double> stockAtCost({required DateTime asOf}) async {
    final end = DateTime(asOf.year, asOf.month, asOf.day, 23, 59, 59);
    final movements =
        await (db.select(db.stockMovements)..where(
              (t) =>
                  t.firmId.equals(firmId) & t.date.isSmallerOrEqualValue(end),
            ))
            .get();
    if (movements.isEmpty) return 0;
    final items = await db.itemRepositoryFor(firmId).all();
    final costById = {for (final i in items) i.id: i.purchasePrice};
    final quantityById = <String, double>{};
    for (final movement in movements) {
      if (!costById.containsKey(movement.itemId)) continue;
      quantityById[movement.itemId] =
          (quantityById[movement.itemId] ?? 0) + movement.quantity;
    }
    var total = 0.0;
    quantityById.forEach((itemId, quantity) {
      // Negative stock (billing ahead of the purchase entry) is not an asset;
      // valuing it would invent a loss on goods that were never bought.
      if (quantity <= 0) return;
      total += quantity * (costById[itemId] ?? 0);
    });
    return total;
  }

  // ---------------- Party statement ----------------

  Future<PartyStatement> partyStatement({
    required String partyId,
    DateTime? from,
    DateTime? to,
  }) async {
    final party =
        await (db.select(db.parties)
              ..where((t) => t.id.equals(partyId) & t.firmId.equals(firmId)))
            .getSingleOrNull();
    final name = party?.name ?? 'Party';

    final sales = await db
        .salesRepositoryFor(firmId)
        .list(
          docType: 'invoice',
          partyId: partyId,
          from: from,
          to: to,
          limit: 1000000,
        );
    final creditNotes = await db
        .salesRepositoryFor(firmId)
        .list(
          docType: 'credit_note',
          partyId: partyId,
          from: from,
          to: to,
          limit: 1000000,
        );
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(
          docType: 'bill',
          partyId: partyId,
          from: from,
          to: to,
          limit: 1000000,
        );
    final debitNotes = await db
        .purchaseRepositoryFor(firmId)
        .list(
          docType: 'debit_note',
          partyId: partyId,
          from: from,
          to: to,
          limit: 1000000,
        );
    // The payments have to honour the same window as the documents; `forParty`
    // returns the whole history, so a "this month" statement listed payments
    // from every previous month too.
    final payments = await db
        .paymentRepositoryFor(firmId)
        .list(partyId: partyId, from: from, to: to, limit: 1000000);

    // The opening balance is the party's opening plus everything that happened
    // before the window. Without the carry-forward, a statement for April
    // would print January's opening balance next to April's rows and the
    // closing figure would silently disagree with the running total above it.
    var opening = party?.openingBalance ?? 0.0;
    if (party != null && party.openingBalanceType == 'cr') {
      opening = -opening;
    }
    if (from != null) {
      final priorSales = await db
          .salesRepositoryFor(firmId)
          .list(
            docType: 'invoice',
            partyId: partyId,
            to: from.subtract(const Duration(microseconds: 1)),
            limit: 1000000,
          );
      final priorCreditNotes = await db
          .salesRepositoryFor(firmId)
          .list(
            docType: 'credit_note',
            partyId: partyId,
            to: from.subtract(const Duration(microseconds: 1)),
            limit: 1000000,
          );
      final priorPurchases = await db
          .purchaseRepositoryFor(firmId)
          .list(
            docType: 'bill',
            partyId: partyId,
            to: from.subtract(const Duration(microseconds: 1)),
            limit: 1000000,
          );
      final priorDebitNotes = await db
          .purchaseRepositoryFor(firmId)
          .list(
            docType: 'debit_note',
            partyId: partyId,
            to: from.subtract(const Duration(microseconds: 1)),
            limit: 1000000,
          );
      final priorPayments = await db
          .paymentRepositoryFor(firmId)
          .list(
            partyId: partyId,
            to: from.subtract(const Duration(microseconds: 1)),
            limit: 1000000,
          );
      for (final s in priorSales) {
        if (s.status == 'cancelled') continue;
        opening += s.grandTotal;
      }
      for (final cn in priorCreditNotes) {
        if (cn.status == 'cancelled') continue;
        opening -= cn.grandTotal;
      }
      for (final p in priorPurchases) {
        if (p.status == 'cancelled') continue;
        opening -= p.grandTotal;
      }
      for (final dn in priorDebitNotes) {
        if (dn.status == 'cancelled') continue;
        opening += dn.grandTotal;
      }
      for (final p in priorPayments) {
        if (p.chequeStatus == 'bounced') continue;
        opening += p.type == 'payment_in' ? -p.amount : p.amount;
      }
    }

    final events = <_LedgerEvent>[];
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      events.add(
        _LedgerEvent(
          s.invoiceDate,
          'Sales Invoice ${s.number}',
          s.number,
          s.grandTotal,
          0,
        ),
      );
    }
    for (final cn in creditNotes) {
      if (cn.status == 'cancelled') continue;
      events.add(
        _LedgerEvent(
          cn.invoiceDate,
          'Credit Note ${cn.number}',
          cn.number,
          0,
          cn.grandTotal,
        ),
      );
    }
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      events.add(
        _LedgerEvent(
          p.billDate,
          'Purchase Bill ${p.number}',
          p.number,
          0,
          p.grandTotal,
        ),
      );
    }
    for (final dn in debitNotes) {
      if (dn.status == 'cancelled') continue;
      events.add(
        _LedgerEvent(
          dn.billDate,
          'Debit Note ${dn.number}',
          dn.number,
          dn.grandTotal,
          0,
        ),
      );
    }
    for (final p in payments) {
      if (p.chequeStatus == 'bounced') continue;
      final isIn = p.type == 'payment_in';
      events.add(
        _LedgerEvent(
          p.date,
          isIn ? 'Payment Received ${p.number}' : 'Payment Made ${p.number}',
          p.number,
          isIn ? 0 : p.amount,
          isIn ? p.amount : 0,
        ),
      );
    }
    events.sort((a, b) => a.date.compareTo(b.date));

    var running = opening;
    final lines = <LedgerLine>[];
    if (opening.abs() > 0.001) {
      lines.add(
        LedgerLine(
          date: from ?? DateTime(2000),
          particulars: 'Opening Balance',
          reference: '',
          debit: opening > 0 ? _d(opening) : Decimal.zero,
          credit: opening < 0 ? _d(-opening) : Decimal.zero,
          balance: _d(running),
        ),
      );
    }
    for (final e in events) {
      running += e.debit - e.credit;
      lines.add(
        LedgerLine(
          date: e.date,
          particulars: e.particulars,
          reference: e.reference,
          debit: _d(e.debit),
          credit: _d(e.credit),
          balance: _d(running),
        ),
      );
    }

    return PartyStatement(
      partyId: partyId,
      partyName: name,
      opening: _d(opening),
      closing: _d(running),
      lines: lines,
    );
  }

  // ---------------- Day book ----------------

  Future<List<DayBookLine>> dayBook({required DateTime day}) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day, 23, 59, 59);
    final sales = await db
        .salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: start, to: end, limit: 1000000);
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: start, to: end, limit: 1000000);
    final expenses = await db
        .expenseRepositoryFor(firmId)
        .list(type: 'expense', from: start, to: end, limit: 1000000);
    final paymentsIn = await db
        .paymentRepositoryFor(firmId)
        .list(type: 'payment_in', from: start, to: end, limit: 1000000);
    final paymentsOut = await db
        .paymentRepositoryFor(firmId)
        .list(type: 'payment_out', from: start, to: end, limit: 1000000);

    final rows = <DayBookLine>[];
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      rows.add(
        DayBookLine(
          date: s.invoiceDate,
          type: 'Sales',
          number: s.number,
          party: s.partyName ?? '-',
          amount: _d(s.grandTotal),
        ),
      );
    }
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      rows.add(
        DayBookLine(
          date: p.billDate,
          type: 'Purchase',
          number: p.number,
          party: p.partyName ?? '-',
          amount: _d(p.grandTotal),
        ),
      );
    }
    for (final e in expenses) {
      rows.add(
        DayBookLine(
          date: e.date,
          type: 'Expense',
          number: e.number,
          party: e.vendorName ?? e.category,
          amount: _d(e.amount),
        ),
      );
    }
    for (final p in paymentsIn) {
      rows.add(
        DayBookLine(
          date: p.date,
          type: 'Receipt',
          number: p.number,
          party: p.partyName ?? '-',
          amount: _d(p.amount),
        ),
      );
    }
    for (final p in paymentsOut) {
      rows.add(
        DayBookLine(
          date: p.date,
          type: 'Payment',
          number: p.number,
          party: p.partyName ?? '-',
          amount: _d(p.amount),
        ),
      );
    }
    rows.sort((a, b) => b.date.compareTo(a.date));
    return rows;
  }

  // ---------------- Stock summary ----------------

  Future<List<StockSummaryRow>> stockSummary() async {
    final items = await db.itemRepositoryFor(firmId).all();
    final rows = <StockSummaryRow>[];
    for (final i in items) {
      // Services aren't counted in stock — see ItemRepository.stockValue.
      if (i.isService || i.stockType != 'tracked') continue;
      rows.add(
        StockSummaryRow(
          itemId: i.id,
          name: i.name,
          hsn: i.hsn,
          unit: i.unit,
          gstRate: i.gstRate,
          stock: i.currentStock,
          saleValue: _d(i.currentStock * i.salePrice),
          purchaseValue: _d(i.currentStock * i.purchasePrice),
          lowStockAlert: i.lowStockAlert,
        ),
      );
    }
    rows.sort((a, b) => a.name.compareTo(b.name));
    return rows;
  }
}

class StockSummaryRow {
  final String itemId;
  final String name;
  final String? hsn;
  final String unit;
  final double gstRate;
  final double stock;
  final Decimal saleValue;
  final Decimal purchaseValue;
  final double lowStockAlert;

  const StockSummaryRow({
    required this.itemId,
    required this.name,
    this.hsn,
    required this.unit,
    required this.gstRate,
    required this.stock,
    required this.saleValue,
    required this.purchaseValue,
    required this.lowStockAlert,
  });

  bool get isLow => lowStockAlert > 0 && stock <= lowStockAlert;
}

class _LedgerEvent {
  final DateTime date;
  final String particulars;
  final String reference;
  final double debit;
  final double credit;

  const _LedgerEvent(
    this.date,
    this.particulars,
    this.reference,
    this.debit,
    this.credit,
  );
}
