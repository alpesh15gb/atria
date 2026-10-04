import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/database/app_database.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';

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
              titleOf: (entity) {
                final doc = entity as SalesInvoiceEntity;
                return '${_docTypeLabel(doc.docType)} ${doc.number}';
              },
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Walk-in"} · '
                  '${Formatters.money(Money.of(entity.grandTotal))} · '
                  'Deleted ${_when(entity.deletedAt)}',
              purgeNote:
                  'A document dated inside a locked period cannot be removed.',
              onRestore: (id) => docs?.restore(id) ?? Future.value(),
              onDeleteForever: (id) => docs?.purge(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedBills,
              titleOf: (entity) =>
                  'Bill ${(entity as PurchaseBillEntity).number}',
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Supplier"} · '
                  '${Formatters.money(Money.of(entity.grandTotal))} · '
                  'Deleted ${_when(entity.deletedAt)}',
              purgeNote:
                  'A bill dated inside a locked period cannot be removed.',
              onRestore: (id) => bills?.restore(id) ?? Future.value(),
              onDeleteForever: (id) => bills?.purge(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedPayments,
              titleOf: (entity) => (entity as PaymentEntity).number,
              subtitleOf: (entity) =>
                  '${entity.partyName ?? "Payment"} · '
                  '${Formatters.money(Money.of(entity.amount))} · '
                  'Deleted ${_when(entity.deletedAt)}',
              purgeNote:
                  'A payment dated inside a locked period cannot be removed.',
              onRestore: (id) => payments?.restore(id) ?? Future.value(),
              onDeleteForever: (id) =>
                  payments?.deleteForever(id) ?? Future.value(),
            ),
            _DeletedList(
              stream: deletedParties,
              titleOf: (entity) => (entity as PartyEntity).name,
              subtitleOf: (entity) =>
                  'Deleted ${_when((entity as PartyEntity).deletedAt)}',
              purgeNote: 'A party used on any invoice or bill is refused automatically.',
              onRestore: partyRepo.restore,
              onDeleteForever: partyRepo.deleteForever,
            ),
            _DeletedList(
              stream: deletedItems,
              titleOf: (entity) => (entity as ItemEntity).name,
              subtitleOf: (entity) =>
                  'Deleted ${_when((entity as ItemEntity).deletedAt)}',
              purgeNote: 'An item with stock history is refused automatically.',
              onRestore: itemRepo.restore,
              onDeleteForever: itemRepo.deleteForever,
            ),
          ],
        ),
      ),
    );
  }

  /// The document types the bin can hold, as a person reads them. The stored
  /// value is the slug the rest of the app keys filters on.
  String _docTypeLabel(String docType) => switch (docType) {
    'invoice' => 'Invoice',
    'quotation' => 'Quotation',
    'sales_order' => 'Sales order',
    'delivery_note' => 'Delivery note',
    'credit_note' => 'Credit note',
    _ => docType,
  };

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
    required this.purgeNote,
    required this.onRestore,
    required this.onDeleteForever,
  });

  final Stream<List<dynamic>> stream;
  final String Function(dynamic) titleOf;
  final String Function(dynamic) subtitleOf;

  /// Why a permanent delete may be refused for this tab. It used to be a
  /// hard-coded "party records" / "item records" line, so binning a payment
  /// warned about items.
  final String purgeNote;

  final Future<void> Function(String) onRestore;
  final Future<void> Function(String) onDeleteForever;

  Future<void> _confirmDeleteForever(
    BuildContext context,
    dynamic entity,
  ) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete "${titleOf(entity)}" forever?',
      message: 'This cannot be undone. $purgeNote',
      confirmLabel: 'Delete forever',
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await onDeleteForever(entity.id);
      messenger?.showSnackBar(SnackBar(content: Text('Deleted forever')));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
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
                'Deleted records wait here until they are restored or '
                'removed for good.',
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
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitleOf(entity),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Restore',
                    icon: const Icon(Icons.restore_rounded),
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      try {
                        await onRestore(entity.id);
                        if (!context.mounted) return;
                        messenger?.showSnackBar(
                          SnackBar(
                            content: Text('Restored "${titleOf(entity)}"'),
                          ),
                        );
                      } catch (error) {
                        // A restore is lock-guarded like a purge is, so this
                        // can be refused — and without a message the row would
                        // just sit there, looking broken.
                        if (!context.mounted) return;
                        messenger?.showSnackBar(
                          SnackBar(content: Text('$error')),
                        );
                      }
                    },
                  ),
                  IconButton(
                    tooltip: 'Delete forever',
                    icon: Icon(
                      Icons.delete_forever_rounded,
                      color: scheme.error,
                    ),
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
