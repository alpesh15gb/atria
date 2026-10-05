import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';

import '../transaction/transaction_common.dart';

export '../transaction/transaction_common.dart'
    show dec, kPurchaseDocTypes, kSalesDocTypes, signFor;

/// The window's start, defaulted.
///
/// `ReportWindow.from` is **nullable** — an open-ended window ("everything
/// before this date") is a real state, and `ReportFilters.within` honours it.
/// The GST builders cannot: `buildGstr3b` and `buildGstr1` take concrete
/// `from`/`to` and slice on them. So a GST report has to choose, and the choice
/// is recorded here rather than made at each call site.
DateTime windowFrom(ReportWindow window) =>
    window.from ?? DateTime(2000, 1, 1);

/// The window's end, defaulted to the day after today.
///
/// Mirrors [windowFrom]. A GST period always ends: an open-ended return is not
/// a return, and defaulting the far end to the wall clock keeps an
/// "all time" window from silently reading a century of documents.
DateTime windowTo(ReportWindow window) => window.to ??
    DateTime.now().add(const Duration(days: 1));

/// The **tax rate** a document's tax actually worked out at, as a percentage.
///
/// GST returns are filed rate-wise: the portal wants "taxable value at 18%",
/// not "taxable value" with a tax column beside it, and the rate a line was
/// *written* at is not always the rate it was *taxed* at — an inclusive line at
/// 18% and a discount that lifts the effective rate both move it.
///
/// Derived from the document's own columns rather than from the item master's
/// `gstRate`, because the master is the *next* invoice's rate. Editing the rate
/// on the item would silently rewrite the history of every invoice filed at the
/// old one, and a return that disagrees with the books is a notice.
/// One line's output/input tax, from its own columns.
///
/// [Decimal] throughout: summing `double` tax columns and rounding once at the
/// end is what puts a return a paisa out, and a return a paisa out is a query
/// at the portal.
Decimal taxOf({
  required double cgst,
  required double sgst,
  required double igst,
  required double cess,
}) =>
    dec(cgst) + dec(sgst) + dec(igst) + dec(cess);

Decimal effectiveRateOf({
  required double taxableValue,
  required double cgst,
  required double sgst,
  required double igst,
  required double cess,
}) {
  final taxable = dec(taxableValue);
  if (taxable <= Decimal.zero) return Decimal.zero;

  // Cess is not part of the rate: it is a separate levy on the same base, and
  // adding it to the tax here would put a 18%-goods line with cess into the
  // 20% band, which the portal rejects.
  final tax = dec(cgst) + dec(sgst) + dec(igst);
  // **Three steps, each load-bearing.** `Decimal /` returns a `Rational`, so
  // the division happens exactly — no float anywhere. That Rational has no
  // finite decimal expansion for most rates (18% of 333 is 59.94, but 1/3 of
  // anything is 0.3333…), and a bare `toDecimal()` **throws** on one, which
  // would take the report down rather than print a rate. Converting at six
  // places then rounding HALF_UP once to a whole percent is what puts
  // 17.9934 into the 18% band the portal files it under.
  final percent = (tax * Decimal.fromInt(100) / taxable)
      .toDecimal(scaleOnInfinitePrecision: 6);
  return percent.round();
}

/// The tax rate to print for a row, at the precision the portal and a reader
/// both expect.
///
/// A whole number for the standard bands, and one decimal only where the firm
/// genuinely files a fractional band (0.25% and the composition schemes), so
/// the return does not read `5.0%` where every CA writes `5%`.
String rateLabel(Decimal rate) {
  final onePlace = rate.round(scale: 1);
  if (onePlace == rate.round()) return rate.round().toStringAsFixed(0);
  return onePlace.toString();
}

/// **Whether this firm's books are GST-registered at all.**
///
/// Every GST report here answers a question the portal only asks a registered
/// person. For an unregistered dealer — which is most of the firms this app
/// serves — a GSTR-1 that totals outward supplies of ₹12,00,000 is not a
/// useful document, it is a filed liability. So each GST source checks this and
/// returns **no rows**, and its spec says why on the screen, rather than
/// printing a return nobody has to file.
Future<bool> firmIsGstRegistered(AppDatabase db, String firmId) async {
  final firm = await (db.select(db.firms)..where((f) => f.id.equals(firmId)))
      .getSingleOrNull();
  final gstin = (firm?.gstin ?? '').trim();
  // A GSTIN is 15 characters in a fixed shape; anything shorter is a firm that
  // never entered one, which is the answer this is asking for.
  return gstin.length >= 15;
}

/// The document's HSN/SAC code as a report cell.
///
/// **Blank is reported as `Not set`, never dropped.** An HSN summary is filed
/// against the portal's HSN/SAC master, and a line with no code is a line the
/// return cannot be filed against. Filing them all under one bucket would hide
/// the problem; naming them makes it a row somebody has to fix.
String hsnOrUnset(String? hsn) {
  final trimmed = (hsn ?? '').trim();
  return trimmed.isEmpty ? 'Not set' : trimmed;
}