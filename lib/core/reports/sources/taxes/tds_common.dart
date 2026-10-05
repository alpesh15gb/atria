// Not `show Value` and not `hide isNull`: the `&` operators below live on
// drift's expression extension types, and a narrowed import drops them.
import 'package:atria/core/database/tables/purchases.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;

import '../transaction/transaction_common.dart';

/// The TDS/TCS reports' shared reading rules.
///
/// **Every TDS and TCS field on a document is snapshotted, never re-derived,
/// and these helpers exist to keep it that way.** The section (192, 194, 195…)
/// depends on what the payment was *for*, the rate is snapshotted beside the
/// section rate for a partly exempt bill, and the deductee's PAN is a fact about
/// the bill as filed. Deriving any of them at report time produces a return that
/// disagrees with the document: a 26Q filed against a guessed PAN is a notice,
/// and a mid-term rate change must not rewrite what a February repayment was
/// worth.
///
/// What these helpers *do* is present the snapshot honestly — including when it
/// is missing, which is the case a 26Q has to show rather than hide.
class TdsCommon {
  TdsCommon._();

  /// The section as a report cell.
  ///
  /// A bill that carried a deduction with no section recorded is reported as
  /// **`Not recorded`**, not as an empty cell and not as a guessed section. A
  /// 26Q line with a blank section cannot be filed, and the reader needs to see
  /// that it is *their* missing field rather than a blank the report produced.
  static String sectionOrUnset(String? section) {
    final trimmed = (section ?? '').trim();
    return trimmed.isEmpty ? 'Not recorded' : trimmed;
  }

  /// The PAN as a report cell, same reasoning as [sectionOrUnset].
  static String panOrUnset(String? pan) {
    final trimmed = (pan ?? '').trim();
    return trimmed.isEmpty ? 'Not recorded' : trimmed;
  }

  /// The rate a deduction was worked out at, preferring the section rate.
  ///
  /// **The section rate wins** because it is what was actually applied to this
  /// bill's taxable value; the document-level `tdsRate` is the rate the editor
  /// was working from and can differ on a partly exempt bill.
  static Decimal rateOf({required double tdsRate, required double sectionRate}) =>
      sectionRate > 0 ? dec(sectionRate) : dec(tdsRate);

  /// Every purchase document that carried a deduction in [window].
  ///
  /// **One predicate for "had TDS", so all three TDS reports agree on which
  /// bills are in scope.** Each report writing its own filter is how the 27EQ
  /// and the TDS Payable come to list different bills — and a quarter's
  /// deduction appearing in one return and not the other is the kind of
  /// difference a CA asks about.
  static Expression<bool> hasTds(PurchaseBills bills) =>
      bills.tds.isBiggerThanValue(0);
}

/// The purchase-side scope every TDS report reads: bills and debit notes,
/// live, in the window.
Expression<bool> tdsScope(
  ReportWindow window,
  String firmId,
  PurchaseBills bills,
) =>
    bills.firmId.equals(firmId) &
    bills.docType.isIn(kPurchaseDocTypes) &
    ReportFilters.isLive(status: bills.status, isDeleted: bills.isDeleted) &
    ReportFilters.within(bills.billDate, window);