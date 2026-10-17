// Not `show Value`: drift predicates live on extension types.
import 'package:atria/core/constants/payment_modes.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/tables/purchases.dart';
import 'package:atria/core/reports/engine/report_source.dart';
import 'package:atria/core/reports/spec/report_spec.dart';
import 'package:atria/core/reports/window/report_window.dart';
import 'package:drift/drift.dart' hide isNull;

/// The human label for a stored expense category id or legacy label.
///
/// Expenses saved by earlier builds or demo seeds may store the full human
/// label ("Internet & Telephone") instead of the id ("internet"). Resolving
/// both here ensures reports group and display them consistently.
String expenseCategoryLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'Miscellaneous';
  final byId = ExpenseCategory.byId(trimmed);
  if (byId != null) return byId.label;
  for (final c in ExpenseCategory.all) {
    if (c.label.toLowerCase() == trimmed.toLowerCase()) return c.label;
  }
  return trimmed;
}

/// The human label for a stored payment mode id.
String paymentModeLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return 'Cash';
  final byId = PaymentMode.byId(trimmed);
  if (byId != null) return byId.label;
  return trimmed;
}

/// The filter id for expense category filtering.
const String kExpenseCategoryFilterId = 'category';

/// Selected category id or label from [filters], or null for all categories.
String? selectedExpenseCategory(Map<String, Object?> filters) {
  final value = filters[kExpenseCategoryFilterId];
  if (value == null) return null;
  final s = '$value'.trim();
  return s.isEmpty ? null : s;
}

/// Options callback for expense reports that filter by category.
Future<List<ReportFilterOption<Object?>>> expenseCategoryOptions(
  AppDatabase db,
  String firmId,
  ReportSpec spec,
  String filterId,
) async {
  if (filterId != kExpenseCategoryFilterId) return const [];
  final rows =
      await (db.select(db.expenses)..where(
            (e) =>
                e.firmId.equals(firmId) &
                e.type.equals('expense') &
                e.isDeleted.equals(false),
          ))
          .get();
  final labels = <String>{
    for (final c in ExpenseCategory.all) c.label,
    for (final r in rows) expenseCategoryLabel(r.category),
  }.toList()..sort();
  return [
    for (final label in labels)
      ReportFilterOption<Object?>(value: label, label: label),
  ];
}

/// Predicate for live expense rows (excluding other income and soft-deleted rows)
/// within [window].
Expression<bool> liveExpensesIn(
  ReportWindow window,
  String firmId,
  Expenses expenses,
) =>
    expenses.firmId.equals(firmId) &
    expenses.type.equals('expense') &
    ReportFilters.notDeleted(expenses.isDeleted) &
    ReportFilters.within(expenses.date, window);
