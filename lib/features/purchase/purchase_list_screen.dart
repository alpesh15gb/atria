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
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/document_row_menu.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

class PurchaseListScreen extends ConsumerStatefulWidget {
  const PurchaseListScreen({super.key, this.initialType});

  /// `?type=` from the rail's Purchase dropdown ('debit_note').
  /// Null/anything else = bills.
  final String? initialType;

  @override
  ConsumerState<PurchaseListScreen> createState() => _PurchaseListScreenState();
}

class _PurchaseListScreenState extends ConsumerState<PurchaseListScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  PeriodRange _range = PeriodRange(period: Period.thisMonth);
  String _search = '';
  Timer? _debounce;

  /// The document type this list shows, read from the route on **every**
  /// build rather than latched into a field.
  ///
  /// `StatefulShellRoute.indexedStack` keeps each branch's navigator alive, so
  /// `/purchase?type=debit_note` → `/purchase?type=bill` resolves to this same
  /// State. Seeding a `late` field from `initialType` wrote it once per
  /// session, which pinned the heading, the pills and the action button to
  /// whichever type the rail was first opened on — the same "everything says
  /// one type until restart" bug the Sales list had.
  String get _activeDocType => switch (widget.initialType) {
        'debit_note' => 'debit_note',
        'purchase_order' => 'purchase_order',
        _ => 'bill',
      };

  bool get _isOrderTab => _activeDocType == 'purchase_order';

  /// Singular name of what this screen lists, for the search placeholder.
  /// It used to say "bill" on every one of the three.
  String get _activeDocNoun => switch (_activeDocType) {
    'debit_note' => 'debit note',
    'purchase_order' => 'purchase order',
    _ => 'bill',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

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
    // The shared page frame: the same gutter, heading and toolbar rhythm as
    // Sales, Items and Parties. This screen used to centre a 1100px column
    // inside the body, which put its heading 52px right of every other list's
    // and its action button 72px short of the right edge.
    return AtriaListPage(
      title: switch (_activeDocType) {
        'debit_note' => 'Debit notes',
        'purchase_order' => 'Purchase orders',
        _ => 'Bills',
      },
      actions: [
        if (repo != null && _activeDocType == 'bill')
          // Scan sits next to Add on bills only: orders and returns are
          // constructed, not photographed.
          AtriaPrimaryAction(
            label: 'Scan bill',
            icon: Icons.document_scanner_outlined,
            onPressed: () => context.push('/purchase/scan'),
          ),
        if (repo != null)
          AtriaPrimaryAction(
            label: switch (_activeDocType) {
              'debit_note' => 'New debit note',
              'purchase_order' => 'New purchase order',
              _ => 'Add bill',
            },
            onPressed: () => context.push('/purchase/new?type=$_activeDocType'),
          ),
      ],
      search: TransactionSearchField(
        controller: _searchController,
        hintText: 'Search supplier, $_activeDocNoun or number…',
        onChanged: _onSearchChanged,
        onClear: () {
          _searchController.clear();
          _searchFocus.unfocus();
          setState(() => _search = '');
        },
      ),
      filters: [
        AtriaAdaptiveFilter<String>(
          label: 'Type',
          segments: const [
            AtriaSegment(value: 'bill', label: 'Bills'),
            AtriaSegment(value: 'purchase_order', label: 'Purchase orders'),
            AtriaSegment(value: 'debit_note', label: 'Debit notes'),
          ],
          value: _activeDocType,
          // `go`, not `setState` — the type lives in the URL, so changing it
          // here has to write it back, or the next router-driven rebuild
          // restores the type the rail is pointing at.
          onChanged: (value) => context.go('/purchase?type=$value'),
        ),
        AtriaAdaptiveFilter<Period>(
          label: 'Date',
          segments: periodSegments(),
          value: _range.period,
          onChanged: (period) =>
              setState(() => _range = _range.withPeriod(period)),
        ),
        // A custom window needs its two days on screen; the named ones show
        // the window in the select itself.
        if (_range.isCustom)
          PeriodCustomRange(
            range: _range,
            onChanged: (range) => setState(() => _range = range),
          ),
      ],
      body: repo == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No business open',
              message:
                  'Set up a firm in Settings to start '
                  'recording purchase bills.',
            )
          : _area(repo),
    );
  }

  Stream<List<PurchaseBillEntity>>? _stream;
  String? _streamKey;
  PurchaseRepository? _streamRepo;

  Stream<List<PurchaseBillEntity>> _streamFor(PurchaseRepository repo) {
    final key = '$_activeDocType-${_range.cacheKey}';
    if (_stream == null || _streamKey != key || _streamRepo != repo) {
      _streamKey = key;
      _streamRepo = repo;
      _stream = repo.watchList(
        docType: _activeDocType,
        from: _range.from,
        to: _range.to,
        limit: 1000,
      );
    }
    return _stream!;
  }

  List<PurchaseBillEntity> _applySearch(
    List<PurchaseBillEntity> bills,
    String search,
  ) {
    if (search.isEmpty) return bills;
    final q = search.toLowerCase();
    return bills
        .where(
          (bill) =>
              bill.number.toLowerCase().contains(q) ||
              (bill.partyName ?? '').toLowerCase().contains(q) ||
              (bill.supplierInvoiceNumber ?? '').toLowerCase().contains(q),
        )
        .toList(growable: false);
  }

  Widget _area(PurchaseRepository repo) {
    return StreamBuilder<List<PurchaseBillEntity>>(
      stream: _streamFor(repo),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load bills',
            message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
          );
        }

        final all = snapshot.data ?? const <PurchaseBillEntity>[];
        final bills = _applySearch(all, _search);
        final stats = _statsOf(all);
        if (bills.isEmpty) {
          // The Date filter is what usually hides a bill: say so instead of
          // insisting none exist (the "my March bill is missing" report).
          final range = _range;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                  child: TotalsCard(
                    compact: true,
                    title: _totalsTitle,
                    entries: _totalsEntries(stats),
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
                      ? (range.isAllTime
                            ? _emptyTitle
                            : 'Nothing in ${range.label}')
                      : 'No matches',
                  message: _search.isNotEmpty
                      ? 'Nothing matches “$_search”. Try a different supplier '
                            'or bill number.'
                      : range.isAllTime
                      ? _emptyMessage
                      : range.emptyWindowMessage(_emptyNoun),
                  actionLabel: _search.isEmpty ? _emptyAction : null,
                  onAction: _search.isEmpty
                      ? () => context.push('/purchase/new?type=$_activeDocType')
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
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
      children: [
        TotalsCard(
          compact: true,
          title: _totalsTitle,
          entries: _totalsEntries(stats),
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
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
      children: [
        TotalsCard(
          compact: true,
          title: _totalsTitle,
          entries: _totalsEntries(stats),
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
          // The kebab button a row shows is a full 48px tap target, so the
          // header reserves the same width — a 36px slot left the Amount and
          // Balance figures 12px left of their own headings.
          trailing: const SizedBox(width: 48),
        ),
        for (final bill in bills)
          _PurchaseTableRow(bill: bill, docType: _activeDocType),
      ],
    );
  }

  String get _emptyTitle => switch (_activeDocType) {
    'debit_note' => 'No debit notes',
    'purchase_order' => 'No purchase orders',
    _ => 'No purchase bills',
  };

  String get _emptyMessage => switch (_activeDocType) {
    'debit_note' =>
      'Record a purchase return to send goods back and reverse the tax.',
    'purchase_order' =>
      'Track orders placed with suppliers before the goods arrive — then '
          'convert them into bills.',
    _ => 'Record your first purchase bill to track stock and payables.',
  };

  String get _emptyAction => switch (_activeDocType) {
    'debit_note' => 'Add Debit Note',
    'purchase_order' => 'Add Purchase Order',
    _ => 'Add Bill',
  };

  /// Plural noun for the period-aware empty state.
  String get _emptyNoun => switch (_activeDocType) {
    'debit_note' => 'debit notes',
    'purchase_order' => 'purchase orders',
    _ => 'bills',
  };

  String get _totalsTitle => switch (_activeDocType) {
    'debit_note' => 'Total Returned',
    'purchase_order' => 'Total Ordered',
    _ => 'Total Purchases',
  };

  /// Orders never touch payables — the bill raised against them does.
  List<TotalsEntry> _totalsEntries(_BillStats stats) => _isOrderTab
      ? [TotalsEntry(label: 'Total', amount: stats.purchases)]
      : [
          TotalsEntry(label: 'Total', amount: stats.purchases),
          TotalsEntry(label: 'Payable', amount: stats.payable),
        ];

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
  'purchase_order' => Icons.shopping_bag_outlined,
  _ => Icons.local_shipping_rounded,
};

/// The lifecycle word for a row — or null when the payment state is what the
/// Status column should carry.
///
/// Only a bill is payable, so only a bill shows Paid / Partial / Unpaid: an
/// order and a purchase return store a ₹0 balance (nothing received, nothing
/// owed), and printing a payment word beside it put "Unpaid" next to a zero on
/// every purchase order for ever. The repository now derives those documents'
/// status from their stored zero as well, so the row and the column agree.
String? _purchaseStatusText(PurchaseBillEntity bill, String docType) {
  if (bill.status == 'cancelled') return 'Cancelled';
  switch (docType) {
    case 'bill':
      return null; // null -> payment status
    case 'purchase_order':
      return bill.status == 'converted' ? 'Converted' : 'Open';
    default:
      return 'Issued';
  }
}

String _purchasePaymentLabel(PurchaseBillEntity bill) =>
    switch (bill.paymentStatus) {
      'paid' => 'Paid',
      'partial' => 'Partial',
      _ => 'Unpaid',
    };

/// The Status cell: the lifecycle word when there is one, the payment word
/// otherwise. Both row layouts go through here so they cannot disagree.
String _purchaseStatusLabel(PurchaseBillEntity bill, String docType) =>
    _purchaseStatusText(bill, docType) ?? _purchasePaymentLabel(bill);

ChipKind _purchaseStatusKind(PurchaseBillEntity bill, String docType) {
  if (bill.status == 'cancelled') return ChipKind.danger;
  if (_purchaseStatusText(bill, docType) != null) return ChipKind.info;
  if (docType != 'bill') return ChipKind.info;
  return switch (bill.paymentStatus) {
    'paid' => ChipKind.success,
    'partial' => ChipKind.warning,
    _ => ChipKind.neutral,
  };
}

class _PurchaseRow extends ConsumerWidget {
  const _PurchaseRow({required this.bill, required this.docType});

  final PurchaseBillEntity bill;
  final String docType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TransactionRow(
      leading: LeadingGlyph(icon: _docIcon(docType)),
      title: bill.partyName ?? 'Unknown supplier',
      subtitle: _subtitle,
      amount: Money.of(bill.grandTotal),
      amountColorize: false,
      statusLabel: _purchaseStatusLabel(bill, docType),
      statusKind: _purchaseStatusKind(bill, docType),
      dimmed: bill.status == 'cancelled',
      onTap: () => context.push('/purchase/edit/${bill.id}?type=$docType'),
      trailing: DocumentRowMenu(
        docType: docType,
        docId: bill.id,
        number: bill.number,
        status: bill.status,
        paymentStatus: bill.paymentStatus,
      ),
    );
  }

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
      onTap: () => context.push('/purchase/edit/${bill.id}?type=$docType'),
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
      statusLabel: _purchaseStatusLabel(bill, docType),
      statusKind: _purchaseStatusKind(bill, docType),
      // The Status column already carries this; the pill beside the balance
      // duplicated it and pushed the figure left of its header.
      showStatusChip: false,
      trailing: DocumentRowMenu(
        docType: docType,
        docId: bill.id,
        number: bill.number,
        status: bill.status,
        paymentStatus: bill.paymentStatus,
      ),
      dimmed: bill.status == 'cancelled',
    );
  }
}
