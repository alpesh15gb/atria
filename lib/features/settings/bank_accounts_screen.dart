import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/bank_account_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';
import '../../shared/widgets/money_text.dart';

/// The accounts and cash boxes the business holds.
///
/// **This screen is why the Bank Statement report can show anything at all.**
///
/// `bank_accounts` arrived in schema v12 as the table that makes a statement
/// possible — `payments.bankAccount` is free text, which is enough to *record*
/// that money went somewhere and not enough to answer "what is the balance, and
/// what happened in this account over this window". But nothing ever wrote to
/// it and nothing ever created a row: there was no UI here, and no payment was
/// ever linked to an account. The report was therefore permanently empty, and
/// its opening-balance derivation — the one number a bank reconciliation exists
/// to check — was reading a column nothing maintained.
///
/// Two things make it work, both outside this file:
/// `PaymentRepository` resolves `payments.bankAccountId` from the account name
/// and maintains `currentBalance` on every create, edit, delete and restore; and
/// `bankStatementRows` walks the opening balance back from that closing figure.
///
/// **Cash in hand is a row here, not the absence of one.** `BankAccounts.type`
/// deliberately includes `cash`, because the Bank Statement lists cash beside
/// the bank accounts and special-casing a missing row would make the accounts
/// list a lie.
class BankAccountsScreen extends ConsumerWidget {
  const BankAccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firmId = ref.watch(activeFirmIdProvider);
    final scheme = Theme.of(context).colorScheme;

    if (firmId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bank & Cash')),
        body: const Center(child: Text('Open a business first.')),
      );
    }

    final db = ref.watch(appDatabaseProvider);
    final query = db.select(db.bankAccounts)
      ..where((a) => a.firmId.equals(firmId) & a.isArchived.equals(false))
      ..orderBy([(a) => OrderingTerm.asc(a.name)]);

    return Scaffold(
      appBar: AppBar(
        // The More sheet navigates with `go`, which leaves `Navigator.canPop()`
        // false — a bare `AppBar` would then draw no back button at all. An
        // explicit leading is what makes this screen escapable.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back',
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/settings'),
        ),
        title: const Text('Bank & Cash'),
        actions: [TextButton.icon(onPressed: () => context.push('/settings/bank-reconciliation'), icon: const Icon(Icons.compare_arrows), label: const Text('Reconcile statement'))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref, firmId, null),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add account'),
      ),
      body: StreamBuilder<List<BankAccountEntity>>(
        stream: query.watch(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return EmptyState(
              icon: PhosphorIconsRegular.warningCircle,
              title: 'Could not load your accounts',
              message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data!;
          if (rows.isEmpty) {
            return EmptyState(
              icon: PhosphorIconsRegular.bank,
              title: 'No accounts yet',
              message:
                  'Add the bank accounts you use and a cash box, then pick one '
                  'when you record a payment. The Bank Statement report reads '
                  'these — without them it has nothing to show.',
              actionLabel: 'Add account',
              onAction: () => _edit(context, ref, firmId, null),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              Text(
                'The Bank Statement report reads these accounts, and the '
                'balance shown here is kept up to date as you record payments.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpace.md),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _Tile(
                    row: row,
                    onEdit: () => _edit(context, ref, firmId, row),
                    onArchive: () => _archive(context, ref, firmId, row),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _archive(
    BuildContext context,
    WidgetRef ref,
    String firmId,
    BankAccountEntity row,
  ) async {
    final ok = await confirmDestructive(
      context,
      title: 'Archive ${row.name}?',
      message:
          'It stops appearing in the account list. Payments already recorded '
          'against it keep their history and the Bank Statement still shows '
          'them. Nothing is deleted.',
      confirmLabel: 'Archive',
    );
    if (!ok) return;
    final db = ref.read(appDatabaseProvider);
    await BankAccountRepository(db, firmId).archive(row.id);
  }
}

Future<void> _edit(
  BuildContext context,
  WidgetRef ref,
  String firmId,
  BankAccountEntity? existing,
) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _AccountSheet(firmId: firmId, existing: existing),
  );
  if (saved != true || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(existing == null ? 'Account added.' : 'Account updated.'),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.row,
    required this.onEdit,
    required this.onArchive,
  });

  final BankAccountEntity row;
  final VoidCallback onEdit;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cash = row.type == 'cash';
    final number = (row.accountNumber ?? '').trim();
    return AtriaCard(
      onTap: onEdit,
      child: Row(
        children: [
          PhosphorIcon(
            cash ? PhosphorIconsRegular.money : PhosphorIconsRegular.bank,
            color: scheme.primary,
            size: 22,
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    cash ? 'Cash in hand' : (row.bankName ?? 'Bank account'),
                    if (number.length > 4)
                      '••${number.substring(number.length - 4)}',
                    if ((row.upiId ?? '').trim().isNotEmpty) row.upiId!.trim(),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          MoneyText(
            Decimal.parse(row.currentBalance.toStringAsFixed(2)),
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          IconButton(
            onPressed: onArchive,
            tooltip: 'Archive ${row.name}',
            icon: const Icon(Icons.archive_outlined),
          ),
        ],
      ),
    );
  }
}

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet({required this.firmId, this.existing});

  final String firmId;
  final BankAccountEntity? existing;

  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _bankName;
  late final TextEditingController _accountNumber;
  late final TextEditingController _ifsc;
  late final TextEditingController _holder;
  late final TextEditingController _notes;
  late final TextEditingController _balance;
  String _type = 'bank';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _bankName = TextEditingController(text: e?.bankName ?? '');
    _accountNumber = TextEditingController(text: e?.accountNumber ?? '');
    _ifsc = TextEditingController(text: e?.ifsc ?? '');
    _holder = TextEditingController(text: e?.accountHolder ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _balance = TextEditingController(
      text: e == null ? '' : e.openingBalance.toStringAsFixed(2),
    );
    _type = e?.type ?? 'bank';
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _bankName,
      _accountNumber,
      _ifsc,
      _holder,
      _notes,
      _balance,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A balance may legitimately be negative (an overdraft), so a leading `-` is
  /// accepted here even though document amounts reject it.
  static Decimal? _amount(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return Decimal.zero;
    return Money.tryParse(text);
  }

  static String? _nullable(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit account' : 'Add account'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                ],
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'bank', label: Text('Bank')),
                    ButtonSegment(value: 'cash', label: Text('Cash')),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'HDFC main',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Give the account a name you will recognise.'
                      : null,
                ),
                if (_type == 'bank') ...[
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: _bankName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Bank'),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: _accountNumber,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Account number',
                    ),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: _ifsc,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(labelText: 'IFSC'),
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: _holder,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Account holder',
                    ),
                  ),
                ],
                const SizedBox(height: AppSpace.sm),
                TextFormField(
                  controller: _balance,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  ),
                  inputFormatters: [IndianAmountInputFormatter(signed: true)],
                  decoration: InputDecoration(
                    labelText: 'Opening balance',
                    prefixText: Formatters.money(Decimal.zero).split('0')[0],
                    helperText: 'Balance before recorded payments. Current balance is calculated automatically.',
                    helperMaxLines: 2,
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? null
                      : _amount(v) == null
                      ? 'That is not an amount.'
                      : null,
                ),
                const SizedBox(height: AppSpace.sm),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = ref.read(appDatabaseProvider);
      final existing = widget.existing;
      final balance = (_amount(_balance.text) ?? Decimal.zero).toDouble();
      await BankAccountRepository(db, widget.firmId).save(
        BankAccountsCompanion(
          id: Value(
            existing?.id ?? 'bac_${DateTime.now().microsecondsSinceEpoch}',
          ),
          firmId: Value(widget.firmId),
          name: Value(_name.text.trim()),
          bankName: Value(_nullable(_bankName.text)),
          accountNumber: Value(_nullable(_accountNumber.text)),
          ifsc: Value(_nullable(_ifsc.text)),
          accountHolder: Value(_nullable(_holder.text)),
          type: Value(_type),
          // Editing a name must not overwrite receipts recorded while this
          // dialog was open. Only the opening is editable; totals are derived.
          openingBalance: Value(balance),
          currentBalance: Value(balance),
          notes: Value(_nullable(_notes.text)),
          isArchived: const Value(false),
          updatedAt: Value(DateTime.now()),
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        // Never a raw `SqliteException` in a shopkeeper's face — see
        // `atriaErrorMessage`.
        _error = atriaErrorMessage(
          error,
          retry: 'Check the details and try again.',
        );
      });
    }
  }
}
