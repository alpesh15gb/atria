import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/ledger_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/status_chip.dart';

/// The chart of accounts: every account the books post into.
///
/// Before this screen existed the app had no accounts at all. It could say how
/// much was sold and how much was owed to each party, but there was nothing to
/// put a capital contribution, a depreciation charge or an opening balance
/// against — and no way to see whether the books added up.
class ChartOfAccountsScreen extends ConsumerStatefulWidget {
  const ChartOfAccountsScreen({super.key});

  static const String routePath = '/ledger';

  @override
  ConsumerState<ChartOfAccountsScreen> createState() =>
      _ChartOfAccountsScreenState();
}

class _ChartOfAccountsScreenState extends ConsumerState<ChartOfAccountsScreen> {
  String _search = '';
  String _type = 'all';
  bool _showArchived = false;

  @override
  Widget build(BuildContext context) {
    // No seeding here on purpose. The chart is written once at launch (see
    // `AtriaApp._seedChart`) and by any report that needs it; a screen that
    // wrote on build would leave a transaction in flight whenever it was
    // disposed mid-write, which is how a teardown hangs.
    final accounts = ref.watch(chartOfAccountsProvider);

    return AtriaListPage(
      title: 'Chart of accounts',
      subtitle:
          'Every account the books post into. Balances come from your '
          'documents and journal vouchers.',
      actions: [
        AtriaHeaderIconAction(
          icon: PhosphorIconsRegular.scales,
          tooltip: 'Trial balance',
          onPressed: () => context.push('/ledger/trial-balance'),
        ),
        AtriaHeaderIconAction(
          icon: PhosphorIconsRegular.books,
          tooltip: 'Journal entries',
          onPressed: () => context.push('/ledger/journals'),
        ),
        AtriaPrimaryAction(
          label: 'New account',
          icon: PhosphorIconsRegular.plus,
          onPressed: () => _openEditor(),
        ),
      ],
      search: TextField(
        decoration: const InputDecoration(
          hintText: 'Search by name, code or group',
          prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass),
        ),
        onChanged: (value) => setState(() => _search = value),
      ),
      filters: [
        AtriaAdaptiveFilter<String>(
          label: 'Type',
          value: _type,
          onChanged: (value) => setState(() => _type = value),
          segments: const [
            AtriaSegment(value: 'all', label: 'All'),
            AtriaSegment(value: 'asset', label: 'Assets'),
            AtriaSegment(value: 'liability', label: 'Liabilities'),
            AtriaSegment(value: 'equity', label: 'Equity'),
            AtriaSegment(value: 'income', label: 'Income'),
            AtriaSegment(value: 'expense', label: 'Expenses'),
          ],
        ),
      ],
      toolbar: [
        Row(
          children: [
            Expanded(
              child: Text(
                _showArchived
                    ? 'Showing archived accounts'
                    : 'Archived accounts are hidden',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showArchived = !_showArchived),
              child: Text(_showArchived ? 'Hide archived' : 'Show archived'),
            ),
          ],
        ),
      ],
      body: accounts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: PhosphorIconsRegular.warningCircle,
          title: 'Could not load the chart',
          message: '$error',
        ),
        data: (rows) {
          final visible = rows.where(_matches).toList();
          if (visible.isEmpty) {
            return EmptyState(
              icon: PhosphorIconsRegular.bookOpen,
              title: rows.isEmpty ? 'No accounts yet' : 'Nothing matches',
              message: rows.isEmpty
                  ? 'The standard chart is created the first time you open '
                        'this screen.'
                  : 'Try a different search or type.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: AppSpace.xxl),
            children: _grouped(visible),
          );
        },
      ),
    );
  }

  bool _matches(AccountEntity account) {
    if (!_showArchived && !account.isActive) return false;
    if (_type != 'all' && account.type != _type) return false;
    if (_search.trim().isEmpty) return true;
    final q = _search.trim().toLowerCase();
    return account.name.toLowerCase().contains(q) ||
        account.code.toLowerCase().contains(q) ||
        account.groupName.toLowerCase().contains(q);
  }

  /// Accounts print under their type, in the order a balance sheet reads —
  /// which is also the order of the code ranges, so the list never surprises
  /// anybody who knows the numbering.
  List<Widget> _grouped(List<AccountEntity> accounts) {
    const order = ['asset', 'liability', 'equity', 'income', 'expense'];
    const titles = {
      'asset': 'Assets',
      'liability': 'Liabilities',
      'equity': 'Equity',
      'income': 'Income',
      'expense': 'Expenses',
    };
    final widgets = <Widget>[];
    for (final type in order) {
      final group = accounts.where((a) => a.type == type).toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      if (group.isEmpty) continue;
      widgets.add(
        SectionHeader(
          title: titles[type]!,
          subtitle: '${group.length} account${group.length == 1 ? '' : 's'}',
          padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.sm),
        ),
      );
      for (final account in group) {
        widgets.add(
          _AccountRow(
            account: account,
            onOpen: () => context.push('/ledger/account/${account.id}'),
            onEdit: () => _openEditor(account: account),
            onArchive: () => _toggleArchived(account),
            onDelete: account.isSystem ? null : () => _delete(account),
          ),
        );
      }
    }
    return widgets;
  }

  Future<void> _openEditor({AccountEntity? account}) async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AccountSheet(repo: repo, account: account),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(account == null ? 'Account added' : 'Account saved'),
        ),
      );
    }
  }

  Future<void> _toggleArchived(AccountEntity account) async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.setAccountActive(account.id, !account.isActive);
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _delete(AccountEntity account) async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${account.name}?'),
        content: const Text(
          'The account disappears from the chart. Journal vouchers that use '
          'it keep working, so if it has any, archive it instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repo.deleteAccount(account.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${account.name} deleted')));
      }
    } catch (error) {
      _report(error);
    }
  }

  void _report(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error'.replaceFirst('Bad state: ', ''))),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.account,
    required this.onOpen,
    required this.onEdit,
    required this.onArchive,
    this.onDelete,
  });

  final AccountEntity account;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AtriaCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              account.code,
              style: text.bodyMedium?.copyWith(
                color: muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      // `overflow` without `maxLines` wraps instead of
                      // truncating: a long name against a System chip at 360dp
                      // folded this into a tall vertical strip, pushing the
                      // row's columns out of line with each other.
                      child: Text(
                        account.name,
                        style: text.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (account.isSystem) ...[
                      const SizedBox(width: AppSpace.sm),
                      const StatusChip(label: 'System', kind: ChipKind.neutral),
                    ],
                    if (!account.isActive) ...[
                      const SizedBox(width: AppSpace.sm),
                      const StatusChip(
                        label: 'Archived',
                        kind: ChipKind.warning,
                      ),
                    ],
                  ],
                ),
                if (account.groupName.isNotEmpty)
                  Text(account.groupName, style: text.bodySmall),
              ],
            ),
          ),
          if (account.openingBalance != 0)
            Text(
              'Opening ${account.openingType == 'cr' ? 'Cr' : 'Dr'} '
              '${account.openingBalance.toStringAsFixed(2)}',
              style: text.bodySmall,
            ),
          PopupMenuButton<String>(
            tooltip: 'Account actions',
            onSelected: (value) {
              switch (value) {
                case 'open':
                  onOpen();
                  break;
                case 'edit':
                  onEdit();
                  break;
                case 'archive':
                  onArchive();
                  break;
                case 'delete':
                  onDelete?.call();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'open', child: Text('Open ledger')),
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: 'archive',
                child: Text(account.isActive ? 'Archive' : 'Reactivate'),
              ),
              if (onDelete != null)
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }
}

/// The add/edit sheet. Codes are suggested but editable, because every
/// accountant has their own numbering they would rather keep.
class _AccountSheet extends StatefulWidget {
  const _AccountSheet({required this.repo, this.account});

  final LedgerRepository repo;
  final AccountEntity? account;

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _group;
  late final TextEditingController _opening;
  late final TextEditingController _description;
  late String _type;
  late String _openingType;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    _name = TextEditingController(text: account?.name ?? '');
    _code = TextEditingController(text: account?.code ?? '');
    _group = TextEditingController(text: account?.groupName ?? '');
    _opening = TextEditingController(
      text: (account?.openingBalance ?? 0) == 0
          ? ''
          : account!.openingBalance.toStringAsFixed(2),
    );
    _description = TextEditingController(text: account?.description ?? '');
    _type = account?.type ?? 'expense';
    _openingType = account?.openingType ?? 'dr';
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _group.dispose();
    _opening.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.account != null;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpace.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              editing ? 'Edit account' : 'New account',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpace.lg),
            TextField(
              controller: _name,
              autofocus: !editing,
              decoration: const InputDecoration(labelText: 'Account name'),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: const [
                      DropdownMenuItem(value: 'asset', child: Text('Asset')),
                      DropdownMenuItem(
                        value: 'liability',
                        child: Text('Liability'),
                      ),
                      DropdownMenuItem(value: 'equity', child: Text('Equity')),
                      DropdownMenuItem(value: 'income', child: Text('Income')),
                      DropdownMenuItem(
                        value: 'expense',
                        child: Text('Expense'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _type = value ?? _type),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Code',
                      hintText: editing ? null : 'next free',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _group,
              decoration: const InputDecoration(
                labelText: 'Group (optional)',
                hintText: 'Cash & bank, Sundry debtors, ...',
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _opening,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Opening balance',
                    ),
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'dr', label: Text('Dr')),
                    ButtonSegment(value: 'cr', label: Text('Cr')),
                  ],
                  selected: {_openingType},
                  onSelectionChanged: (selection) =>
                      setState(() => _openingType = selection.first),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: AppSpace.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: AppSpace.sm),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(editing ? 'Save' : 'Add account'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      _snack('Give the account a name.');
      return;
    }
    // `Money.tryParse` so "1,00,000" is read as a lakh; `double.tryParse`
    // returns null for the grouping comma and an opening balance would save
    // as ₹0 with no warning — the account would exist in the chart with no
    // balance, and the trial balance would be out from the first day.
    final opening = Money.tryParse(_opening.text)?.toDouble() ?? 0;
    setState(() => _saving = true);
    try {
      final existing = widget.account;
      if (existing == null) {
        await widget.repo.createAccount(
          name: name,
          type: _type,
          code: _code.text.trim().isEmpty ? null : _code.text.trim(),
          groupName: _group.text.trim(),
          openingBalance: opening,
          openingType: _openingType,
          description: _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
        );
      } else {
        await widget.repo.updateAccount(
          existing.copyWith(
            name: name,
            type: _type,
            groupName: _group.text.trim(),
            openingBalance: opening,
            openingType: _openingType,
            // Nullable columns need drift's Value wrapper so clearing the note
            // actually writes NULL instead of being read as "leave unchanged".
            description: Value(
              _description.text.trim().isEmpty
                  ? null
                  : _description.text.trim(),
            ),
          ),
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      _snack('$error'.replaceFirst('Bad state: ', ''));
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
