import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/payment_modes.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/audit_repository.dart';
import '../../core/database/repositories/payment_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

/// The Date filter's window, shared by both tabs so switching between
/// Expenses and Other income never moves the window under the user.
final _rangeProvider = StateProvider<PeriodRange>(
  (ref) => PeriodRange(period: Period.thisMonth),
);

final _expenseRowsProvider = StreamProvider<List<ExpenseEntity>>((ref) {
  final repo = ref.watch(expenseRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseEntity>[]);
  final range = ref.watch(_rangeProvider);
  return repo.watchList(
    type: 'expense',
    from: range.from,
    to: range.to,
    limit: 1000,
  );
});

final _incomeRowsProvider = StreamProvider<List<ExpenseEntity>>((ref) {
  final repo = ref.watch(expenseRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseEntity>[]);
  final range = ref.watch(_rangeProvider);
  return repo.watchList(
    type: 'income',
    from: range.from,
    to: range.to,
    limit: 1000,
  );
});

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );
  final _searchController = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isExpenseTab => _tabController.index == 0;  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(expenseRepositoryProvider);
    final range = ref.watch(_rangeProvider);
    // The shared page frame — this screen used to centre an 840px column, so
    // its heading sat 182px right of the other lists' and its action button
    // 182px short of the right edge.
    return AtriaListPage(
      title: _isExpenseTab ? 'Expenses' : 'Other income',
      actions: [
        if (repo != null)
          AtriaPrimaryAction(
            label: _isExpenseTab ? 'Add expense' : 'Add income',
            // The type keeps the editor in income mode; without it the Other
            // Income tab opened an expense form.
            onPressed: () => context.push(
              '/expenses/new?type=${_isExpenseTab ? 'expense' : 'income'}',
            ),
          ),
      ],
      search: TransactionSearchField(
        controller: _searchController,
        hintText: _isExpenseTab
            ? 'Search vendor, category or amount…'
            : 'Search source, category or amount…',
        onChanged: (value) => setState(() => _search = value.trim()),
        onClear: () => setState(() {
          _searchController.clear();
          _search = '';
        }),
      ),
      // Was a TabBar in the app bar — the only tab strip left on a list screen
      // after Sales and Purchase moved to chips, so it reads as the same
      // control as every other screen now. The TabController still drives the
      // TabBarView below; the chips just move it.
      filters: [
        AtriaAdaptiveFilter<int>(
          label: 'Type',
          segments: const [
            AtriaSegment(value: 0, label: 'Expenses'),
            AtriaSegment(value: 1, label: 'Other income'),
          ],
          value: _tabController.index,
          onChanged: (index) => _tabController.animateTo(index),
        ),
        AtriaAdaptiveFilter<Period>(
          label: 'Date',
          segments: periodSegments(),
          value: range.period,
          onChanged: (period) {
            // Re-picking the current option must not re-run the query and
            // flash the loader.
            if (period == range.period) return;
            ref.read(_rangeProvider.notifier).state =
                range.withPeriod(period);
          },
        ),
        if (range.isCustom)
          PeriodCustomRange(
            range: range,
            onChanged: (next) =>
                ref.read(_rangeProvider.notifier).state = next,
          ),
      ],
      toolbar: repo == null ? const [] : [_summaryCard],
      body: repo == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No business open',
              message: 'Set up a firm in Settings to start recording '
                  'expenses.',
            )
          : TabBarView(
              controller: _tabController,
              children: [
                _list(isExpense: true),
                _list(isExpense: false),
              ],
            ),
    );
  }

  /// One card, ledger-first: the net figure leads, expenses and income follow
  /// — instead of three competing summary boxes.
  Widget get _summaryCard {
    final expenses = ref.watch(_expenseRowsProvider).valueOrNull ?? const [];
    final income = ref.watch(_incomeRowsProvider).valueOrNull ?? const [];
    final expenseTotal = _sum(expenses);
    final incomeTotal = _sum(income);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      child: TotalsCard(
        compact: true,
        title: 'Net P&L · ${ref.watch(_rangeProvider).label}',
        entries: [
          TotalsEntry(label: 'Net', amount: incomeTotal - expenseTotal),
          TotalsEntry(label: 'Expenses', amount: expenseTotal),
          TotalsEntry(label: 'Income', amount: incomeTotal),
        ],
      ),
    );
  }

  Decimal _sum(List<ExpenseEntity> rows) {
    var total = Decimal.zero;
    for (final row in rows) {
      total += Money.of(row.amount);
    }
    return total;
  }

  bool _matches(ExpenseEntity row, String q) {
    if (q.isEmpty) return true;
    final categoryLabel =
        _categoryLabel(row.category, isExpense: _isExpenseTab);
    // Also match the raw amount and a digit-stripped variant, so searching
    // "1,000" (grouped) and "1000" both find ₹1,000 entries.
    //
    // The numeric branch is gated on a non-empty digit-stripped query: an
    // empty string is a substring of every string, so searching "zzz" used to
    // match every row ("No matches" was unreachable for any text query).
    final amount = Money.of(row.amount);
    final rawAmount = row.amount.toStringAsFixed(2);
    final bareQuery = q.replaceAll(RegExp(r'[^\d.]'), '');
    final numericMatch = bareQuery.isNotEmpty &&
        (rawAmount.contains(bareQuery) ||
            Formatters.indianGroup(rawAmount).contains(bareQuery));
    return (row.vendorName ?? '').toLowerCase().contains(q) ||
        categoryLabel.toLowerCase().contains(q) ||
        (PaymentMode.byId(row.mode)?.label ?? row.mode)
            .toLowerCase()
            .contains(q) ||
        Formatters.money(amount).contains(q) ||
        numericMatch;
  }

  /// Centers [child] in the tab body, but lets it scroll when the viewport is
  /// too short to hold it — the empty state used to overflow by ~33px in a
  /// short window (the striped "RenderFlex overflowed" bar).
  Widget _centeredScrollable(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight:
                constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(child: child),
        ),
      ),
    );
  }

  Widget _list({required bool isExpense}) {
    final value =
        ref.watch(isExpense ? _expenseRowsProvider : _incomeRowsProvider);
    return value.when(
      data: (rows) {
        final q = _search.toLowerCase();
        final filtered =
            rows.where((row) => _matches(row, q)).toList(growable: false);
        if (filtered.isEmpty) {
          // Like the other lists: "nothing recorded" and "nothing inside this
          // window" are different facts, and the Date filter is the usual
          // reason a record the user knows exists is missing.
          final range = ref.watch(_rangeProvider);
          return _centeredScrollable(EmptyState(
            icon: q.isNotEmpty
                ? Icons.search_off_rounded
                : isExpense
                    ? Icons.payments_outlined
                    : Icons.savings_outlined,
            title: q.isNotEmpty
                ? 'No matches'
                : range.isAllTime
                    ? (isExpense
                        ? 'No expenses recorded'
                        : 'No other income recorded')
                    : 'Nothing in ${range.label}',
            message: q.isNotEmpty
                ? 'Nothing matches “$_search”. Try a vendor, category or '
                    'amount.'
                : range.isAllTime
                    ? (isExpense
                        ? 'Log rent, salaries, bills and day-to-day spending '
                            'to keep your profit and loss honest.'
                        : 'Log interest, discounts received and other '
                            'non-sales earnings here.')
                    : range.emptyWindowMessage(
                        isExpense ? 'expenses' : 'income entries'),
            actionLabel: q.isNotEmpty || !range.isAllTime
                ? null
                : isExpense
                    ? 'Add Expense'
                    : 'Add Income',
            onAction: q.isEmpty && range.isAllTime
                ? () => context.push(
                    '/expenses/new?type=${isExpense ? 'expense' : 'income'}')
                : null,
          ));
        }
        return Scrollbar(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
            itemCount: filtered.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _ExpenseRow(
              expense: filtered[index],
              treatAsOutflow: isExpense,
            ),
          ),
        );
      },
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (error, stackTrace) => _centeredScrollable(EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Could not load records',
        message: error.toString(),
      )),
    );
  }
}

class _ExpenseRow extends ConsumerWidget {
  const _ExpenseRow({required this.expense, required this.treatAsOutflow});

  final ExpenseEntity expense;
  final bool treatAsOutflow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(expenseRepositoryProvider);
    final categoryLabel =
        _categoryLabel(expense.category, isExpense: treatAsOutflow);
    final mode = PaymentMode.byId(expense.mode);
    // Expenses are shown as outflows so they render in the app's debit colour.
    final amount =
        treatAsOutflow ? -Money.of(expense.amount) : Money.of(expense.amount);

    return Dismissible(
      key: ValueKey<String>('${expense.type}-${expense.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.error,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child:
            Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.onError),
      ),
      // The write happens HERE, not in `onDismissed`.
      //
      // `onDismissed` runs after the row has already animated away, so a
      // failure there left the record in place and the row reappearing — the
      // user had swiped twice with no explanation. `confirmDismiss` decides
      // whether the row goes at all: true only once the record is in the bin.
      confirmDismiss: (direction) => _confirmAndDelete(context, repo),
      child: TransactionRow(
        // Tap opens the editor for this record — swipe still deletes.
        onTap: () =>
            context.push('/expenses/edit/${expense.id}?type=${expense.type}'),
        leading: LeadingGlyph(
          icon: _categoryIcon(expense.category),
          shape: BoxShape.rectangle,
        ),
        title: (expense.vendorName ?? '').trim().isNotEmpty
            ? expense.vendorName!
            : categoryLabel,
        subtitle: [
          categoryLabel,
          Formatters.date(expense.date),
          mode?.label ?? expense.mode,
        ].join('  ·  '),
        amount: amount,
        amountColorize: true,
        statusLabel: treatAsOutflow ? 'Expense' : 'Income',
        statusKind:
            treatAsOutflow ? ChipKind.danger : ChipKind.success,
        trailing: RowActionsButton(
          actions: [
            RowAction(
              label: 'Edit',
              icon: Icons.edit_outlined,
              onSelected: () => context.push(
                  '/expenses/edit/${expense.id}?type=${expense.type}'),
            ),
            RowAction(
              label: 'Delete',
              icon: Icons.delete_outline_rounded,
              destructive: true,
              // Async now, and the future is real: this used to be a
              // `VoidCallback`, so `await repo?.softDelete(...)` was dropped on
              // the floor and a `PeriodLockedException` surfaced nowhere.
              onSelected: () => _confirmAndDelete(context, repo),
            ),
          ],
        ),
      ),
    );
  }

  /// Confirms, then deletes. Returns whether the record is gone.
  ///
  /// Shared by the swipe and the kebab so the two paths cannot disagree — the
  /// kebab used to delete without awaiting and the swipe deleted after the row
  /// had gone. Returns false on refusal, on a missing repository, and on a
  /// failed write, so a `Dismissible` handed this never removes a row whose
  /// record is still there.
  Future<bool> _confirmAndDelete(
    BuildContext context,
    ExpenseRepository? repo,
  ) async {
    if (repo == null) return false;
    // Captured before the dialog: the `await` is an async gap, and a context
    // looked up afterwards can belong to a dead element.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await _confirmDelete(context, repo);
    if (confirmed != true || !context.mounted) return false;
    try {
      await repo.softDelete(expense.id);
      messenger?.showSnackBar(
        const SnackBar(content: Text('Moved to the recycle bin')),
      );
      return true;
    } on PeriodLockedException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
      return false;
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not delete: $error')),
      );
      return false;
    }
  }

  Future<bool?> _confirmDelete(BuildContext context, ExpenseRepository? repo) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this record?'),
        content: Text(
          '${Formatters.money(Money.of(expense.amount))} on '
          '${Formatters.date(expense.date)} moves to the recycle bin and '
          'can be restored from Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

String _categoryLabel(String id, {required bool isExpense}) {
  if (isExpense) {
    return ExpenseCategory.byId(id)?.label ?? id;
  }
  return IncomeCategory.byId(id)?.label ?? id;
}

IconData _categoryIcon(String id) => switch (id) {
      'rent' => Icons.home_work_outlined,
      'salary' => Icons.group_outlined,
      'electricity' => Icons.bolt_outlined,
      'water' => Icons.water_drop_outlined,
      'internet' => Icons.wifi_outlined,
      'transport' => Icons.local_shipping_outlined,
      'marketing' => Icons.campaign_outlined,
      'office' => Icons.inventory_outlined,
      'maintenance' => Icons.build_outlined,
      'bank_charges' => Icons.account_balance_outlined,
      'professional' => Icons.gavel_outlined,
      'tax' => Icons.receipt_long_outlined,
      'insurance' => Icons.shield_outlined,
      'interest' => Icons.savings_outlined,
      'discount' => Icons.local_offer_outlined,
      'commission' => Icons.handshake_outlined,
      'asset_sale' => Icons.domain_outlined,
      'refund' => Icons.undo_rounded,
      'misc' => Icons.category_outlined,
      'other' => Icons.receipt_outlined,
      _ => Icons.receipt_outlined,
    };
