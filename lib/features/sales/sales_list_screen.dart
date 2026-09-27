import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/sales_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

class SalesListScreen extends ConsumerStatefulWidget {
  const SalesListScreen({super.key});

  @override
  ConsumerState<SalesListScreen> createState() => _SalesListScreenState();
}

class _SalesListScreenState extends ConsumerState<SalesListScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();
  String _search = '';
  Period _period = Period.thisMonth;
  Timer? _searchDebounce;

  // The FAB reads this instead of _tabController.index: after swiping tabs
  // the FAB only rebuilds when something calls setState, so it kept the old
  // doc type's label and created the wrong document on tap.
  int _activeTabIndex = 0;

  String get _activeDocType => _docTypes[_activeTabIndex];

  static const _docTypes = [
    'invoice',
    'quotation',
    'sales_order',
    'delivery_note',
    'credit_note',
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _docTypes.length, vsync: this);
    _tabController.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabController.index == _activeTabIndex &&
        !_tabController.indexIsChanging) {
      return;
    }
    setState(() => _activeTabIndex = _tabController.index);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sales = ref.watch(salesRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(text: 'Invoices'),
            Tab(text: 'Quotations'),
            Tab(text: 'Sales Orders'),
            Tab(text: 'Delivery Notes'),
            Tab(text: 'Credit Notes'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/sales/new?type=$_activeDocType'),
        icon: const Icon(Icons.add_rounded),
        // Label follows the active tab — on Quotations the button used to
        // still read "New Invoice", which read as a bug.
        label: Text(switch (_activeDocType) {
          'quotation' => 'New Quotation',
          'sales_order' => 'New Order',
          'delivery_note' => 'New Delivery Note',
          'credit_note' => 'New Credit Note',
          _ => 'New Invoice',
        }),
      ),
      body: sales == null
          ? EmptyState(
              icon: PhosphorIconsRegular.receipt,
              title: 'No business selected',
              message: 'Choose or create a business to start selling.',
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: TransactionSearchField(
                    controller: _searchController,
                    hintText: 'Search invoice or party…',
                    onChanged: (value) {
                      // Debounced: rebuilding per keystroke re-subscribed the
                      // whole list stream on every letter, flashing the loader.
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(const Duration(milliseconds: 250), () {
                        if (mounted) setState(() => _search = value);
                      });
                    },
                    onClear: () => setState(() {
                      _searchController.clear();
                      _search = '';
                    }),
                  ),
                ),
                const SizedBox(height: 10),
                PeriodPillRow(
                  value: _period,
                  onChanged: (period) => setState(() => _period = period),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      for (var i = 0; i < _docTypes.length; i++)
                        _SaleList(
                          docType: _docTypes[i],
                          search: _search,
                          from: periodStart(_period),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _SaleList extends ConsumerStatefulWidget {
  const _SaleList({
    required this.docType,
    required this.search,
    this.from,
  });

  final String docType;
  final String search;
  final DateTime? from;

  @override
  ConsumerState<_SaleList> createState() => _SaleListState();
}

class _SaleListState extends ConsumerState<_SaleList> {
  // One stream per (docType, search, from), kept across rebuilds — the old
  // code constructed a fresh stream inside build, tearing down and
  // re-subscribing the drift watch on every parent setState (per keystroke).
  final Map<String, Stream<List<SalesInvoiceEntity>>> _streams = {};

  Stream<List<SalesInvoiceEntity>> _streamFor(SalesRepository? sales) {
    if (sales == null) return const Stream.empty();
    final key =
        '${widget.docType}|${widget.search}|${widget.from?.microsecondsSinceEpoch ?? 0}';
    return _streams.putIfAbsent(key, () {
      return sales.watchList(
        docType: widget.docType,
        search: widget.search,
        from: widget.from,
        limit: 200,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sales = ref.watch(salesRepositoryProvider);
    if (sales == null) return const SizedBox.shrink();

    return StreamBuilder<List<SalesInvoiceEntity>>(
      stream: _streamFor(sales),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        final data = snapshot.data ?? const [];
        if (data.isEmpty) {
          final query = widget.search.trim();
          if (query.isNotEmpty) {
            // A search matching nothing is "no matches", not "no documents
            // yet" — the old empty state invited the user to create their
            // first invoice while they were only searching.
            return EmptyState(
              icon: PhosphorIconsRegular.magnifyingGlass,
              title: 'No matches for “$query”',
              message:
                  'Try a different name or number, or clear the search to see '
                  'all ${_emptyTitle.toLowerCase()}.',
            );
          }
          return EmptyState(
            icon: PhosphorIconsRegular.receipt,
            title: _emptyTitle,
            message: _emptyMessage,
            actionLabel: _actionLabel,
            onAction: () => context.push('/sales/new?type=${widget.docType}'),
          );
        }

        return LayoutBuilder(
          builder: (context, constraints) => constraints.isCompact
              ? _cardList(context, data)
              : _tableList(context, data),
        );
      },
    );
  }

  Widget _cardList(BuildContext context, List<SalesInvoiceEntity> data) {
    final stats = _statsOf(data);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        _TotalsSection(docType: widget.docType, stats: stats),
        const SizedBox(height: 12),
        for (final invoice in data)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SaleRow(
              invoice: invoice,
              docType: widget.docType,
              showDate: true,
            ),
          ),
      ],
    );
  }

  Widget _tableList(BuildContext context, List<SalesInvoiceEntity> data) {
    final stats = _statsOf(data);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      children: [
        _TotalsSection(docType: widget.docType, stats: stats),
        const SizedBox(height: 14),
        SectionHeader(
          title: 'Transactions',
          actionLabel: '${data.length} shown',
        ),
        const SizedBox(height: 6),
        TransactionTableHeader(
          columns: const TransactionColumns(
            date: 'Date',
            number: 'No.',
            party: 'Party',
            detail: 'Status',
            amount: 'Amount',
            balance: 'Balance',
          ),
          trailing: const SizedBox(width: 36),
        ),
        for (final invoice in data)
          _SaleTableRow(
            invoice: invoice,
            docType: widget.docType,
          ),
      ],
    );
  }

  _SaleStats _statsOf(List<SalesInvoiceEntity> data) {
    var total = Decimal.zero;
    var received = Decimal.zero;
    var balance = Decimal.zero;
    var count = 0;
    for (final doc in data) {
      if (doc.status == 'cancelled') continue;
      count++;
      total += Money.of(doc.grandTotal);
      received += Money.of(doc.paidAmount);
      balance += Money.of(doc.balanceDue);
    }
    return _SaleStats(
      total: total,
      received: received,
      balance: balance,
      count: count,
    );
  }

  String get _emptyTitle {
    switch (widget.docType) {
      case 'quotation':
        return 'No quotations yet';
      case 'sales_order':
        return 'No sales orders yet';
      default:
        return 'No invoices yet';
    }
  }

  String get _emptyMessage {
    switch (widget.docType) {
      case 'quotation':
        return 'Create a quotation to share an estimate with your customers.';
      case 'sales_order':
        return 'Track confirmed orders before you ship them.';
      default:
        return 'Create your first GST invoice — it takes under a minute.';
    }
  }

  String get _actionLabel {
    switch (widget.docType) {
      case 'quotation':
        return 'New quotation';
      case 'sales_order':
        return 'New sales order';
      default:
        return 'New invoice';
    }
  }
}

class _SaleStats {
  const _SaleStats({
    required this.total,
    required this.received,
    required this.balance,
    required this.count,
  });

  final Decimal total;
  final Decimal received;
  final Decimal balance;
  final int count;
}

/// The one-card summary. Invoices show the money breakdown the way the
/// desktop suites do (total, received, balance); the document-only tabs
/// (quotation, order, note) show just the period total and a count.
class _TotalsSection extends StatelessWidget {
  const _TotalsSection({required this.docType, required this.stats});

  final String docType;
  final _SaleStats stats;

  @override
  Widget build(BuildContext context) {
    if (docType == 'invoice') {
      return TotalsCard(
        compact: true,
        title: 'Total Sales Amount',
        entries: [
          TotalsEntry(label: 'Total', amount: stats.total),
          TotalsEntry(label: 'Received', amount: stats.received),
          TotalsEntry(label: 'Balance', amount: stats.balance),
        ],
      );
    }
    return TotalsCard(
      compact: true,
      title: _title,
      entries: [
        TotalsEntry(label: 'Total', amount: stats.total),
        TotalsEntry(label: 'Documents', amount: Decimal.fromInt(stats.count)),
      ],
    );
  }

  String get _title => switch (docType) {
        'quotation' => 'Total Quoted Amount',
        'sales_order' => 'Total Ordered Amount',
        'delivery_note' => 'Delivery Notes',
        'credit_note' => 'Total Credited',
        _ => 'Total Sales Amount',
      };
}

IconData _docIcon(String docType) => switch (docType) {
      'quotation' => Icons.request_quote_outlined,
      'sales_order' => Icons.shopping_bag_outlined,
      'delivery_note' => Icons.local_shipping_outlined,
      'credit_note' => Icons.assignment_return_outlined,
      _ => Icons.receipt_long_outlined,
    };

String? _statusText(SalesInvoiceEntity doc) {
  if (doc.status == 'converted') return 'Converted';
  if (doc.status == 'cancelled') return 'Cancelled';
  if (doc.status == 'confirmed' || doc.status == 'draft') {
    return doc.status == 'confirmed' ? 'Confirmed' : 'Draft';
  }
  return null;
}

class _SaleRow extends ConsumerWidget {
  const _SaleRow({
    required this.invoice,
    required this.docType,
    this.showDate = false,
  });

  final SalesInvoiceEntity invoice;
  final String docType;
  final bool showDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConvertible =
        (docType == 'quotation' || docType == 'sales_order') &&
            invoice.status != 'converted' &&
            invoice.status != 'cancelled';

    return TransactionRow(
      leading: LeadingGlyph(icon: _docIcon(docType)),
      title: invoice.partyName ?? 'Walk-in customer',
      subtitle: _subtitle,
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      statusLabel: _statusText(invoice) ?? _paymentLabel,
      statusKind: _statusKind,
      dimmed: invoice.status == 'cancelled',
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      trailing: RowActionsButton(
        actions: [
          RowAction(
            label: 'Edit',
            icon: Icons.edit_outlined,
            onSelected: () => context
                .push('/sales/edit/${invoice.id}?type=$docType'),
          ),
          if (isConvertible)
            RowAction(
              label: 'Convert to invoice',
              icon: Icons.receipt_long_outlined,
              onSelected: () => context.push(
                  '/sales/new?type=invoice&from=${invoice.id}'),
            ),
          RowAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text('Delete ${invoice.number}?'),
                  content: const Text(
                      'Stock and balances are reversed. The document moves '
                      'to the recycle bin and can be restored from '
                      'Settings.'),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        foregroundColor:
                            Theme.of(dialogContext).colorScheme.error,
                      ),
                      onPressed: () =>
                          Navigator.of(dialogContext).pop(true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                try {
                  await ref
                      .read(salesRepositoryProvider)
                      ?.softDelete(invoice.id);
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

  String get _paymentLabel => switch (invoice.paymentStatus) {
        'paid' => 'Paid',
        'partial' => 'Partial',
        _ => 'Unpaid',
      };

  ChipKind get _statusKind {
    if (invoice.status == 'cancelled') return ChipKind.danger;
    if (invoice.status == 'converted') return ChipKind.info;
    if (_paymentLabel == 'Paid') return ChipKind.success;
    if (_paymentLabel == 'Partial') return ChipKind.warning;
    return ChipKind.neutral;
  }

  String get _subtitle {
    final parts = <String>[invoice.number];
    if (showDate) parts.add(Formatters.date(invoice.invoiceDate));
    if (invoice.isInterState && (invoice.partyGstin ?? '').isNotEmpty) {
      parts.add(
          'Inter-state · ${IndianStates.byCode(invoice.placeOfSupply)?.name ?? ''}');
    }
    return parts.join('  ·  ');
  }
}

class _SaleTableRow extends ConsumerWidget {
  const _SaleTableRow({required this.invoice, required this.docType});

  final SalesInvoiceEntity invoice;
  final String docType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConvertible =
        (docType == 'quotation' || docType == 'sales_order') &&
            invoice.status != 'converted' &&
            invoice.status != 'cancelled';

    return TransactionTableRow(
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      leading: LeadingGlyph(icon: _docIcon(docType)),
      date: Formatters.date(invoice.invoiceDate),
      number: invoice.number,
      party: invoice.partyName ?? 'Walk-in customer',
      detail: _statusText(invoice) ?? _paymentLabel,
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      balance: Money.of(invoice.balanceDue),
      statusLabel: _statusText(invoice) ?? _paymentLabel,
      statusKind: _statusKind,
      trailing: RowActionsButton(
        actions: [
          RowAction(
            label: 'Edit',
            icon: Icons.edit_outlined,
            onSelected: () =>
                context.push('/sales/edit/${invoice.id}?type=$docType'),
          ),
          if (isConvertible)
            RowAction(
              label: 'Convert to invoice',
              icon: Icons.receipt_long_outlined,
              onSelected: () =>
                  context.push('/sales/new?type=invoice&from=${invoice.id}'),
            ),
          RowAction(
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            destructive: true,
            onSelected: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text('Delete ${invoice.number}?'),
                  content: const Text(
                      'Stock and balances are reversed. The document moves '
                      'to the recycle bin and can be restored from '
                      'Settings.'),
                  actions: [
                    TextButton(
                      onPressed: () =>
                          Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        foregroundColor:
                            Theme.of(dialogContext).colorScheme.error,
                      ),
                      onPressed: () =>
                          Navigator.of(dialogContext).pop(true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                try {
                  await ref
                      .read(salesRepositoryProvider)
                      ?.softDelete(invoice.id);
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
      dimmed: invoice.status == 'cancelled',
    );
  }

  String get _paymentLabel => switch (invoice.paymentStatus) {
        'paid' => 'Paid',
        'partial' => 'Partial',
        _ => 'Unpaid',
      };

  ChipKind get _statusKind {
    if (invoice.status == 'cancelled') return ChipKind.danger;
    if (invoice.status == 'converted') return ChipKind.info;
    if (_paymentLabel == 'Paid') return ChipKind.success;
    if (_paymentLabel == 'Partial') return ChipKind.warning;
    return ChipKind.neutral;
  }
}
