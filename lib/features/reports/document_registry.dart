import 'package:flutter/widgets.dart';

import '../../core/reports/engine/report_result.dart';
import 'documents/balance_sheet_document.dart';
import 'documents/cash_flow_document.dart';
import 'documents/day_book_document.dart';
import 'documents/gstr1_document.dart';
import 'documents/gstr3b_document.dart';
import 'documents/gstr9_document.dart';
import 'documents/profit_and_loss_document.dart';
import 'documents/stock_detail_document.dart';
import 'documents/trial_balance_document.dart';

/// The bespoke body for a document-layout report, by catalogue id.
///
/// **A registry rather than a `switch`**, because each of the nine documents is
/// a separate file under `documents/`, added one commit at a time. A `switch`
/// would mean the screen grows with the library and every new report is a
/// change to the file that renders all of them. Here the screen never changes:
/// it asks for a builder by id and renders the column table when the answer is
/// null, which is the correct behaviour for a document that has not been lifted
/// out of the old dashboard yet.
///
/// **A table rather than self-registration.** Dart has no top-level statements,
/// so a document file cannot register itself on import without a lazy-final or a
/// `main()` — and a lazy static would mean a builder is missing until something
/// happens to touch it, which is a blank screen on one report and no error. The
/// map is exhaustive at compile time instead, and adding the tenth document is
/// one line here rather than one line in the file that renders all of them.
Widget? Function(BuildContext, ReportResult)? documentBuilderFor(String id) =>
    _builders[id];

final Map<String, Widget? Function(BuildContext, ReportResult)> _builders = {
  'profit_and_loss': buildProfitAndLoss,
  'trial_balance': buildTrialBalance,
  'balance_sheet': buildBalanceSheet,
  'cash_flow': buildCashFlow,
  'stock_detail': buildStockDetail,
  'gstr1': buildGstr1,
  'gstr3b': buildGstr3b,
  'gstr9': buildGstr9,
  'day_book': buildDayBook,
};
