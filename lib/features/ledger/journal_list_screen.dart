import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/status_chip.dart';

/// Journal vouchers, newest first.
///
/// The one place an entry can be made that is not a document: capital brought
/// in, depreciation, an opening balance carried forward, a correction between
/// two accounts. Each voucher is validated as balanced before it is saved, so
/// the trial balance cannot be broken from here.
class JournalListScreen extends ConsumerStatefulWidget {
  const JournalListScreen({super.key});

  static const String routePath = '/ledger/journals';

  @override
  ConsumerState<JournalListScreen> createState() => _JournalListScreenState();
}

class _JournalListScreenState extends ConsumerState<JournalListScreen> {
  String _search = '';
  bool _showDeleted = false;

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(journalsProvider);

    return AtriaListPage(
      title: 'Journal entries',
      subtitle:
          'Adjustments that are not a sale, a bill, a payment or an '
          'expense — capital, depreciation, corrections.',
      actions: [
        AtriaPrimaryAction(
          label: 'New journal',
          icon: PhosphorIconsRegular.plus,
          onPressed: () => context.push('/ledger/journals/new'),
        ),
      ],
      search: TextField(
        decoration: const InputDecoration(
          hintText: 'Search by narration or number',
          prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass),
        ),
        onChanged: (value) => setState(() => _search = value),
      ),
      toolbar: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Vouchers are numbered JV/0001 and up within the firm.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _showDeleted = !_showDeleted),
              child: Text(_showDeleted ? 'Hide binned' : 'Show binned'),
            ),
          ],
        ),
      ],
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: PhosphorIconsRegular.warningCircle,
          title: 'Could not load the vouchers',
          message: '$error',
        ),
        data: (rows) {
          final visible = rows.where((e) {
            if (!_showDeleted && e.isDeleted) return false;
            if (_search.trim().isEmpty) return true;
            final q = _search.trim().toLowerCase();
            return e.narration.toLowerCase().contains(q) ||
                e.number.toLowerCase().contains(q);
          }).toList();
          if (visible.isEmpty) {
            return EmptyState(
              icon: PhosphorIconsRegular.notebook,
              title: rows.isEmpty
                  ? 'No journal entries yet'
                  : 'Nothing matches',
              message: rows.isEmpty
                  ? 'A journal entry moves an amount between two accounts, '
                        'splitting every rupee into a debit and a credit.'
                  : 'Try a different search.',
              actionLabel: rows.isEmpty ? 'New journal' : null,
              onAction: rows.isEmpty
                  ? () => context.push('/ledger/journals/new')
                  : null,
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: AppSpace.xxl),
            itemCount: visible.length,
            itemBuilder: (context, index) => _JournalRow(entry: visible[index]),
          );
        },
      ),
    );
  }
}

class _JournalRow extends ConsumerWidget {
  const _JournalRow({required this.entry});

  final JournalEntryEntity entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final text = Theme.of(context).textTheme;
    return AtriaCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      // The number and the date have to give way before the
                      // row does: at 360dp this column is ~125dp while
                      // "JV/0001" + "03 Oct 2026" alone is ~127dp, and a
                      // binned voucher adds a chip on top of that.
                      child: Text(
                        entry.number,
                        style: text.bodyLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Text(Formatters.date(entry.date), style: text.bodySmall),
                    if (entry.isDeleted) ...[
                      const SizedBox(width: AppSpace.sm),
                      const StatusChip(label: 'Binned', kind: ChipKind.danger),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpace.xxs),
                Text(
                  entry.narration,
                  style: text.bodyMedium?.copyWith(color: muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _Amount(entryId: entry.id, deleted: entry.isDeleted),
          PopupMenuButton<String>(
            tooltip: 'Voucher actions',
            onSelected: (value) => _act(context, ref, value),
            itemBuilder: (context) => [
              if (!entry.isDeleted)
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(
                value: entry.isDeleted ? 'restore' : 'delete',
                child: Text(entry.isDeleted ? 'Restore' : 'Move to bin'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return;
    final messenger = ScaffoldMessenger.of(context);
    if (action == 'edit') {
      context.push('/ledger/journals/edit/${entry.id}');
      return;
    }
    try {
      if (action == 'delete') {
        await repo.deleteJournal(entry.id);
        messenger.showSnackBar(
          SnackBar(content: Text('${entry.number} binned')),
        );
      } else {
        await repo.restoreJournal(entry.id);
        messenger.showSnackBar(
          SnackBar(content: Text('${entry.number} restored')),
        );
      }
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('$error'.replaceFirst('Bad state: ', ''))),
      );
    }
  }
}

/// The voucher's total, read from its lines. The list shows one number per
/// voucher — the amount that balanced — which is what a person uses to find it
/// again on a printed day book.
class _Amount extends ConsumerWidget {
  const _Amount({required this.entryId, required this.deleted});

  final String entryId;
  final bool deleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return const SizedBox.shrink();
    return FutureBuilder<List<JournalLineEntity>>(
      future: repo.journalLinesOf(entryId),
      builder: (context, snapshot) {
        final lines = snapshot.data;
        if (lines == null) return const SizedBox(width: 80);
        var total = 0.0;
        for (final line in lines) {
          total += line.debit;
        }
        return Padding(
          padding: const EdgeInsets.only(right: AppSpace.sm),
          child: Text(
            Formatters.money(Money.of(total)),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              decoration: deleted ? TextDecoration.lineThrough : null,
            ),
          ),
        );
      },
    );
  }
}
