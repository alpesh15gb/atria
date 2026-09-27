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
    required this.outwardByRate,
  });

  Decimal get outputTax => outputCgst + outputSgst + outputIgst + cess;
  Decimal get inputTax => inputCgst + inputSgst + inputIgst;
  Decimal get netPayable => outputTax - inputTax;

  factory GstSummary.empty() => GstSummary(
        taxableValue: Decimal.zero,
        outputCgst: Decimal.zero,
        outputSgst: Decimal.zero,
        outputIgst: Decimal.zero,
        cess: Decimal.zero,
        inputCgst: Decimal.zero,
        inputSgst: Decimal.zero,
        inputIgst: Decimal.zero,
        outwardByRate: [],
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

  const ProfitAndLoss({
    required this.from,
    required this.to,
    required this.incomeRows,
    required this.expenseRows,
    required this.totalIncome,
    required this.totalExpenses,
    required this.grossProfit,
    required this.netProfit,
  });
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

  Future<DashboardSummary> dashboard({
    DateTime? from,
    DateTime? to,
  }) async {
    final range = DateRangeFilter(
      start: from ?? DateTime(DateTime.now().year, DateTime.now().month, 1),
      end: to ?? DateTime.now(),
    );

    final sales = await db.salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: range.start, to: range.end, limit: 1000000);
    final purchases = await db.purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: range.start, to: range.end, limit: 1000000);
    final expenses = await db.expenseRepositoryFor(firmId)
        .list(type: 'expense', from: range.start, to: range.end, limit: 1000000);
    final income = await db.expenseRepositoryFor(firmId)
        .list(type: 'income', from: range.start, to: range.end, limit: 1000000);
    final paymentsIn = await db.paymentRepositoryFor(firmId)
        .list(type: 'payment_in', from: range.start, to: range.end, limit: 1000000);
    final paymentsOut = await db.paymentRepositoryFor(firmId)
        .list(type: 'payment_out', from: range.start, to: range.end, limit: 1000000);
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
      if (s.balanceDue > 0.001 && s.dueDate != null && s.dueDate!.isBefore(DateTime.now())) {
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
      if (i.stockType != 'tracked') continue;
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
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: from, to: to, limit: 1000000);

    double taxable = 0, ocgst = 0, osgst = 0, oigst = 0, cess = 0;
    final byRate = <double, RateWiseTax>{};
    for (final s in sales) {
      if (s.status == 'cancelled' || s.isExport) continue;
      taxable += s.taxableValue;
      ocgst += s.cgst;
      osgst += s.sgst;
      oigst += s.igst;
      cess += s.cess;
      final items = await db.salesRepositoryFor(firmId).itemsFor(s.id);
      for (final l in items) {
        final existing = byRate[l.gstRate];
        byRate[l.gstRate] = RateWiseTax(
          rate: l.gstRate,
          taxableValue: Decimal.parse(
                  ((existing?.taxableValue ?? Decimal.zero).toDouble() + l.taxableValue)
                      .toStringAsFixed(2)) +
              Decimal.zero,
          cgst: Decimal.parse(
                  ((existing?.cgst ?? Decimal.zero).toDouble() + l.cgst)
                      .toStringAsFixed(2)) +
              Decimal.zero,
          sgst: Decimal.parse(
                  ((existing?.sgst ?? Decimal.zero).toDouble() + l.sgst)
                      .toStringAsFixed(2)) +
              Decimal.zero,
          igst: Decimal.parse(
                  ((existing?.igst ?? Decimal.zero).toDouble() + l.igst)
                      .toStringAsFixed(2)) +
              Decimal.zero,
          cess: Decimal.parse(
                  ((existing?.cess ?? Decimal.zero).toDouble() + l.cessAmount)
                      .toStringAsFixed(2)) +
              Decimal.zero,
          lineCount: (existing?.lineCount ?? 0) + 1,
        );
      }
    }

    double icgst = 0, isgst = 0, iigst = 0;
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      icgst += p.cgst;
      isgst += p.sgst;
      iigst += p.igst;
    }

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
      outwardByRate: rateWise,
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
    final purchases = await db
        .purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: from, to: to, limit: 1000000);
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
    double purchaseTaxable = 0;
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      purchaseTaxable += p.taxableValue;
    }
    final expenseByCat = <String, double>{};
    for (final e in expenses) {
      expenseByCat[e.category] = (expenseByCat[e.category] ?? 0) + e.amount;
    }
    final incomeByCat = <String, double>{};
    for (final i in income) {
      incomeByCat[i.category] = (incomeByCat[i.category] ?? 0) + i.amount;
    }

    final grossProfit = salesTaxable - purchaseTaxable;
    final expenseRows = expenseByCat.entries
        .map((e) => PnLRow(e.key, _d(e.value)))
        .toList()
      ..sort((a, b) => b.amount.compareTo(a.amount));
    final incomeRows = incomeByCat.entries
        .map((e) => PnLRow(e.key, _d(e.value)))
        .toList()
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
      totalExpenses: _d(purchaseTaxable + totalExpenses),
      grossProfit: _d(grossProfit),
      // Net profit = total income − total expenses, where income already
      // includes sales and expenses already include purchases. The old
      // `grossProfit + totalIncome − totalExpenses` expanded to
      // 2·sales − 2·purchases + income − expenses, overstating profit by
      // exactly the gross profit.
      netProfit: _d(salesTaxable + totalIncome - purchaseTaxable - totalExpenses),
    );
  }

  // ---------------- Party statement ----------------

  Future<PartyStatement> partyStatement({
    required String partyId,
    DateTime? from,
    DateTime? to,
  }) async {
    final party = await (db.select(db.parties)
          ..where((t) => t.id.equals(partyId) & t.firmId.equals(firmId)))
        .getSingleOrNull();
    final name = party?.name ?? 'Party';

    final sales = await db.salesRepositoryFor(firmId).list(
        docType: 'invoice', partyId: partyId, from: from, to: to, limit: 1000000);
    final purchases = await db.purchaseRepositoryFor(firmId).list(
        docType: 'bill', partyId: partyId, from: from, to: to, limit: 1000000);
    // The payments have to honour the same window as the documents; `forParty`
    // returns the whole history, so a "this month" statement listed payments
    // from every previous month too.
    final payments = await db.paymentRepositoryFor(firmId)
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
      final priorSales = await db.salesRepositoryFor(firmId).list(
          docType: 'invoice',
          partyId: partyId,
          to: from.subtract(const Duration(microseconds: 1)),
          limit: 1000000);
      final priorPurchases = await db.purchaseRepositoryFor(firmId).list(
          docType: 'bill',
          partyId: partyId,
          to: from.subtract(const Duration(microseconds: 1)),
          limit: 1000000);
      final priorPayments = await db.paymentRepositoryFor(firmId).list(
          partyId: partyId,
          to: from.subtract(const Duration(microseconds: 1)),
          limit: 1000000);
      for (final s in priorSales) {
        if (s.status == 'cancelled') continue;
        opening += s.grandTotal;
      }
      for (final p in priorPurchases) {
        if (p.status == 'cancelled') continue;
        opening -= p.grandTotal;
      }
      for (final p in priorPayments) {
        opening += p.type == 'payment_in' ? -p.amount : p.amount;
      }
    }

    final events = <_LedgerEvent>[];
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      events.add(_LedgerEvent(s.invoiceDate, 'Sales Invoice ${s.number}',
          s.number, s.grandTotal, 0));
    }
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      events.add(_LedgerEvent(
          p.billDate, 'Purchase Bill ${p.number}', p.number, 0, p.grandTotal));
    }
    for (final p in payments) {
      final isIn = p.type == 'payment_in';
      events.add(_LedgerEvent(
          p.date,
          isIn ? 'Payment Received ${p.number}' : 'Payment Made ${p.number}',
          p.number,
          isIn ? 0 : p.amount,
          isIn ? p.amount : 0));
    }
    events.sort((a, b) => a.date.compareTo(b.date));

    var running = opening;
    final lines = <LedgerLine>[];
    if (opening.abs() > 0.001) {
      lines.add(LedgerLine(
        date: from ?? DateTime(2000),
        particulars: 'Opening Balance',
        reference: '',
        debit: opening > 0 ? _d(opening) : Decimal.zero,
        credit: opening < 0 ? _d(-opening) : Decimal.zero,
        balance: _d(running),
      ));
    }
    for (final e in events) {
      running += e.debit - e.credit;
      lines.add(LedgerLine(
        date: e.date,
        particulars: e.particulars,
        reference: e.reference,
        debit: _d(e.debit),
        credit: _d(e.credit),
        balance: _d(running),
      ));
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

  Future<List<DayBookLine>> dayBook({
    required DateTime day,
  }) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(day.year, day.month, day.day, 23, 59, 59);
    final sales = await db.salesRepositoryFor(firmId)
        .list(docType: 'invoice', from: start, to: end, limit: 1000000);
    final purchases = await db.purchaseRepositoryFor(firmId)
        .list(docType: 'bill', from: start, to: end, limit: 1000000);
    final expenses = await db
        .expenseRepositoryFor(firmId)
        .list(type: 'expense', from: start, to: end, limit: 1000000);
    final paymentsIn = await db.paymentRepositoryFor(firmId)
        .list(type: 'payment_in', from: start, to: end, limit: 1000000);
    final paymentsOut = await db.paymentRepositoryFor(firmId)
        .list(type: 'payment_out', from: start, to: end, limit: 1000000);

    final rows = <DayBookLine>[];
    for (final s in sales) {
      if (s.status == 'cancelled') continue;
      rows.add(DayBookLine(
        date: s.invoiceDate,
        type: 'Sales',
        number: s.number,
        party: s.partyName ?? '-',
        amount: _d(s.grandTotal),
      ));
    }
    for (final p in purchases) {
      if (p.status == 'cancelled') continue;
      rows.add(DayBookLine(
        date: p.billDate,
        type: 'Purchase',
        number: p.number,
        party: p.partyName ?? '-',
        amount: _d(p.grandTotal),
      ));
    }
    for (final e in expenses) {
      rows.add(DayBookLine(
        date: e.date,
        type: 'Expense',
        number: e.number,
        party: e.vendorName ?? e.category,
        amount: _d(e.amount),
      ));
    }
    for (final p in paymentsIn) {
      rows.add(DayBookLine(
        date: p.date,
        type: 'Receipt',
        number: p.number,
        party: p.partyName ?? '-',
        amount: _d(p.amount),
      ));
    }
    for (final p in paymentsOut) {
      rows.add(DayBookLine(
        date: p.date,
        type: 'Payment',
        number: p.number,
        party: p.partyName ?? '-',
        amount: _d(p.amount),
      ));
    }
    rows.sort((a, b) => b.date.compareTo(a.date));
    return rows;
  }

  // ---------------- Stock summary ----------------

  Future<List<StockSummaryRow>> stockSummary() async {
    final items = await db.itemRepositoryFor(firmId).all();
    final rows = <StockSummaryRow>[];
    for (final i in items) {
      if (i.stockType != 'tracked') continue;
      rows.add(StockSummaryRow(
        itemId: i.id,
        name: i.name,
        hsn: i.hsn,
        unit: i.unit,
        gstRate: i.gstRate,
        stock: i.currentStock,
        saleValue: _d(i.currentStock * i.salePrice),
        purchaseValue: _d(i.currentStock * i.purchasePrice),
        lowStockAlert: i.lowStockAlert,
      ));
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

  const _LedgerEvent(this.date, this.particulars, this.reference, this.debit, this.credit);
}
