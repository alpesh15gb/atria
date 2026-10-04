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
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/document_row_menu.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/status_chip.dart';
import '../../shared/widgets/transaction_list.dart';

class SalesListScreen extends ConsumerStatefulWidget {
  const SalesListScreen({super.key, this.initialType});

  /// `?type=` from the rail's Sales dropdown (quotation, sales_order,
  /// delivery_note, credit_note). Null/unknown = invoices.
  final String? initialType;

  @override
  ConsumerState<SalesListScreen> createState() => _SalesListScreenState();
}

class _SalesListScreenState extends ConsumerState<SalesListScreen> {
  final _searchController = TextEditingController();
  String _search = '';
  PeriodRange _range = PeriodRange(period: Period.thisMonth);
  Timer? _searchDebounce;

  /// The document type this list shows — one screen per type now that the
  /// five tabs moved into the left rail's Sales dropdown.
  ///
  /// Derived from the route on every build, never latched into a field.
  /// `StatefulShellRoute.indexedStack` keeps each branch's navigator alive, so
  /// `/sales?type=quotation` → `/sales?type=invoice` resolves to this same
  /// State, not a new one. A `late` field seeded from `initialType` was
  /// therefore written exactly once per session: whichever type the rail was
  /// first opened on won for good, and the heading, the filter pills and the
  /// primary action went on naming a document the user had already left —
  /// "every screen says invoice" until the app was restarted. The route is the
  /// only holder of the current type, so it is the only thing allowed to
  /// answer.
  String get _docType =>
      _supported.contains(widget.initialType) ? widget.initialType! : 'invoice';

  static const _supported = [
    'invoice',
    'quotation',
    'sales_order',
    'delivery_note',
    'credit_note',
  ];

  /// The document types as filter options — the same list the rail's Sales
  /// section offers, so the two can never disagree.
  static const _typeSegments = [
    AtriaSegment(value: 'invoice', label: 'Invoices'),
    AtriaSegment(value: 'quotation', label: 'Quotations'),
    AtriaSegment(value: 'sales_order', label: 'Sales orders'),
    AtriaSegment(value: 'delivery_note', label: 'Delivery notes'),
    AtriaSegment(value: 'credit_note', label: 'Credit notes'),
  ];

  /// The page heading follows the filter, the way QBO's page title names the
  /// list you are actually on.
  String get _pageTitle => switch (_docType) {
    'quotation' => 'Quotations',
    'sales_order' => 'Sales orders',
    'delivery_note' => 'Delivery notes',
    'credit_note' => 'Credit notes',
    _ => 'Invoices',
  };

  String get _newLabel => switch (_docType) {
    'quotation' => 'New quotation',
    'sales_order' => 'New sales order',
    'delivery_note' => 'New delivery note',
    'credit_note' => 'New credit note',
    _ => 'New invoice',
  };

  /// Singular name of what this screen lists.
  ///
  /// The search field used to say "Search invoice or party…" on every one of
  /// the five, which is the last place on the screen that still named a
  /// document the person had already navigated away from.
  String get _singularNoun => switch (_docType) {
    'quotation' => 'quotation',
    'sales_order' => 'sales order',
    'delivery_note' => 'delivery note',
    'credit_note' => 'credit note',
    _ => 'invoice',
  };

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sales = ref.watch(salesRepositoryProvider);

    if (sales == null) {
      return const AtriaListPage(
        title: 'Sales',
        body: EmptyState(
          icon: PhosphorIconsRegular.receipt,
          title: 'No business selected',
          message: 'Choose or create a business to start selling.',
        ),
      );
    }

    // QBO's page anatomy: the page names itself and carries its own primary
    // action at the right edge of the heading — there is no FAB and no second
    // title bar, because the chrome band above already owns the app-wide
    // controls.
    return AtriaListPage(
      title: _pageTitle,
      actions: [
        AtriaPrimaryAction(
          label: _newLabel,
          onPressed: () => context.push('/sales/new?type=$_docType'),
        ),
      ],
      search: TransactionSearchField(
        controller: _searchController,
        hintText: 'Search $_singularNoun or party…',
        onChanged: (value) {
          // Debounced: rebuilding per keystroke re-subscribed the whole
          // list stream on every letter, flashing the loader.
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
      filters: [
        AtriaAdaptiveFilter<String>(
          label: 'Type',
          segments: _typeSegments,
          value: _docType,
          // `go`, not `setState`: the type now lives in the URL, so switching
          // it here has to write it back there. A local `setState` moved the
          // screen off the rail's selection and off its own deep link, so the
          // next router-driven rebuild snapped the heading back to the type in
          // the address bar.
          onChanged: (value) => context.go('/sales?type=$value'),
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
      body: _SaleList(
        key: ValueKey('$_docType|${_range.cacheKey}'),
        docType: _docType,
        search: _search,
        range: _range,
      ),
    );
  }
}

class _SaleList extends ConsumerStatefulWidget {
  const _SaleList({
    super.key,
    required this.docType,
    required this.search,
    required this.range,
  });

  final String docType;
  final String search;
  final PeriodRange range;

  @override
  ConsumerState<_SaleList> createState() => _SaleListState();
}

class _SaleListState extends ConsumerState<_SaleList> {
  // One stream per (docType, search, window), kept across rebuilds — the old
  // code constructed a fresh stream inside build, tearing down and
  // re-subscribing the drift watch on every parent setState (per keystroke).
  final Map<String, Stream<List<SalesInvoiceEntity>>> _streams = {};

  Stream<List<SalesInvoiceEntity>> _streamFor(SalesRepository? sales) {
    if (sales == null) return const Stream.empty();
    final key = '${widget.docType}|${widget.search}|${widget.range.cacheKey}';
    return _streams.putIfAbsent(key, () {
      return sales.watchList(
        docType: widget.docType,
        search: widget.search,
        from: widget.range.from,
        to: widget.range.to,
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
          // A period filter that has simply excluded every row used to read
          // "No invoices yet" — which is why a user with an older bill open on
          // "This Month" believed the document had vanished. Say which window
          // is hiding them and name the way out.
          final range = widget.range;
          return EmptyState(
            icon: PhosphorIconsRegular.receipt,
            title: range.isAllTime ? _emptyTitle : 'Nothing in ${range.label}',
            message: range.isAllTime
                ? _emptyMessage
                : range.emptyWindowMessage('${_resultNoun}s'),
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
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
      children: [
        _TotalsSection(docType: widget.docType, stats: stats),
        const SizedBox(height: 8),
        AtriaResultsBar(
          count: stats.count,
          noun: _resultNoun,
          filtered: widget.search.trim().isNotEmpty,
        ),
        const SizedBox(height: 4),
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

  /// Desktop: the rows *are* the summarised figures, so the totals close the
  /// table instead of sitting above it as a separate panel — QBO's arrangement.
  Widget _tableList(BuildContext context, List<SalesInvoiceEntity> data) {
    final stats = _statsOf(data);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
      children: [
        AtriaResultsBar(
          count: stats.count,
          noun: _resultNoun,
          filtered: widget.search.trim().isNotEmpty,
        ),
        TransactionTableHeader(
          columns: const TransactionColumns(
            date: 'Date',
            number: 'No.',
            party: 'Customer',
            detail: 'Status',
            amount: 'Amount',
            balance: 'Balance',
          ),
          // The kebab button a row shows is a full 48px tap target, so the
          // header and totals reserve the same width — a 36px slot left the
          // Amount and Balance figures 12px left of their own headings.
          trailing: const SizedBox(width: 48),
        ),
        for (final invoice in data)
          _SaleTableRow(invoice: invoice, docType: widget.docType),
        if (widget.docType == 'invoice')
          TransactionTableTotals(
            // Aligned under the same columns the rows use, kebab slot
            // included, so "Balance ₹0.00" sits under its header.
            trailingWidth: 48,
            entries: [
              TotalsEntry(label: 'Total', amount: stats.total),
              TotalsEntry(label: 'Received', amount: stats.received),
              TotalsEntry(label: 'Balance', amount: stats.balance),
            ],
          ),
      ],
    );
  }

  _SaleStats _statsOf(List<SalesInvoiceEntity> data) {
    var total = Decimal.zero;
    var received = Decimal.zero;
    var balance = Decimal.zero;
    // The bar counts what is ON SCREEN. Cancelled rows are still rendered
    // (dimmed, badged "Cancelled"), and skipping them here made the header say
    // "12 invoices" above thirteen rows. The MONEY totals keep excluding them —
    // a cancelled document contributes nothing to sales or to receivable.
    final count = data.length;
    for (final doc in data) {
      if (doc.status == 'cancelled') continue;
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
      case 'delivery_note':
        return 'No delivery notes yet';
      case 'credit_note':
        return 'No credit notes yet';
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
      case 'delivery_note':
        return 'Record what you shipped — a delivery note is a paper record, '
            'so it does not change stock. Raise an invoice to bill it.';
      case 'credit_note':
        return 'Record goods returned by a customer. The credit note adds them '
            'back to stock and reduces their outstanding.';
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
      case 'delivery_note':
        return 'New delivery note';
      case 'credit_note':
        return 'New credit note';
      default:
        return 'New invoice';
    }
  }

  /// Singular noun for the results line (the bar pluralises it).
  String get _resultNoun => switch (widget.docType) {
    'quotation' => 'quotation',
    'sales_order' => 'order',
    'delivery_note' => 'delivery note',
    'credit_note' => 'credit note',
    _ => 'invoice',
  };
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

/// The lifecycle word for a row — or null when the payment state is what the
/// Status column should carry.
///
/// Invoices deliberately return null when they are healthy: every saved
/// invoice is stored as 'confirmed', so printing "Confirmed" there meant the
/// Status column read "Confirmed" on a fully paid invoice and on a long-
/// overdue one alike, and Paid / Partial / Unpaid were never visible. The
/// lifecycle words are reserved for the document types where they mean
/// something (estimates, orders, notes).
String? _statusText(SalesInvoiceEntity doc, String docType) {
  if (doc.status == 'cancelled') return 'Cancelled';
  switch (docType) {
    case 'invoice':
      return _isOverdue(doc) ? 'Overdue' : null; // null -> payment status
    case 'quotation':
    case 'sales_order':
      if (doc.status == 'converted') return 'Converted';
      return doc.status == 'draft' ? 'Draft' : 'Open';
    case 'delivery_note':
    case 'credit_note':
      return doc.status == 'draft' ? 'Draft' : 'Issued';
    default:
      return null;
  }
}

/// The same rule the dashboard and the reminders list use: a live document
/// with something still owing and a due date in the past.
bool _isOverdue(SalesInvoiceEntity doc) {
  final due = doc.dueDate;
  return doc.balanceDue > 0.001 && due != null && due.isBefore(DateTime.now());
}

String _paymentLabel(SalesInvoiceEntity doc) => switch (doc.paymentStatus) {
  'paid' => 'Paid',
  'partial' => 'Partial',
  _ => 'Unpaid',
};

ChipKind _statusKindFor(SalesInvoiceEntity doc, String docType) {
  if (doc.status == 'cancelled') return ChipKind.danger;
  if (doc.status == 'converted') return ChipKind.info;
  if (docType != 'invoice') return ChipKind.info;
  if (_isOverdue(doc)) return ChipKind.danger;
  return switch (doc.paymentStatus) {
    'paid' => ChipKind.success,
    'partial' => ChipKind.warning,
    _ => ChipKind.neutral,
  };
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
    return TransactionRow(
      leading: LeadingGlyph(icon: _docIcon(docType)),
      title: invoice.partyName ?? 'Walk-in customer',
      subtitle: _subtitle,
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      statusLabel: _statusText(invoice, docType) ?? _paymentLabel(invoice),
      statusKind: _statusKindFor(invoice, docType),
      dimmed: invoice.status == 'cancelled',
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      // Content-aware kebab: the entries adapt to the document type and its
      // state (Receive Payment only on a balanced invoice, Convert only on
      // an open estimate, PDF/Print on sales documents, History always).
      trailing: DocumentRowMenu(
        docType: docType,
        docId: invoice.id,
        number: invoice.number,
        status: invoice.status,
        paymentStatus: invoice.paymentStatus,
        balanceDue: invoice.balanceDue,
      ),
    );
  }

  String get _subtitle {
    final parts = <String>[invoice.number];
    if (showDate) parts.add(Formatters.date(invoice.invoiceDate));
    if (invoice.isInterState && (invoice.partyGstin ?? '').isNotEmpty) {
      parts.add(
        'Inter-state · ${IndianStates.byCode(invoice.placeOfSupply)?.name ?? ''}',
      );
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
    return TransactionTableRow(
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      leading: LeadingGlyph(icon: _docIcon(docType)),
      date: Formatters.date(invoice.invoiceDate),
      number: invoice.number,
      party: invoice.partyName ?? 'Walk-in customer',
      detail: _statusText(invoice, docType) ?? _paymentLabel(invoice),
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      balance: Money.of(invoice.balanceDue),
      statusLabel: _statusText(invoice, docType) ?? _paymentLabel(invoice),
      statusKind: _statusKindFor(invoice, docType),
      // The Status column already says it — a pill beside the balance
      // repeated the word and nudged the figure left of its header.
      showStatusChip: false,
      // Content-aware kebab: the entries adapt to the document type and its
      // state (Receive Payment only on a balanced invoice, Convert only on
      // an open estimate, PDF/Print on sales documents, History always).
      trailing: DocumentRowMenu(
        docType: docType,
        docId: invoice.id,
        number: invoice.number,
        status: invoice.status,
        paymentStatus: invoice.paymentStatus,
        balanceDue: invoice.balanceDue,
      ),
      dimmed: invoice.status == 'cancelled',
    );
  }
}
