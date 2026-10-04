import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/bulk/bulk_actions.dart';
import '../../core/bulk/bulk_sales_actions.dart';
import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/sales_repository.dart';
import '../../core/domain/document_status.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/services/csv_export.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';
import '../../shared/widgets/document_row_menu.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/selection_bar.dart';
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
  DocumentStatus? _status;
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

  /// The statuses worth offering as filters, for the document type on screen.
  ///
  /// Built from [DocumentStatus.forDocType] rather than a hand-written list, so
  /// the filter and the lifecycle can never offer a state the vocabulary does
  /// not have. 'Confirmed' is dropped because it is the stored default on every
  /// saved invoice — a segment labelled Confirmed that returns the whole list is
  /// worse than no segment.
  List<AtriaSegment<String>> get _statusSegments {
    final allowed = DocumentStatus.forDocType(_docType);
    // 'confirmed' is the stored default on every invoice and reads as "no
    // filter", so offering it as a segment that returns "everything" is a lie.
    final choices = allowed
        .where(
          (s) =>
              s != DocumentStatus.confirmed &&
              s != DocumentStatus.convertedLegacy,
        )
        .toList();
    if (choices.length < 2) return const [];
    return [
      const AtriaSegment(value: 'all', label: 'All'),
      ...choices.map((s) => AtriaSegment(value: s.name, label: s.label)),
    ];
  }

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
        // Only for the document types that actually have a lifecycle to
        // filter. On invoices every row is 'confirmed', so the filter would
        // offer four segments of which three return nothing.
        if (_statusSegments.isNotEmpty)
          AtriaAdaptiveFilter<String>(
            label: 'Status',
            segments: _statusSegments,
            value: _status?.name ?? 'all',
            onChanged: (value) => setState(
              () => _status = value == 'all'
                  ? null
                  : DocumentStatus.of(value, _docType),
            ),
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
        key: ValueKey('$_docType|${_range.cacheKey}|${_status?.name}'),
        docType: _docType,
        search: _search,
        range: _range,
        statusFilter: _status,
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
    required this.statusFilter,
  });

  final String docType;
  final String search;
  final PeriodRange range;

  /// Null = every status. Otherwise only this one.
  ///
  /// Single-select on purpose. A multi-select status filter needs a "which
  /// are on?" control that stays visible while you set it, and the filter row
  /// is a single line of pills — a second sheet for every list is a worse
  /// trade than not offering combinations. "All" is the first segment, so the
  /// way back out is always one tap and never a hidden reset.
  final DocumentStatus? statusFilter;

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
    final key =
        '${widget.docType}|${widget.search}|${widget.range.cacheKey}|'
        '${widget.statusFilter?.name ?? 'all'}';
    return _streams.putIfAbsent(key, () {
      return sales.watchList(
        docType: widget.docType,
        search: widget.search,
        from: widget.range.from,
        to: widget.range.to,
        limit: 200,
        statuses: widget.statusFilter == null
            ? const {}
            : {widget.statusFilter!},
      );
    });
  }

  /// Which rows are ticked.
  ///
  /// Lives here rather than in the page frame because this is where the rows
  /// are: `AtriaListPage.toolbar` belongs to the parent screen, which never sees
  /// the stream. The selection bar is therefore rendered as the list's first
  /// child, where it sits directly above the rows it acts on.
  BulkSelection _selection = const BulkSelection();

  void _setSelection(BulkSelection next) {
    if (next == _selection) return;
    setState(() => _selection = next);
  }

  void _toggle(String id) => _setSelection(_selection.toggle(id));

  /// Ticks every loaded row, or clears the whole selection if it already was
  /// everything.
  ///
  /// [loadedCount] is supplied here rather than read off [_selection] because
  /// the field holds *intent* only — the count belongs to the list, and only
  /// the list knows it. Leaving the field's count at zero makes `isAllLoaded`
  /// permanently false, and the select-all control can then only ever grow the
  /// selection: pressing it twice gives you every row selected rather than none.
  void _toggleAll(List<SalesInvoiceEntity> data) {
    final current = BulkSelection(
      ids: _selection.ids,
      loadedCount: data.length,
    );
    _setSelection(current.toggleAll(data.map((d) => d.id)));
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
        // A document deleted from another screen must not linger in the
        // selection and then fail the next bulk action with an error nobody can
        // act on, and a row hidden by a new search must lose its tick rather
        // than silently joining the next action. Reconciled into a local rather
        // than into the field, because build must not mutate state.
        final visible = data.map((d) => d.id).toSet();
        final selection = BulkSelection(
          ids: _selection.pruned(visible).ids,
          loadedCount: data.length,
        );
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
              ? _cardList(context, data, selection)
              : _tableList(context, data, selection),
        );
      },
    );
  }

  Widget _cardList(
    BuildContext context,
    List<SalesInvoiceEntity> data,
    BulkSelection selection,
  ) {
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
        _selectionBar(data, selection),
        for (final invoice in data)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _SaleRow(
              invoice: invoice,
              docType: widget.docType,
              showDate: true,
              selected: selection.contains(invoice.id),
              onToggleSelect: () => _toggle(invoice.id),
            ),
          ),
      ],
    );
  }

  /// The bulk bar. Returns a zero-height box when nothing is ticked, so the row
  /// collapses instead of leaving an always-present band of dead controls.
  Widget _selectionBar(List<SalesInvoiceEntity> data, BulkSelection selection) {
    if (selection.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SelectionBar(
        selection: selection,
        selectionNoun: _resultNoun,
        onChanged: _setSelection,
        onSelectAll: () => _toggleAll(data),
        actions: [
          TextButton.icon(
            onPressed: () => _bulkPdf(data, selection),
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('PDF'),
          ),
          TextButton.icon(
            onPressed: () => _bulkCsv(selection),
            icon: const Icon(Icons.table_chart_outlined, size: 18),
            label: const Text('CSV'),
          ),
          TextButton.icon(
            onPressed: () => _bulkDelete(data, selection),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Desktop: the rows *are* the summarised figures, so the totals close the
  /// table instead of sitting above it as a separate panel — QBO's arrangement.
  Widget _tableList(
    BuildContext context,
    List<SalesInvoiceEntity> data,
    BulkSelection selection,
  ) {
    final stats = _statsOf(data);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 28),
      children: [
        AtriaResultsBar(
          count: stats.count,
          noun: _resultNoun,
          filtered: widget.search.trim().isNotEmpty,
        ),
        _selectionBar(data, selection),
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
          _SaleTableRow(
            invoice: invoice,
            docType: widget.docType,
            selected: selection.contains(invoice.id),
            onToggleSelect: () => _toggle(invoice.id),
          ),
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

  BulkSalesActions _actions() => BulkSalesActions(
    sales: ref.read(salesRepositoryProvider),
    firmId: ref.read(activeFirmIdProvider) ?? '',
    exportBaseDirectory: exportRootDirectory,
  );

  Future<void> _bulkCsv(BulkSelection selection) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final file = await _actions().csv(selection.ids);
      if (!mounted) return;
      // Both, always: on Android the share sheet is the only way out of
      // app-private storage, and a path printed as the primary result is
      // meaningless to someone holding a phone.
      await Share.shareXFiles([XFile(file.path)]);
      if (!mounted) return;
      _setSelection(selection.cleared());
      messenger?.showSnackBar(
        SnackBar(content: Text('Exported ${selection.count} $_resultNoun')),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not export: $error')),
      );
    }
  }

  Future<void> _bulkPdf(
    List<SalesInvoiceEntity> data,
    BulkSelection selection,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (firm == null) return;
    try {
      final result = await _actions().pdfs(selection.ids.toList(), firm);
      if (!mounted) return;
      if (result.files.isEmpty) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Could not print: ${result.failed} failed')),
        );
        return;
      }
      await BulkPdfShare(
        shareFiles: (paths, {subject}) => Share.shareXFiles([
          for (final path in paths) XFile(path),
        ], subject: subject),
      ).share(result, subject: 'Invoices');
      if (!mounted) return;
      _setSelection(selection.cleared());
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            result.failed == 0
                ? 'Printed ${result.printed} $_resultNoun'
                : 'Printed ${result.printed} of ${selection.count}; '
                      '${result.failed} could not be built',
          ),
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not print: $error')),
      );
    }
  }

  /// Deletes the selection after naming what is about to go, then offers an undo
  /// covering **only** the rows it confirmed deleting.
  Future<void> _bulkDelete(
    List<SalesInvoiceEntity> data,
    BulkSelection selection,
  ) async {
    // Taken before the dialog: the messenger belongs to the scaffold that owns
    // this screen, and looking it up after the await risks reaching a different
    // one if the operator navigated during the confirmation.
    final messenger = ScaffoldMessenger.maybeOf(context);

    final ids = selection.ids.toList();
    final named = data
        .where((d) => selection.contains(d.id))
        .map((d) => d.number)
        .toList();

    // Name the first few. A confirmation listing 200 invoice numbers is not
    // read by anyone; naming a couple makes the accidental selection obvious.
    final preview = named.take(3).join(', ');
    final more = named.length > 3 ? ' and ${named.length - 3} more' : '';
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete ${selection.count} $_resultNoun?',
      message:
          '$preview$more move to the recycle bin. Stock and balances are '
          'reversed, and you can restore them until you empty the bin.',
    );
    if (!confirmed || !mounted) return;

    final outcome = await _actions().delete(ids);
    if (!mounted) return;
    _setSelection(selection.cleared());

    // The count is the count that happened, never the count asked for.
    final message = outcome.failed == 0
        ? 'Deleted ${outcome.deleted} $_resultNoun'
        : 'Deleted ${outcome.deleted} of ${outcome.requested}; '
              '${outcome.failed} could not be deleted';
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 6),
        action: outcome.deleted == 0
            ? null
            : SnackBarAction(
                label: 'Undo',
                onPressed: () => _undoDelete(outcome.deletedIds),
              ),
      ),
    );
  }

  Future<void> _undoDelete(Set<String> ids) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final outcome = await _actions().undoDelete(ids);
    if (!mounted) return;
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          outcome.failed == 0
              ? 'Restored ${outcome.deleted}'
              : 'Restored ${outcome.deleted} of ${outcome.requested}; '
                    '${outcome.failed} could not be restored',
        ),
      ),
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

/// The lifecycle a row is in, with expiry worked out rather than read.
///
/// Null means "this column carries the payment state, not a lifecycle" —
/// which is the case for a healthy invoice, because every saved invoice is
/// 'confirmed' and a Status column reading "Confirmed" above a long-overdue
/// one told the operator nothing while hiding Paid / Partial / Unpaid.
DocumentStatus? _lifecycleOf(SalesInvoiceEntity doc, String docType) {
  if (doc.status == 'cancelled') return DocumentStatus.cancelled;
  if (doc.convertedToInvoiceId != null ||
      doc.status == DocumentStatus.legacyConvertedValue) {
    return DocumentStatus.convertedLegacy;
  }
  if (DocumentStatus.isExpired(
    status: doc.status,
    docType: docType,
    // A quotation's "Valid till" is stored in dueDate — the same field an
    // invoice uses for when payment is due, and for a document nobody has
    // committed to paying, that field means the offer's last day.
    validTill: doc.dueDate,
  )) {
    return DocumentStatus.expired;
  }
  final stored = DocumentStatus.of(doc.status, docType);
  // 'confirmed' on an invoice is not news, and a quotation that is merely
  // awaiting a reply has not earned a badge either — it is the default, so it
  // gets no chip rather than a chip every row shares.
  if (stored == DocumentStatus.confirmed && docType != 'invoice') return null;
  if (docType == 'invoice') return null;
  return stored;
}

/// The label and colour for a row's Status cell, decided in one place.
///
/// The two used to be separate functions, which is how they drifted: the
/// label knew about 'converted' and the colour function knew about it
/// independently, and a status added to one was invisible in the other.
({String label, ChipKind kind}) _rowStatus(
  SalesInvoiceEntity doc,
  String docType,
) {
  final lifecycle = _lifecycleOf(doc, docType);
  if (lifecycle != null) {
    return (label: lifecycle.label, kind: lifecycle.kind);
  }
  if (_isOverdue(doc)) {
    return (label: 'Overdue', kind: ChipKind.danger);
  }
  return switch (doc.paymentStatus) {
    'paid' => (label: 'Paid', kind: ChipKind.success),
    'partial' => (label: 'Partial', kind: ChipKind.warning),
    _ => (label: 'Unpaid', kind: ChipKind.neutral),
  };
}

/// The same rule the dashboard and the reminders list use: a live document
/// with something still owing and a due date in the past.
bool _isOverdue(SalesInvoiceEntity doc) {
  final due = doc.dueDate;
  return doc.balanceDue > 0.001 && due != null && due.isBefore(DateTime.now());
}

/// A tick target sized to fit a table's fixed 50px leading slot.
///
/// A stock `Checkbox` is 40px of visual plus its own padding, which measures
/// wider than the slot and pushes every flexed column right of it. Pinning it
/// with `SizedBox` + `Center` keeps the header, the rows, and the totals line
/// on the same grid, and lets the row itself stay tappable for navigation.
class _SelectionBox extends StatelessWidget {
  const _SelectionBox({
    required this.selected,
    required this.onTap,
    this.rowId,
  });

  final bool selected;
  final VoidCallback onTap;

  /// The document this tick belongs to, when it is a row's tick rather than
  /// something a caller positions itself. Carried as a key so a test can name
  /// a row's checkbox instead of counting `Checkbox`es — the selection bar has
  /// one of its own, and it appears and disappears as the selection changes, so
  /// any index into a raw `find.byType(Checkbox)` shifts underneath the test.
  final String? rowId;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 50,
      height: 40,
      child: Center(
        child: Checkbox(
          key: rowId == null ? null : ValueKey('select-$rowId'),
          value: selected,
          onChanged: (_) => onTap(),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class _SaleRow extends ConsumerWidget {
  const _SaleRow({
    required this.invoice,
    required this.docType,
    this.showDate = false,
    this.selected = false,
    this.onToggleSelect,
  });

  final SalesInvoiceEntity invoice;
  final String docType;
  final bool showDate;

  /// Whether this row is ticked for a bulk action.
  final bool selected;

  /// Null hides the checkbox — a list without bulk actions passes nothing and
  /// gets no tick target at all.
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TransactionRow(
      // The card has no column grid to line up with, so it keeps its document
      // glyph and gains a checkbox beside it. The table below drops the glyph
      // instead — see [_SaleTableRow].
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onToggleSelect != null) ...[
            _SelectionBox(
              selected: selected,
              onTap: onToggleSelect!,
              rowId: invoice.id,
            ),
            const SizedBox(width: 10),
          ],
          LeadingGlyph(icon: _docIcon(docType)),
        ],
      ),
      title: invoice.partyName ?? 'Walk-in customer',
      subtitle: _subtitle,
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      statusLabel: _rowStatus(invoice, docType).label,
      statusKind: _rowStatus(invoice, docType).kind,
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
        convertedToInvoiceId: invoice.convertedToInvoiceId,
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
  const _SaleTableRow({
    required this.invoice,
    required this.docType,
    this.selected = false,
    this.onToggleSelect,
  });

  final SalesInvoiceEntity invoice;
  final String docType;
  final bool selected;
  final VoidCallback? onToggleSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TransactionTableRow(
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      // The header reserves a fixed 50px leading slot for exactly this widget.
      // A Checkbox is 40px tall with a tap target wider than that, so it is
      // pinned to the slot rather than left to push the flexed columns along —
      // the glyph has to go instead, which is why it survives only in the card
      // list above.
      leading: onToggleSelect == null
          ? LeadingGlyph(icon: _docIcon(docType))
          : _SelectionBox(
              selected: selected,
              onTap: onToggleSelect!,
              rowId: invoice.id,
            ),
      date: Formatters.date(invoice.invoiceDate),
      number: invoice.number,
      party: invoice.partyName ?? 'Walk-in customer',
      detail: _rowStatus(invoice, docType).label,
      amount: Money.of(invoice.grandTotal),
      amountColorize: false,
      balance: Money.of(invoice.balanceDue),
      statusLabel: _rowStatus(invoice, docType).label,
      statusKind: _rowStatus(invoice, docType).kind,
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
        convertedToInvoiceId: invoice.convertedToInvoiceId,
        paymentStatus: invoice.paymentStatus,
        balanceDue: invoice.balanceDue,
      ),
      dimmed: invoice.status == 'cancelled',
    );
  }
}
