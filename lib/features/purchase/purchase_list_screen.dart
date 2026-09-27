import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/purchase_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

class PurchaseListScreen extends ConsumerStatefulWidget {
  const PurchaseListScreen({super.key});

  @override
  ConsumerState<PurchaseListScreen> createState() =>
      _PurchaseListScreenState();
}

class _PurchaseListScreenState extends ConsumerState<PurchaseListScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  Period _period = Period.thisMonth;
  String _search = '';
  Timer? _debounce;

  static const _docTypes = ['bill', 'debit_note'];

  late final TabController _tabController =
      TabController(length: _docTypes.length, vsync: this);

  @override
  void initState() {
    super.initState();
    _tabController.addListener(() {
      // The stream is cached per docType; re-key it when the tab changes.
      if (!_tabController.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _tabController.dispose();
    super.dispose();
  }

  String get _activeDocType => _docTypes[_tabController.index];
  bool get _isDebitTab => _activeDocType == 'debit_note';

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      setState(() => _search = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(purchaseRepositoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Purchase'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Bills'),
            Tab(text: 'Debit Notes'),
          ],
        ),
      ),
      floatingActionButton: repo == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () =>
                  context.push('/purchase/new?type=$_activeDocType'),
              icon: const Icon(Icons.add_rounded),
              label: Text(_isDebitTab ? 'New Debit Note' : 'Add Bill'),
            ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 1100,
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: TransactionSearchField(
                        controller: _searchController,
                        hintText: 'Search supplier, bill or invoice no.',
                        onChanged: _onSearchChanged,
                        onClear: () {
                          _searchController.clear();
                          _searchFocus.unfocus();
                          setState(() => _search = '');
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    PeriodPillRow(
                      value: _period,
                      onChanged: (period) => setState(() => _period = period),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: repo == null
                          ? const EmptyState(
                              icon: Icons.storefront_outlined,
                              title: 'No business open',
                              message: 'Set up a firm in Settings to start '
                                  'recording purchase bills.',
                            )
                          : TabBarView(
                              controller: _tabController,
                              children: [
                                for (final _ in _docTypes) _area(repo),
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

  Stream<List<PurchaseBillEntity>>? _stream;
  String? _streamKey;
  PurchaseRepository? _streamRepo;

  Stream<List<PurchaseBillEntity>> _streamFor(PurchaseRepository repo) {
    final key = '${_period.name}-$_activeDocType';
    if (_stream == null || _streamKey != key || _streamRepo != repo) {
      _streamKey = key;
      _streamRepo = repo;
      _stream = repo.watchList(
        docType: _activeDocType,
        from: periodStart(_period),
        limit: 1000,
      );
    }
    return _stream!;
  }

  List<PurchaseBillEntity> _applySearch(
      List<PurchaseBillEntity> bills, String search) {
    if (search.isEmpty) return bills;
    final q = search.toLowerCase();
    return bills
        .where((bill) =>
            bill.number.toLowerCase().contains(q) ||
            (bill.partyName ?? '').toLowerCase().contains(q) ||
            (bill.supplierInvoiceNumber ?? '').toLowerCase().contains(q))
        .toList(growable: false);
  }

  Widget _area(PurchaseRepository repo) {
    return StreamBuilder<List<PurchaseBillEntity>>(
      stream: _streamFor(repo),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load bills',
            message: '${snapshot.error}',
          );
        }

        final all = snapshot.data ?? const <PurchaseBillEntity>[];
        final bills = _applySearch(all, _search);
        final stats = _statsOf(all);
        if (bills.isEmpty) {
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TotalsCard(
                    compact: true,
                    title: _isDebitTab ? 'Total Returned' : 'Total Purchases',
                    entries: [
                      TotalsEntry(label: 'Total', amount: stats.purchases),
                      TotalsEntry(label: 'Payable', amount: stats.payable),
                    ],
                  ),
                ),
              ),
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: _search.isEmpty
                      ? Icons.shopping_cart_checkout_rounded
                      : Icons.search_off_rounded,
                  title: _search.isEmpty
                      ? (_isDebitTab ? 'No debit notes' : 'No purchase bills')
                      : 'No matches',
                  message: _search.isEmpty
                      ? 'Record your first purchase bill to track stock and '
                          'payables.'
                      : 'Nothing matches “$_search”. Try a different supplier '
                          'or bill number.',
                  actionLabel: _search.isEmpty
                      ? (_isDebitTab ? 'Add Debit Note' : 'Add Bill')
                      : null,
                  onAction: _search.isEmpty
                      ? () =>
                          context.push('/purchase/new?type=$_activeDocType')
                      : null,
                ),
              ),
            ],
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) => constraints.isCompact
              ? _cardList(bills, stats)
              : _tableList(bills, stats),
        );
      },
    );
  }

  Widget _cardList(List<PurchaseBillEntity> bills, _BillStats stats) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        TotalsCard(
          compact: true,
          title: _isDebitTab ? 'Total Returned' : 'Total Purchases',
          entries: [
            TotalsEntry(label: 'Total', amount: stats.purchases),
            TotalsEntry(label: 'Payable', amount: stats.payable),
          ],
        ),
        const SizedBox(height: 12),
        for (final bill in bills)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PurchaseRow(bill: bill, docType: _activeDocType),
          ),
      ],
    );
  }

  Widget _tableList(List<PurchaseBillEntity> bills, _BillStats stats) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        TotalsCard(
          compact: true,
          title: _isDebitTab ? 'Total Returned' : 'Total Purchases',
          entries: [
            TotalsEntry(label: 'Total', amount: stats.purchases),
            TotalsEntry(label: 'Payable', amount: stats.payable),
          ],
        ),
        const SizedBox(height: 14),
        SectionHeader(
          title: 'Transactions',
          actionLabel: '${bills.length} shown',
        ),
        const SizedBox(height: 6),
        TransactionTableHeader(
          columns: TransactionColumns(
            date: 'Date',
            number: 'Bill no.',
            party: 'Supplier',
            detail: 'Ref',
            amount: 'Amount',
            balance: 'Balance',
          ),
          trailing: const SizedBox(width: 36),
        ),
        for (final bill in bills)
          _PurchaseTableRow(bill: bill, docType: _activeDocType),
      ],
    );
  }

  _BillStats _statsOf(List<PurchaseBillEntity> bills) {
    var purchases = Decimal.zero;
    var payable = Decimal.zero;
    for (final bill in bills) {
      if (bill.status == 'cancelled') continue;
      purchases += Money.of(bill.grandTotal);
      payable += Money.of(bill.balanceDue);
    }
    return _BillStats(purchases: purchases, payable: payable);
  }
}

class _BillStats {
  const _BillStats({required this.purchases, required this.payable});

  final Decimal purchases;
  final Decimal payable;
}

IconData _docIcon(String docType) => switch (docType) {
      'debit_note' => Icons.assignment_return_outlined,
      _ => Icons.local_shipping_rounded,
    };

String? _statusText(PurchaseBillEntity bill) {
  if (bill.status == 'cancelled') return 'Cancelled';
  return null;
}

class _PurchaseRow extends ConsumerWidget {
  const _PurchaseRow({required this.bill, required this.docType});


  final PurchaseBillEntity bill;
  final String docType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDebit = docType == 'debit_note';
    return TransactionRow(
      leading: LeadingGlyph(icon: _docIcon(docType)),
      title: bill.partyName ?? 'Unknown supplier',
      subtitle: _subtitle,
      amount: Money.of(bill.grandTotal),
      amountColorize: false,
      statusLabel: _statusText(bill) ?? _paymentLabel,
      statusKind: bill.status == 'cancelled'
          ? ChipKind.danger
          : _paymentKind,
      dimmed: bill.status == 'cancelled',
      onTap: () =>
          context.push('/purchase/edit/${bill.id}?type=$docType'),
      trailing: RowActionsButton(
        actions: [
          RowAction(
            label: isDebit ? 'Edit debit note' : 'Edit bill',
            icon: Icons.edit_outlined,
            onSelected: () =>
                context.push('/purchase/edit/${bill.id}?type=$docType'),
          ),
          RowAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () async {
              final ok = await _confirmDelete(context, bill.number);
              if (ok == true) {
                try {
                  await ref
                      .read(purchaseRepositoryProvider)
                      ?.softDelete(bill.id);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not delete: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  String get _paymentLabel => switch (bill.paymentStatus) {
        'paid' => 'Paid',
        'partial' => 'Partial',
        _ => 'Unpaid',
      };

  ChipKind get _paymentKind => switch (bill.paymentStatus) {
        'paid' => ChipKind.success,
        'partial' => ChipKind.warning,
        _ => ChipKind.neutral,
      };

  String get _subtitle {
    final parts = <String>[bill.number];
    if ((bill.supplierInvoiceNumber ?? '').trim().isNotEmpty) {
      parts.add('SI ${bill.supplierInvoiceNumber}');
    }
    return parts.join('  ·  ');
  }
}

class _PurchaseTableRow extends ConsumerWidget {
  const _PurchaseTableRow({required this.bill, required this.docType});

  final PurchaseBillEntity bill;
  final String docType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TransactionTableRow(
      onTap: () =>
          context.push('/purchase/edit/${bill.id}?type=$docType'),
      leading: LeadingGlyph(icon: _docIcon(docType)),
      date: Formatters.date(bill.billDate),
      number: bill.number,
      party: bill.partyName ?? 'Unknown supplier',
      detail: (bill.supplierInvoiceNumber ?? '').trim().isNotEmpty
          ? 'SI ${bill.supplierInvoiceNumber}'
          : '—',
      amount: Money.of(bill.grandTotal),
      amountColorize: false,
      balance: Money.of(bill.balanceDue),
      statusLabel: _statusText(bill) ?? _paymentLabel,
      statusKind:
          bill.status == 'cancelled' ? ChipKind.danger : _paymentKind,
      trailing: RowActionsButton(
        actions: [
          RowAction(
            label: docType == 'debit_note' ? 'Edit debit note' : 'Edit bill',
            icon: Icons.edit_outlined,
            onSelected: () =>
                context.push('/purchase/edit/${bill.id}?type=$docType'),
          ),
          RowAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () async {
              final ok = await _confirmDelete(context, bill.number);
              if (ok == true) {
                try {
                  await ref
                      .read(purchaseRepositoryProvider)
                      ?.softDelete(bill.id);
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Could not delete: $e')),
                  );
                }
              }
            },
          ),
        ],
      ),
      dimmed: bill.status == 'cancelled',
    );
  }

  String get _paymentLabel => switch (bill.paymentStatus) {
        'paid' => 'Paid',
        'partial' => 'Partial',
        _ => 'Unpaid',
      };

  ChipKind get _paymentKind => switch (bill.paymentStatus) {
        'paid' => ChipKind.success,
        'partial' => ChipKind.warning,
        _ => ChipKind.neutral,
      };
}

/// Confirmation used by both row variants before a soft delete.
Future<bool?> _confirmDelete(BuildContext context, String number) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Delete $number?'),
      content: const Text(
          'Stock received is reversed. The bill moves to the recycle bin '
          'and can be restored from Settings.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            foregroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
}
