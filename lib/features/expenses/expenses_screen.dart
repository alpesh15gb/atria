import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/payment_modes.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/payment_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

final _periodProvider = StateProvider<Period>((ref) => Period.thisMonth);

final _expenseRowsProvider = StreamProvider<List<ExpenseEntity>>((ref) {
  final repo = ref.watch(expenseRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseEntity>[]);
  return repo.watchList(
    type: 'expense',
    from: periodStart(ref.watch(_periodProvider)),
    limit: 1000,
  );
});

final _incomeRowsProvider = StreamProvider<List<ExpenseEntity>>((ref) {
  final repo = ref.watch(expenseRepositoryProvider);
  if (repo == null) return Stream.value(const <ExpenseEntity>[]);
  return repo.watchList(
    type: 'income',
    from: periodStart(ref.watch(_periodProvider)),
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

  bool get _isExpenseTab => _tabController.index == 0;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(expenseRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Expenses'),
            Tab(text: 'Other Income'),
          ],
        ),
      ),
      floatingActionButton: repo == null
          ? null
          : FloatingActionButton.extended(
              // The type keeps the editor in income mode; without it the Other
              // Income tab opened an expense form.
              onPressed: () => context.push(
                  '/expenses/new?type=${_isExpenseTab ? 'expense' : 'income'}'),
              icon: const Icon(Icons.add_rounded),
              label: Text(_isExpenseTab ? 'Add Expense' : 'Add Income'),
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 840,
                ),
                child: repo == null
                    ? const EmptyState(
                        icon: Icons.storefront_outlined,
                        title: 'No business open',
                        message: 'Set up a firm in Settings to start recording '
                            'expenses.',
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                            child: TransactionSearchField(
                              controller: _searchController,
                              hintText: _isExpenseTab
                                  ? 'Search vendor, category or amount…'
                                  : 'Search source, category or amount…',
                              onChanged: (value) =>
                                  setState(() => _search = value.trim()),
                              onClear: () => setState(() {
                                _searchController.clear();
                                _search = '';
                              }),
                            ),
                          ),
                          const SizedBox(height: 10),
                          PeriodPillRow(
                            value: ref.watch(_periodProvider),
                            onChanged: (period) =>
                                ref.read(_periodProvider.notifier).state =
                                    period,
                          ),
                          const SizedBox(height: 4),
                          _summaryCard,
                          const SizedBox(height: 10),
                          Expanded(
                            child: TabBarView(
                              controller: _tabController,
                              children: [
                                _list(isExpense: true),
                                _list(isExpense: false),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            );
          },
        ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: TotalsCard(
        compact: true,
        title: 'Net P&L · ${periodLabel(ref.watch(_periodProvider))}',
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
    final amount = Money.of(row.amount);
    final rawAmount = row.amount.toStringAsFixed(2);
    final bareAmount = rawAmount.replaceAll(RegExp(r'[^\d.]'), '');
    final bareQuery = q.replaceAll(RegExp(r'[^\d.]'), '');
    return (row.vendorName ?? '').toLowerCase().contains(q) ||
        categoryLabel.toLowerCase().contains(q) ||
        (PaymentMode.byId(row.mode)?.label ?? row.mode)
            .toLowerCase()
            .contains(q) ||
        Formatters.money(amount).contains(q) ||
        rawAmount.contains(bareQuery) ||
        (bareQuery.isNotEmpty && bareAmount.contains(bareQuery)) ||
        (q.contains(',') &&
            Formatters.indianGroup(rawAmount).contains(q));
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
          return EmptyState(
            icon: q.isNotEmpty
                ? Icons.search_off_rounded
                : isExpense
                    ? Icons.payments_outlined
                    : Icons.savings_outlined,
            title: q.isNotEmpty
                ? 'No matches'
                : isExpense
                    ? 'No expenses recorded'
                    : 'No other income recorded',
            message: q.isNotEmpty
                ? 'Nothing matches “$_search”. Try a vendor, category or '
                    'amount.'
                : isExpense
                    ? 'Log rent, salaries, bills and day-to-day spending to '
                        'keep your profit and loss honest.'
                    : 'Log interest, discounts received and other non-sales '
                        'earnings here.',
            actionLabel: q.isNotEmpty
                ? null
                : isExpense
                    ? 'Add Expense'
                    : 'Add Income',
            onAction: q.isEmpty
                ? () => context.push(
                    '/expenses/new?type=${isExpense ? 'expense' : 'income'}')
                : null,
          );
        }
        return Scrollbar(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
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
      error: (error, stackTrace) => EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Could not load records',
        message: error.toString(),
      ),
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
      confirmDismiss: (direction) => _confirmDelete(context, repo),
      onDismissed: (direction) async {
        try {
          await repo?.softDelete(expense.id);
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not delete: $e')),
          );
        }
      },
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
              onSelected: () async {
                final ok = await _confirmDelete(context, repo);
                if (ok == true) await repo?.softDelete(expense.id);
              },
            ),
          ],
        ),
      ),
    );
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
