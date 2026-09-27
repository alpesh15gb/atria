import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/database/app_database.dart';
import '../../core/state/providers.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';

/// Vyapar-style recycle bin: everything soft-deleted lands here and can be
/// restored or permanently removed. Permanent removal is deliberately
/// guarded — parties used on documents and items with stock history refuse
/// to leave.
class RecycleBinScreen extends ConsumerWidget {
  const RecycleBinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partyRepo = ref.watch(partyRepositoryProvider);
    final itemRepo = ref.watch(itemRepositoryProvider);
    final salesRepo = ref.watch(salesRepositoryProvider);
    final purchaseRepo = ref.watch(purchaseRepositoryProvider);
    final paymentRepo = ref.watch(paymentRepositoryProvider);

    if (partyRepo == null || itemRepo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Recycle Bin')),
        body: const EmptyState(
          icon: Icons.delete_outline_rounded,
          title: 'No business open',
          message: 'Open a business to see its recycle bin.',
        ),
      );
    }

    // Non-null after the guard (null-checking the later closures would lose
    // promotion — Dart cannot flow the check into lambda bodies).
    final docs = salesRepo;
    final bills = purchaseRepo;
    final payments = paymentRepo;

    final deletedParties = partyRepo.watchDeleted();
    final deletedItems = itemRepo.watchDeleted();
    final deletedDocs = docs?.watchDeleted() ?? const Stream.empty();
    final deletedBills = bills?.watchDeleted() ?? const Stream.empty();
    final deletedPayments = payments?.watchDeleted() ?? const Stream.empty();

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recycle Bin'),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Invoices & Docs'),
              Tab(text: 'Purchases'),
              Tab(text: 'Payments'),
              Tab(text: 'Parties'),
              Tab(text: 'Items'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _DeletedList(
              stream: deletedDocs,
              titleOf: (entity) =>
                  '${(entity as SalesInvoiceEntity).docType == "invoice" ? "Invoice" : entity.docType} '
                  '${entity.number}',
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Walk-in"} · '
                      '₹${Money.of(entity.grandTotal)} · '
                      'Deleted ${_when(entity.deletedAt)}',
              onRestore: (id) => docs?.restore(id) ?? Future.value(),
              onDeleteForever: (id) => docs?.purge(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedBills,
              titleOf: (entity) =>
                  'Bill ${(entity as PurchaseBillEntity).number}',
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Supplier"} · '
                      '₹${Money.of(entity.grandTotal)} · '
                      'Deleted ${_when(entity.deletedAt)}',
              onRestore: (id) => bills?.restore(id) ?? Future.value(),
              onDeleteForever: (id) => bills?.purge(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedPayments,
              titleOf: (entity) => (entity as PaymentEntity).number,
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Payment"} · '
                      '₹${Money.of(entity.amount)} · '
                      'Deleted ${_when(entity.deletedAt)}',
              onRestore: (id) => payments?.restore(id) ?? Future.value(),
              onDeleteForever: (id) => payments?.deleteForever(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedParties,
              titleOf: (entity) => (entity as PartyEntity).name,
              subtitleOf: (entity) =>
                  'Deleted ${_when((entity as PartyEntity).deletedAt)}',
              onRestore: partyRepo.restore,
              onDeleteForever: partyRepo.deleteForever,
            ),
            _DeletedList(
              stream: deletedItems,
              titleOf: (entity) => (entity as ItemEntity).name,
              subtitleOf: (entity) =>
                  'Deleted ${_when((entity as ItemEntity).deletedAt)}',
              onRestore: itemRepo.restore,
              onDeleteForever: itemRepo.deleteForever,
            ),
          ],
        ),
      ),
    );
  }

  String _when(DateTime? at) {
    if (at == null) return 'earlier';
    return DateFormat('d MMM yyyy, h:mm a').format(at);
  }
}

class _DeletedList extends StatelessWidget {
  const _DeletedList({
    required this.stream,
    required this.titleOf,
    required this.subtitleOf,
    required this.onRestore,
    required this.onDeleteForever,
  });

  final Stream<List<dynamic>> stream;
  final String Function(dynamic) titleOf;
  final String Function(dynamic) subtitleOf;
  final Future<void> Function(String) onRestore;
  final Future<void> Function(String) onDeleteForever;

  Future<void> _confirmDeleteForever(
      BuildContext context, dynamic entity) async {
    final repo = entity is PartyEntity ? 'party' : 'item';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete "${titleOf(entity)}" forever?'),
        content: Text(
            'This cannot be undone. $repo records referenced by documents or '
            'history are refused automatically.'),
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
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await onDeleteForever(entity.id);
      messenger?.showSnackBar(SnackBar(content: Text('Deleted forever')));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text('$error'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<dynamic>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data ?? const [];
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.delete_outline_rounded,
            title: 'Nothing here',
            message:
                'Deleted parties and items wait here until they are restored '
                'or removed for good.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
          itemCount: rows.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final entity = rows[index];
            return AtriaCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titleOf(entity),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleOf(entity),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore_rounded),
                    onPressed: () async {
                      await onRestore(entity.id);
                      if (!context.mounted) return;
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text('Restored "${titleOf(entity)}"')),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Delete forever',
                    icon: Icon(Icons.delete_forever_rounded,
                        color: scheme.error),
                    onPressed: () => _confirmDeleteForever(context, entity),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
