import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/payment_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_avatar.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/document_row_menu.dart';
import '../../shared/widgets/period_selector.dart';
import '../../shared/widgets/transaction_list.dart';

/// Cash & Bank balances across payment modes for the period shown.
class CashBankSummary {
  CashBankSummary();

  double cashIn = 0, cashOut = 0, bankIn = 0, bankOut = 0, chequeIn = 0;

  double get cashBalance => cashIn - cashOut;
  double get bankBalance => bankIn - bankOut;
  double get cheques => chequeIn;
}

enum _PaymentFilter { all, paymentIn, paymentOut }

/// Cheques whose money has not arrived: in hand, or given to the bank and not
/// yet cleared.
///
/// Deliberately not filtered by the screen's date window: a cheque taken in the
/// last quarter is exactly the one that is still waiting, and hiding it behind a
/// "This month" filter is how a deposit gets forgotten.
final _unclearedChequesProvider = StreamProvider<List<PaymentEntity>>((ref) {
  final repo = ref.watch(paymentRepositoryProvider);
  if (repo == null) return Stream.value(const <PaymentEntity>[]);
  return repo.watchUnclearedCheques();
});

/// Payments In/Out: every receipt and payment with mode breakdown
/// (cash / bank / cheque), Vyapar's Payments page. FAB opens the editor.
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  _PaymentFilter _filter = _PaymentFilter.all;
  PeriodRange _range = PeriodRange(period: Period.thisMonth);
  final _searchController = TextEditingController();
  String _search = '';

  // One stream per (type, window), kept across rebuilds. Building the stream
  // inline in `build` handed the StreamBuilder a brand-new Drift watch on
  // every keystroke — it unsubscribed, lost its data and flashed the full-page
  // spinner while the user was still typing.
  Stream<List<PaymentEntity>>? _stream;
  String? _streamKey;
  PaymentRepository? _streamRepo;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String? get _typeFilter => switch (_filter) {
    _PaymentFilter.all => null,
    _PaymentFilter.paymentIn => 'payment_in',
    _PaymentFilter.paymentOut => 'payment_out',
  };

  Stream<List<PaymentEntity>> _streamFor(PaymentRepository repo) {
    final key = '${_typeFilter ?? 'all'}|${_range.cacheKey}';
    if (_stream == null || _streamKey != key || _streamRepo != repo) {
      _streamKey = key;
      _streamRepo = repo;
      _stream = repo.watchList(
        type: _typeFilter,
        from: _range.from,
        to: _range.to,
        limit: 2000,
      );
    }
    return _stream!;
  }

  /// The summary cards' balances, read from the books. The ledger is the one
  /// source of truth for "Cash in hand" — re-deriving it from the payment rows
  /// alone would disagree with the books by every amount that moved through
  /// the till another way (a cash expense, a hand-keyed voucher).
  ///
  /// The [AsyncValue] is handed to the cards rather than unwrapped here: the
  /// provider is an `async*` StreamProvider that runs a full trial balance
  /// before its first yield, and `valueOrNull ?? const CashBankBalances()`
  /// painted a hard ₹0.00 for that whole gap — the first thing the screen said
  /// about a shop with money in it was that it had none. Being `autoDispose`
  /// it re-flashes on every tab return, so the gap recurs for the life of the
  /// app. The cards decide what "not known yet" looks like.
  AsyncValue<CashBankBalances> get _balances =>
      ref.watch(cashBankBalancesProvider);

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(paymentRepositoryProvider);
    // The shared page frame owns the heading, its inset and the position of
    // the primary action, so this page lines up with every other list.
    return AtriaListPage(
      title: 'Payments',
      actions: [
        if (repo != null)
          AtriaPrimaryAction(
            label: 'Record payment',
            onPressed: () => showPaymentEditor(context, ref),
            icon: Icons.add_rounded,
          ),
      ],
      body: repo == null
          ? const EmptyState(
              icon: Icons.storefront_outlined,
              title: 'No business open',
              message: 'Open a business to record payments in and out.',
            )
          : _body(repo),
    );
  }

  Widget _body(PaymentRepository repo) {
    return StreamBuilder<List<PaymentEntity>>(
      stream: _streamFor(repo),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load payments',
            message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
          );
        }
        var payments = snapshot.data ?? const <PaymentEntity>[];
        final query = _search.toLowerCase();
        if (query.isNotEmpty) {
          payments = payments
              .where(
                (p) =>
                    (p.partyName ?? '').toLowerCase().contains(query) ||
                    p.number.toLowerCase().contains(query) ||
                    (p.reference ?? '').toLowerCase().contains(query),
              )
              .toList(growable: false);
        }

        // The money cards keep reading the whole history; only the rows obey
        // the filters.
        final summary = _balances;

        // The cheque strip owns the rows it shows, so they are taken out of
        // the list below — otherwise the same cheque appears twice on one
        // screen. A search stands the strip down: a search must be able to
        // find a cheque by number, reference or party like anything else.
        final uncleared =
            ref.watch(_unclearedChequesProvider).valueOrNull ??
            const <PaymentEntity>[];
        final searching = _search.isNotEmpty;
        final inStrip = searching
            ? const <String>{}
            : uncleared.map((c) => c.id).toSet();
        final listed = inStrip.isEmpty
            ? payments
            : payments
                  .where((p) => !inStrip.contains(p.id))
                  .toList(growable: false);

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _summaryRow(context, summary)),
            if (!searching)
              SliverToBoxAdapter(
                child: _chequeBucket(context, repo, uncleared),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(0, AppSpace.sm, 0, 0),
                child: TransactionSearchField(
                  controller: _searchController,
                  hintText: 'Search party, number or reference',
                  onChanged: (v) => setState(() => _search = v.trim()),
                  onClear: () {
                    _searchController.clear();
                    setState(() => _search = '');
                  },
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: AppSpace.md)),
            SliverToBoxAdapter(
              child: AtriaFilterBar(
                filters: [
                  AtriaAdaptiveFilter<_PaymentFilter>(
                    label: 'Type',
                    scrollable: false,
                    value: _filter,
                    onChanged: (f) => setState(() => _filter = f),
                    segments: const [
                      AtriaSegment(value: _PaymentFilter.all, label: 'All'),
                      AtriaSegment(
                        value: _PaymentFilter.paymentIn,
                        label: 'Money in',
                      ),
                      AtriaSegment(
                        value: _PaymentFilter.paymentOut,
                        label: 'Money out',
                      ),
                    ],
                  ),
                  // Payments was the only list without a date window, so the
                  // summary cards were labelled "for the period shown" while
                  // actually totalling all of history.
                  AtriaAdaptiveFilter<Period>(
                    label: 'Date',
                    segments: periodSegments(),
                    value: _range.period,
                    onChanged: (period) =>
                        setState(() => _range = _range.withPeriod(period)),
                  ),
                  if (_range.isCustom)
                    PeriodCustomRange(
                      range: _range,
                      onChanged: (range) => setState(() => _range = range),
                    ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: AtriaResultsBar(
                count: listed.length,
                noun: 'payment',
                filtered:
                    _search.isNotEmpty ||
                    _filter != _PaymentFilter.all ||
                    !_range.isAllTime ||
                    inStrip.isNotEmpty,
              ),
            ),
            if (payments.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                // A search that matched nothing is "no matches", not "no
                // payments yet" — the old branch tested the date window only,
                // so typing a name with no match invited the user to record
                // their first payment while they were only searching. Mirrors
                // the wording the purchase and sales lists use.
                child: searching
                    ? EmptyState(
                        icon: Icons.search_off_rounded,
                        title: 'No matches',
                        message:
                            'Nothing matches “$_search”. Try a different party, '
                            'number or reference.',
                      )
                    : _range.isAllTime
                    ? const EmptyState(
                        icon: Icons.payments_rounded,
                        title: 'No payments yet',
                        message:
                            'Record money received or paid — cash, bank '
                            'or cheque — with the Record payment button.',
                      )
                    : EmptyState(
                        icon: Icons.payments_rounded,
                        title: 'Nothing in ${_range.label}',
                        message: _range.emptyWindowMessage('payments'),
                      ),
              )
            else if (listed.isEmpty)
              // Everything in this window is already in the strip above; an
              // empty state here would claim the shop has no payments.
              const SliverToBoxAdapter(child: SizedBox.shrink())
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 96),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final p = listed[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _paymentRow(context, repo, p),
                    );
                  }, childCount: listed.length),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The cheques that still need doing something about.
  ///
  /// Sits directly under the balances because it explains the third card: the
  /// "Cheques to deposit" figure is this list. Deliberately NOT filtered by the
  /// screen's date window — a cheque taken in the last quarter is exactly the
  /// one still waiting, and hiding it behind a "This month" pill is how a
  /// deposit gets forgotten.
  ///
  /// Each row carries the same cheque menu as the main list, so depositing one
  /// is a tap from here, and [_body] takes these rows out of the list below so
  /// the same cheque is never on screen twice. The reverse of that pairing
  /// matters too: while a search is running the strip stands down entirely,
  /// because a search has to be able to reach a cheque by number.
  Widget _chequeBucket(
    BuildContext context,
    PaymentRepository repo,
    List<PaymentEntity> cheques,
  ) {
    if (cheques.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Every uncleared cheque, not just the receipts: the header counts all of
    // them and the third card (Cheques in hand) carries both directions, so a
    // total that silently ignored the cheques the shop wrote under-reports
    // exactly the figure it sits next to.
    var inTotal = Money.zero;
    var outTotal = Money.zero;
    for (final c in cheques) {
      final amount = Money.of(c.amount);
      if (c.type == 'payment_in') {
        inTotal += amount;
      } else {
        outTotal += amount;
      }
    }
    final total = inTotal + outTotal;
    final bothWays = inTotal > Money.zero && outTotal > Money.zero;

    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.sm),
      child: AtriaCard(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long_rounded,
                  size: AppIconSize.md,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cheques.length == 1
                        ? '1 cheque awaiting clearance'
                        : '${cheques.length} cheques awaiting clearance',
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (total > Money.zero)
                  Text(
                    Formatters.money(total),
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              bothWays
                  ? 'Money in ${Formatters.money(inTotal)} · money out '
                        '${Formatters.money(outTotal)}. Deposit the ones in '
                        'hand, then mark what the bank has cleared. A bounced '
                        'cheque releases the invoice it was settling.'
                  : 'Deposit the ones in hand, then mark what the bank has '
                        'cleared. A bounced cheque releases the invoice it was '
                        'settling.',
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            // Bounded, so a backlog of cheques cannot push the search field
            // and the whole list off the bottom of an unbounded sliver.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: cheques.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _paymentRow(context, repo, cheques[index]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Applies one cheque transition and reports what happened.
  ///
  /// The bounce asks for a reason first — it is the only one of the three that
  /// changes the books, and the reason is what the follow-up call is about.
  Future<void> _runChequeAction(
    BuildContext context,
    PaymentRepository repo,
    PaymentEntity payment,
    String action,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      switch (action) {
        case 'deposit':
          await repo.markChequeDeposited(payment.id);
          messenger?.showSnackBar(
            SnackBar(content: Text('${payment.number} marked as deposited.')),
          );
        case 'clear':
          await repo.markChequeCleared(payment.id);
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                '${payment.number} cleared — the money now counts.',
              ),
            ),
          );
        case 'bounce':
          final reason = await _askBounceReason(context, payment);
          if (reason == null) return;
          await repo.markChequeBounced(payment.id, reason: reason);
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                '${payment.number} bounced — any invoice it settled is unpaid '
                'again.',
              ),
            ),
          );
      }
    } on StateError catch (error) {
      // A locked period, or something that is not a cheque. Both are worth
      // showing verbatim: the message already says what to do.
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not update the cheque: $error')),
      );
    }
  }

  Future<String?> _askBounceReason(
    BuildContext context,
    PaymentEntity payment,
  ) {
    var reason = '';
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Cheque ${payment.number} bounced'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The ${Formatters.money(Money.of(payment.amount))} this cheque '
              'was settling goes back to unpaid. Record why the bank returned '
              'it if you know.',
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              onChanged: (value) => reason = value,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'Insufficient funds',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(reason),
            child: const Text('Mark bounced'),
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(BuildContext context, AsyncValue<CashBankBalances> state) {
    // Not known yet and known to be zero are different answers. Until the
    // trial balance lands, every card says so instead of asserting a balance.
    final balances = state.valueOrNull;
    final loading = balances == null;
    final s = balances ?? const CashBankBalances();
    final cards = <Widget>[
      _SummaryCard(
        label: 'Cash in hand',
        icon: Icons.payments_rounded,
        value: Money.of(s.cash),
        tone: s.cash >= 0 ? Tone.positive : Tone.negative,
        loading: loading,
      ),
      _SummaryCard(
        label: 'Bank accounts',
        icon: Icons.account_balance_rounded,
        value: Money.of(s.bank),
        tone: s.bank >= 0 ? Tone.positive : Tone.negative,
        loading: loading,
      ),
      _SummaryCard(
        label: 'Cheques to deposit',
        icon: Icons.receipt_long_rounded,
        value: Money.of(s.cheques),
        tone: Tone.neutral,
        loading: loading,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            return Column(
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: cards[i]),
                ],
              ],
            );
          }
          return Row(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: cards[i]),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _paymentRow(
    BuildContext context,
    PaymentRepository repo,
    PaymentEntity p,
  ) {
    final isIn = p.type == 'payment_in';
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          AtriaAvatar.glyph(
            icon: isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
            tone: isIn ? AtriaAvatarTone.info : AtriaAvatarTone.danger,
            radius: AtriaAvatar.row,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.partyName ?? (isIn ? 'Cash received' : 'Cash paid'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${p.number} · ${_modeLabel(p.mode)}'
                  '${(p.reference ?? '').isNotEmpty ? ' · ${p.reference}' : ''}'
                  ' · ${Formatters.date(p.date)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (p.mode == 'cheque' &&
                    (p.chequeStatus ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  _ChequeStatusChip(
                    status: p.chequeStatus!,
                    reason: p.bounceReason,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${isIn ? '+' : '−'} ${Formatters.money(Money.of(p.amount))}',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: isIn ? scheme.secondary : scheme.error,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A cheque with nothing legal left to do (it has cleared) gets
                  // no menu at all rather than a menu of greyed-out entries.
                  if (p.mode == 'cheque' &&
                      _ChequeMenu.chequeActions(p).isNotEmpty)
                    _ChequeMenu(
                      payment: p,
                      repo: repo,
                      onAction: _runChequeAction,
                    ),
                  DocumentRowMenu(
                    docType: p.type,
                    docId: p.id,
                    number: p.number,
                    status: 'active',
                    onEdit: (menuContext, menuRef) =>
                        showPaymentEditor(menuContext, menuRef, existing: p),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _modeLabel(String mode) => switch (mode) {
    'cash' => 'Cash',
    'cheque' => 'Cheque',
    'upi' => 'UPI',
    'neft' => 'NEFT/RTGS',
    'card' => 'Card',
    _ => 'Bank',
  };
}

/// Where a cheque has got to, in one small chip.
class _ChequeStatusChip extends StatelessWidget {
  const _ChequeStatusChip({required this.status, this.reason});

  final String status;
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final (label, colour) = switch (status) {
      'pending' => ('In hand', colors.warning),
      'deposited' => ('Deposited', scheme.primary),
      'cleared' => ('Cleared', colors.positive),
      'bounced' => ('Bounced', scheme.error),
      _ => (status, scheme.onSurfaceVariant),
    };
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.12),
            borderRadius: const BorderRadius.all(
              Radius.circular(AppRadius.pill),
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: colour, fontWeight: FontWeight.w700),
          ),
        ),
        if (status == 'bounced' && (reason ?? '').isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              reason!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ],
    );
  }
}

/// The three things that can happen to a cheque.
///
/// Offered by state, from the *same* table the repository enforces
/// ([PaymentRepository.legalChequeTransitionsFrom]) — so this menu can never
/// reach an entry that would be refused. A cheque in hand can be deposited,
/// cleared or bounced; one at the bank can be cleared or bounced; one the bank
/// returned can only be deposited again, once it is re-presented; one that has
/// cleared has nothing left to do, so [chequeActions] returns nothing and the
/// row shows no menu at all. Offering "bounce" on a cleared cheque was how a
/// settled invoice got un-paid by a second tap with no warning.
class _ChequeMenu extends StatelessWidget {
  const _ChequeMenu({
    required this.payment,
    required this.repo,
    required this.onAction,
  });

  final PaymentEntity payment;
  final PaymentRepository repo;
  final Future<void> Function(
    BuildContext context,
    PaymentRepository repo,
    PaymentEntity payment,
    String action,
  )
  onAction;

  /// The entries legal from this cheque's current state, minus the no-op
  /// repeat of the state it is already in. Empty for a cleared cheque.
  static List<(String, String, IconData)> chequeActions(PaymentEntity payment) {
    final current = payment.chequeStatus ?? 'pending';
    final legal = PaymentRepository.legalChequeTransitionsFrom(current);
    const all = <(String, String, String, IconData)>[
      (
        'deposit',
        'deposited',
        'Deposit in bank',
        Icons.account_balance_rounded,
      ),
      (
        'clear',
        'cleared',
        'Mark cleared by bank',
        Icons.check_circle_outline_rounded,
      ),
      ('bounce', 'bounced', 'Mark bounced', Icons.cancel_outlined),
    ];
    return [
      for (final (action, target, label, icon) in all)
        if (target != current && legal.contains(target)) (action, label, icon),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final options = chequeActions(payment);

    return PopupMenuButton<String>(
      tooltip: 'Cheque actions',
      icon: const Icon(Icons.more_vert_rounded, size: AppIconSize.md),
      onSelected: (value) => onAction(context, repo, payment, value),
      itemBuilder: (context) => [
        for (final (value, label, icon) in options)
          PopupMenuItem<String>(
            value: value,
            child: Row(
              children: [
                Icon(icon, size: AppIconSize.md),
                const SizedBox(width: 10),
                Text(label),
              ],
            ),
          ),
      ],
    );
  }
}

enum Tone { positive, negative, neutral }

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.icon,
    required this.value,
    required this.tone,
    this.loading = false,
  });

  final String label;
  final IconData icon;
  final Decimal value;
  final Tone tone;

  /// The figure is not known yet. Shown instead of ₹0.00 — see [_balances].
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stack = constraints.maxWidth < 240;
        return AtriaCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: stack
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: AppRadius.smAll,
                      ),
                      child: Icon(
                        icon,
                        size: AppIconSize.md,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 2),
                    _figure(context, compact: true),
                  ],
                )
              : Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: AppRadius.smAll,
                      ),
                      child: Icon(
                        icon,
                        size: AppIconSize.md,
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 2),
                          _figure(context, compact: false),
                        ],
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _figure(BuildContext context, {required bool compact}) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: _FigureSkeleton(),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Text(
      // Exact on a wide window, where the card has room for the full figure;
      // compact when stacked, where a bank balance in crores would not fit
      // the narrow card either way.
      compact ? Formatters.moneyCompact(value) : Formatters.money(value),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: switch (tone) {
          Tone.positive => scheme.secondary,
          Tone.negative => scheme.error,
          Tone.neutral => scheme.onSurface,
        },
      ),
    );
  }
}

/// The "balance not known yet" placeholder for a summary card.
///
/// A gentle pulse rather than a spinner: three of these sit side by side, and a
/// spinner in each says "busy" while saying nothing about the fact that the
/// figure is missing. It mirrors the shimmer the reports screen uses for the
/// same reason. Sized like the figure it replaces so the card does not jump
/// when the real number arrives.
class _FigureSkeleton extends StatefulWidget {
  const _FigureSkeleton();

  @override
  State<_FigureSkeleton> createState() => _FigureSkeletonState();
}

class _FigureSkeletonState extends State<_FigureSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Loading balance',
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.4, end: 1).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        ),
        // A fraction of whatever width the card has, never a fixed one: at the
        // 360dp breakpoint a card is ~73dp of content, where a 84dp bar would
        // overflow and take the whole summary row's first paint down with it.
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: 0.7,
            alignment: Alignment.centerLeft,
            child: Container(
              height: 18,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet: record money IN or OUT in one form — or edit an existing
/// payment when [existing] is given.
///
/// A thin entry point only. The form itself is [_PaymentEditorSheet], a real
/// StatefulWidget, because it used to be a function that returned as soon as
/// `showModalBottomSheet` did: its five `TextEditingController`s were then
/// never disposed, the parties `watchAll().first` was an uncancelled
/// subscription, and four error paths plus a `finally` all ran `setState`
/// after `await repo.create/update` — so a sheet swiped away mid-write threw
/// `setState() called after dispose`.
Future<void> showPaymentEditor(
  BuildContext context,
  WidgetRef ref, {
  PaymentEntity? existing,
}) async {
  final repo = ref.read(paymentRepositoryProvider);
  final firmId = ref.read(activeFirmIdProvider);
  if (repo == null || firmId == null) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _PaymentEditorSheet(
      repository: repo,
      firmId: firmId,
      existing: existing,
    ),
  );
}

/// The record / edit payment form.
class _PaymentEditorSheet extends ConsumerStatefulWidget {
  const _PaymentEditorSheet({
    required this.repository,
    required this.firmId,
    this.existing,
  });

  final PaymentRepository repository;
  final String firmId;
  final PaymentEntity? existing;

  @override
  ConsumerState<_PaymentEditorSheet> createState() =>
      _PaymentEditorSheetState();
}

class _PaymentEditorSheetState extends ConsumerState<_PaymentEditorSheet> {
  /// The type lives in a controller rather than a field because it is chosen
  /// by a [SegmentedButton] and read twice (the sequence, and the row itself).
  late final TextEditingController _typeController;

  /// Holds the party's ID, while the visible field holds its name.
  late final TextEditingController _partyController;
  late final TextEditingController _amountController;
  late final TextEditingController _referenceController;
  late final TextEditingController _notesController;

  String _mode = 'cash';
  DateTime _date = DateTime.now();
  List<PartyEntity> _parties = const [];

  /// The account the money moved through, by name — the same shape the
  /// repository's `bankAccount` column has always held, and which
  /// `PaymentRepository` resolves into `bankAccountId`.
  String? _bankAccount;
  String? _bankAccountId;
  bool _accountChosen = false;

  /// The firm's accounts, so the picker can offer them. Empty means the firm has
  /// set none up, and the picker then renders nothing at all rather than an
  /// empty dropdown.
  List<BankAccountEntity> _accounts = const [];
  StreamSubscription<List<BankAccountEntity>>? _accountsSub;
  String? _amountError;
  bool _submitting = false;

  /// The name currently showing in the party field, so a retyped or cleared
  /// field can un-set the selection (previously the id stuck and the edit kept
  /// writing to a party the user had removed from the form).
  String? _selectedPartyName;
  bool _partyNameSeeded = false;

  StreamSubscription<List<PartyEntity>>? _partiesSub;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _typeController = TextEditingController(
      text: existing?.type ?? 'payment_in',
    );
    _partyController = TextEditingController(text: existing?.partyId ?? '');
    _amountController = TextEditingController(
      text: existing == null
          ? ''
          : (existing.amount == existing.amount.roundToDouble()
                ? existing.amount.toInt().toString()
                : existing.amount.toStringAsFixed(2)),
    );
    _referenceController = TextEditingController(
      text: existing?.reference ?? '',
    );
    _notesController = TextEditingController(text: existing?.notes ?? '');
    _mode = existing?.mode ?? 'cash';
    _date = existing?.date ?? DateTime.now();
    _selectedPartyName = existing?.partyName;
    // The name, not the id: `bankAccount` is the free-text column every caller
    // has always written, and the repository resolves it against the account
    // list on the way in.
    _bankAccountId = existing?.bankAccountId;
    _bankAccount = (existing?.bankAccount ?? '').trim().isEmpty
        ? null
        : existing!.bankAccount!.trim();

    // A subscription, not `.first.then(...)`: `.first` still opens the query,
    // and its `.then` was neither cancellable nor guarded, so it resolved
    // against a sheet that had already been dismissed.
    final partyRepo = ref.read(partyRepositoryProvider);
    if (partyRepo != null) {
      _partiesSub = partyRepo.watchAll().listen((list) {
        if (!mounted) return;
        setState(() => _parties = list);
      });
    }

    // Live, so an account added in Settings appears without reopening this
    // sheet — the same reason the party list is a subscription.
    final db = ref.read(appDatabaseProvider);
    final firmId = ref.read(activeFirmIdProvider);
    if (firmId != null) {
      final query = db.select(db.bankAccounts)
        ..where((a) => a.firmId.equals(firmId) & a.isArchived.equals(false))
        ..orderBy([(a) => OrderingTerm.asc(a.name)]);
      _accountsSub = query.watch().listen((list) {
        if (!mounted) return;
        setState(() {
          _accounts = list;
          if (!_accountChosen) {
            for (final account in list) {
              if (account.id == _bankAccountId ||
                  (_bankAccountId == null && account.name == _bankAccount)) {
                _bankAccountId = account.id;
                _bankAccount = account.name;
                break;
              }
            }
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _partiesSub?.cancel();
    _accountsSub?.cancel();
    _typeController.dispose();
    _partyController.dispose();
    _amountController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  static String? _trimmedOrNull(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Records a payment. Returns true when the row is written (the sheet may
  /// close), false to keep it open with the reason showing.
  Future<bool> _submit() async {
    if (_submitting) return false;
    // Grouped input ("1,000") used to double.parse to a silent no-op;
    // Money.parse understands Indian grouping and throws with a reason.
    final Decimal amount;
    try {
      amount = Money.parse(_amountController.text.trim());
    } on FormatException {
      setState(() => _amountError = 'Enter a valid amount');
      return false;
    }
    if (amount <= Decimal.zero) {
      setState(() => _amountError = 'Amount must be greater than zero');
      return false;
    }
    setState(() {
      _amountError = null;
      _submitting = true;
    });
    // Captured before the first await: the sheet can be swiped away mid-write,
    // and by then this State's context is gone — but the messenger belongs to
    // the app, and it is exactly where a failed save has to be reported.
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final partyId = _partyController.text.trim();
      final party = _parties
          .where((p) => p.id == partyId)
          .cast<PartyEntity?>()
          .firstWhere((p) => p != null, orElse: () => null);
      final firm = await ref
          .read(firmRepositoryProvider)
          .getById(widget.firmId);
      if (firm == null) {
        if (mounted) setState(() => _submitting = false);
        return false;
      }
      final existing = widget.existing;
      final number = existing != null
          ? existing.number
          : await ref
                .read(firmRepositoryProvider)
                .nextNumber(
                  firm,
                  _typeController.text == 'payment_in'
                      ? DocSequence.paymentIn
                      : DocSequence.paymentOut,
                  date: _date,
                );
      if (existing != null) {
        // An edit keeps the payment's number and its link to a document;
        // the repository recomputes that document's balances afterwards.
        await widget.repository.update(
          existing.copyWith(
            type: _typeController.text,
            partyId: Value(party?.id),
            partyName: Value(party?.name),
            amount: amount.toDouble(),
            date: _date,
            mode: _mode,
            reference: Value(_trimmedOrNull(_referenceController.text)),
            notes: Value(_trimmedOrNull(_notesController.text)),
            bankAccount: Value(_bankAccount),
            bankAccountId: Value(_bankAccountId),
          ),
        );
      } else {
        await widget.repository.create(
          type: _typeController.text,
          number: number,
          partyId: party?.id,
          partyName: party?.name,
          amount: amount.toDouble(),
          date: _date,
          mode: _mode,
          reference: _trimmedOrNull(_referenceController.text),
          notes: _trimmedOrNull(_notesController.text),
          // The account name. The repository resolves it to `bankAccountId`
          // and maintains the account's cached balance — see `create`.
          bankAccount: _bankAccount,
          bankAccountId: _bankAccountId,
        );
      }
      return true;
    } catch (e) {
      final message = 'Could not save: $e';
      if (mounted) {
        setState(() => _amountError = message);
      } else {
        // The sheet is gone and the row was NOT written, so the operator has to
        // be told — via the messenger, not through a disposed State.
        messenger?.showSnackBar(SnackBar(content: Text(message)));
      }
      return false;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The account picker, or nothing when the firm has set none up.
  ///
  /// Returns an empty box rather than a disabled field when there are no
  /// accounts: an empty dropdown invites the question "why is this grey?", and
  /// the answer is only discoverable in Settings.
  Widget _accountField() {
    final accounts = _accounts;
    if (accounts.isEmpty && _bankAccountId == null) {
      return const SizedBox.shrink();
    }
    final missing =
        _bankAccountId != null && !accounts.any((a) => a.id == _bankAccountId);
    return DropdownButtonFormField<String>(
      key: ValueKey(_bankAccountId),
      iconSize: AppIconSize.md,
      initialValue: _bankAccountId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Account',
        helperText: 'Feeds the Bank Statement report',
      ),
      items: [
        const DropdownMenuItem<String>(
          value: null,
          child: Text('Not specified'),
        ),
        for (final account in accounts)
          DropdownMenuItem<String>(
            value: account.id,
            child: Text(account.name),
          ),
        if (missing)
          DropdownMenuItem<String>(
            value: _bankAccountId,
            child: Text(_bankAccount ?? 'Archived account'),
          ),
      ],
      onChanged: (id) => setState(() {
        _accountChosen = true;
        _bankAccountId = id;
        _bankAccount = null;
        for (final account in accounts) {
          if (account.id == id) {
            _bankAccount = account.name;
            break;
          }
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'payment_in', label: Text('Money in')),
              ButtonSegment(value: 'payment_out', label: Text('Money out')),
            ],
            selected: {_typeController.text},
            onSelectionChanged: (s) =>
                setState(() => _typeController.text = s.first),
          ),
          const SizedBox(height: 12),
          Autocomplete<PartyEntity>(
            displayStringForOption: (p) => p.name,
            optionsBuilder: (v) => _parties.where(
              (p) => p.name.toLowerCase().contains(v.text.trim().toLowerCase()),
            ),
            onSelected: (p) {
              _partyController.text = p.id;
              _selectedPartyName = p.name;
            },
            fieldViewBuilder: (context, c, focus, onSubmit) {
              if (_isEdit && !_partyNameSeeded) {
                _partyNameSeeded = true;
                c.text = widget.existing?.partyName ?? '';
              }
              return TextField(
                controller: c,
                onChanged: (t) {
                  // Cleared or retyped without picking a suggestion =
                  // no party (or not yet chosen).
                  if (t.trim() != (_selectedPartyName ?? '')) {
                    _partyController.text = '';
                  }
                },
                decoration: const InputDecoration(
                  labelText: 'Party (optional)',
                  prefixIcon: AtriaFieldIcon(Icons.person_outline_rounded),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Amount *',
              prefixText: '₹ ',
              errorText: _amountError,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            iconSize: AppIconSize.md,
            initialValue: _mode,
            decoration: const InputDecoration(labelText: 'Mode'),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'bank', child: Text('Bank')),
              DropdownMenuItem(
                value: 'bank_transfer',
                child: Text('Bank Transfer (NEFT/RTGS/IMPS)'),
              ),
              DropdownMenuItem(value: 'upi', child: Text('UPI')),
              DropdownMenuItem(value: 'neft', child: Text('NEFT/RTGS')),
              DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
              DropdownMenuItem(value: 'card', child: Text('Card')),
              DropdownMenuItem(value: 'other', child: Text('Other')),
            ],
            onChanged: (v) => setState(() => _mode = v ?? 'cash'),
          ),
          const SizedBox(height: 12),
          // Which account the money moved through.
          //
          // Without this the Bank Statement has nothing to report: the report
          // keys on `payments.bankAccountId`, and the only thing that ever set
          // it was `PaymentRepository`'s name match against an account the
          // operator had never been able to create. A shop with three accounts
          // could record *that* money moved but never *which*, which is the
          // whole question the report answers.
          //
          // Optional on purpose — a counter sale paid out of the drawer is still
          // a legitimate payment — but an account that exists and is never
          // chosen is a silent hole in the books.
          _accountField(),
          const SizedBox(height: 12),
          TextField(
            controller: _referenceController,
            decoration: const InputDecoration(
              labelText: 'Reference / cheque no.',
            ),
          ),
          const SizedBox(height: 12),
          // The notes controller existed but nothing ever rendered it —
          // anything typed into notes elsewhere had no counterpart here.
          TextField(
            controller: _notesController,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Notes'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submitting
                ? null
                : () async {
                    final ok = await _submit();
                    if (ok && context.mounted) Navigator.of(context).pop();
                  },
            child: Text(
              _submitting
                  ? 'Saving…'
                  : _isEdit
                  ? 'Save changes'
                  : 'Save payment',
            ),
          ),
        ],
      ),
    );
  }
}
