import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/payment_repository.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
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

/// Payments In/Out: every receipt and payment with mode breakdown
/// (cash / bank / cheque), Vyapar's Payments page. FAB opens the editor.
class PaymentsScreen extends ConsumerStatefulWidget {
  const PaymentsScreen({super.key});

  @override
  ConsumerState<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends ConsumerState<PaymentsScreen> {
  _PaymentFilter _filter = _PaymentFilter.all;
  final _searchController = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(paymentRepositoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Payments')),
      floatingActionButton: repo == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showEditor(context, ref),
              icon: const Icon(Icons.add_card_rounded),
              label: const Text('Add Payment'),
            ),
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
      stream: repo.watchList(
          type: _filter == _PaymentFilter.all
              ? null
              : _filter == _PaymentFilter.paymentIn
                  ? 'payment_in'
                  : 'payment_out',
          limit: 2000),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not load payments',
            message: '${snapshot.error}',
          );
        }
        var payments = snapshot.data ?? const <PaymentEntity>[];
        final query = _search.toLowerCase();
        if (query.isNotEmpty) {
          payments = payments
              .where((p) =>
                  (p.partyName ?? '').toLowerCase().contains(query) ||
                  p.number.toLowerCase().contains(query) ||
                  (p.reference ?? '').toLowerCase().contains(query))
              .toList(growable: false);
        }

        final summary = _summarize(snapshot.data ?? const []);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _summaryRow(context, summary)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() => _search = v.trim()),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: 'Search party, number or reference',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final f in _PaymentFilter.values)
                      FilterChip(
                        label: Text(switch (f) {
                          _PaymentFilter.all => 'All',
                          _PaymentFilter.paymentIn => 'Money in',
                          _PaymentFilter.paymentOut => 'Money out',
                        }),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                  ],
                ),
              ),
            ),
            if (payments.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.payments_rounded,
                  title: 'No payments yet',
                  message: 'Record money received or paid — cash, bank or '
                      'cheque — with the Add Payment button.',
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final p = payments[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _paymentRow(context, repo, p),
                      );
                    },
                    childCount: payments.length,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  CashBankSummary _summarize(List<PaymentEntity> payments) {
    final s = CashBankSummary();
    for (final p in payments) {
      if (p.isDeleted) continue;
      final isIn = p.type == 'payment_in';
      switch (p.mode) {
        case 'cash':
          isIn ? s.cashIn += p.amount : s.cashOut += p.amount;
          break;
        case 'cheque':
          if (isIn) s.chequeIn += p.amount;
          break;
        default: // bank / upi / card / neft
          isIn ? s.bankIn += p.amount : s.bankOut += p.amount;
      }
    }
    return s;
  }

  Widget _summaryRow(BuildContext context, CashBankSummary s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _SummaryCard(
              label: 'Cash in hand',
              icon: Icons.payments_rounded,
              value: Money.of(s.cashBalance),
              tone: s.cashBalance >= 0 ? Tone.positive : Tone.negative,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SummaryCard(
              label: 'Bank accounts',
              icon: Icons.account_balance_rounded,
              value: Money.of(s.bankBalance),
              tone: s.bankBalance >= 0 ? Tone.positive : Tone.negative,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SummaryCard(
              label: 'Cheques to deposit',
              icon: Icons.receipt_long_rounded,
              value: Money.of(s.chequeIn),
              tone: Tone.neutral,
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentRow(
      BuildContext context, PaymentRepository repo, PaymentEntity p) {
    final isIn = p.type == 'payment_in';
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor:
                isIn ? scheme.secondaryContainer : scheme.errorContainer,
            child: Icon(
              isIn ? Icons.south_west_rounded : Icons.north_east_rounded,
              size: 19,
              color: isIn ? scheme.secondary : scheme.error,
            ),
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
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  '${p.number} · ${_modeLabel(p.mode)}'
                  '${(p.reference ?? '').isNotEmpty ? ' · ${p.reference}' : ''}'
                  ' · ${Formatters.date(p.date)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [                Text(
                  '${isIn ? '+' : '−'} ${Formatters.money(Money.of(p.amount))}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isIn ? scheme.secondary : scheme.error,
                      ),
                ),
              RowActionsButton(
                actions: [
                  RowAction(
                    label: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    destructive: true,
                    onSelected: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Delete payment?'),
                          content: const Text(
                              'It moves to the recycle bin and can be '
                              'restored from there.'),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton.tonal(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await repo.softDelete(p.id);
                      }
                    },
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

enum Tone { positive, negative, neutral }

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.icon,
    required this.value,
    required this.tone,
  });

  final String label;
  final IconData icon;
  final Decimal value;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: const BorderRadius.all(Radius.circular(10)),
            ),
            child: Icon(icon, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  Formatters.money(value),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: switch (tone) {
                          Tone.positive => scheme.secondary,
                          Tone.negative => scheme.error,
                          Tone.neutral => scheme.onSurface,
                        },
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet: record money IN or OUT in one form.
Future<void> _showEditor(BuildContext context, WidgetRef ref) async {
  final repo = ref.read(paymentRepositoryProvider);
  final partyRepo = ref.read(partyRepositoryProvider);
  final firmId = ref.read(activeFirmIdProvider);
  if (repo == null || partyRepo == null || firmId == null) return;

  final typeController = TextEditingController(text: 'payment_in');
  final partyController = TextEditingController();
  final amountController = TextEditingController();
  final referenceController = TextEditingController();
  final notesController = TextEditingController();
  String mode = 'cash';
  DateTime date = DateTime.now();
  List<PartyEntity> parties = [];
  String? amountError;
  bool submitting = false;

  /// Records a payment; returns true on success (the sheet closes), false
  /// keeps the sheet open with the reason visible.
  Future<bool> submit(StateSetter setSheetState) async {
    if (submitting) return false;
    // Grouped input ("1,000") used to double.parse to a silent no-op;
    // Money.parse understands Indian grouping and throws with a reason.
    final Decimal amount;
    try {
      amount = Money.parse(amountController.text.trim());
    } on FormatException {
      setSheetState(() => amountError = 'Enter a valid amount');
      return false;
    }
    if (amount <= Decimal.zero) {
      setSheetState(() => amountError = 'Amount must be greater than zero');
      return false;
    }
    setSheetState(() {
      amountError = null;
      submitting = true;
    });
    try {
      final partyId = partyController.text.trim();
      final party = parties
          .where((p) => p.id == partyId)
          .cast<PartyEntity?>()
          .firstWhere((p) => p != null, orElse: () => null);
      final firm = await ref.read(firmRepositoryProvider).getById(firmId);
      if (firm == null) {
        setSheetState(() => submitting = false);
        return false;
      }
      final number = await ref.read(firmRepositoryProvider).nextNumber(
            firm,
            typeController.text == 'payment_in'
                ? DocSequence.paymentIn
                : DocSequence.paymentOut,
            date: date,
          );
      await repo.create(
        type: typeController.text,
        number: number,
        partyId: party?.id,
        partyName: party?.name,
        amount: amount.toDouble(),
        date: date,
        mode: mode,
        reference: referenceController.text.trim().isEmpty
            ? null
            : referenceController.text.trim(),
        notes: notesController.text.trim().isEmpty
            ? null
            : notesController.text.trim(),
      );
      return true;
    } catch (e) {
      setSheetState(() => amountError = 'Could not save: $e');
      return false;
    } finally {
      setSheetState(() => submitting = false);
    }
  }

  final partiesStream = partyRepo.watchAll();
  partiesStream.first.then((list) {
    parties = list;
  });

  // ignore: use_build_context_synchronously
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
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
              selected: {typeController.text},
              onSelectionChanged: (s) =>
                  setSheetState(() => typeController.text = s.first),
            ),
            const SizedBox(height: 12),
            Autocomplete<PartyEntity>(
              displayStringForOption: (p) => p.name,
              optionsBuilder: (v) => parties.where((p) => p.name
                  .toLowerCase()
                  .contains(v.text.trim().toLowerCase())),
              onSelected: (p) => partyController.text = p.id,
              fieldViewBuilder: (context, c, focus, onSubmit) => TextField(
                controller: c,
                decoration: const InputDecoration(
                  labelText: 'Party (optional)',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount *',
                prefixText: '₹ ',
                errorText: amountError,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(labelText: 'Mode'),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('Cash')),
                DropdownMenuItem(value: 'bank', child: Text('Bank')),
                DropdownMenuItem(value: 'upi', child: Text('UPI')),
                DropdownMenuItem(value: 'neft', child: Text('NEFT/RTGS')),
                DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
                DropdownMenuItem(value: 'card', child: Text('Card')),
              ],
              onChanged: (v) => setSheetState(() => mode = v ?? 'cash'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: referenceController,
              decoration: const InputDecoration(
                labelText: 'Reference / cheque no.',
              ),
            ),
            const SizedBox(height: 12),
            // The notes controller existed but nothing ever rendered it —
            // anything typed into notes elsewhere had no counterpart here.
            TextField(
              controller: notesController,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Notes',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: submitting
                  ? null
                  : () async {
                      final ok = await submit(setSheetState);
                      if (ok && sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
              child: Text(submitting ? 'Saving…' : 'Save payment'),
            ),
          ],
        ),
      ),
    ),
  );
}
