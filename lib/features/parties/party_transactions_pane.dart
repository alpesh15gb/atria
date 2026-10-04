import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/database/app_database.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_avatar.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';

/// Right pane of the desktop Parties master-detail: the selected party's
/// header (name, GSTIN/phone, outstanding) and every transaction with them —
/// invoices, quotations, orders and notes — newest first. Vyapar's Parties
/// screen, minus the phone-only chrome. Empty selection renders a prompt.
class PartyTransactionsPane extends ConsumerStatefulWidget {
  const PartyTransactionsPane({super.key, required this.party});

  final PartyEntity? party;

  @override
  ConsumerState<PartyTransactionsPane> createState() =>
      _PartyTransactionsPaneState();
}

class _PartyTransactionsPaneState extends ConsumerState<PartyTransactionsPane> {
  String _typeFilter = 'all';

  static const _typeLabels = {
    'all': 'All',
    'invoice': 'Invoices',
    'quotation': 'Quotations',
    'sales_order': 'Orders',
    'credit_note': 'Credit notes',
    'delivery_note': 'Delivery notes',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final party = widget.party;
    if (party == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.swipe_right_rounded,
              size: AppIconSize.empty,
              color: scheme.outline,
            ),
            const SizedBox(height: 10),
            Text(
              'Select a party to see their transactions',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final sales = ref.watch(salesRepositoryProvider);
    if (sales == null) {
      return const Center(
        child: EmptyState(
          icon: Icons.storefront_outlined,
          title: 'No business open',
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, party),
        Divider(height: 1, color: scheme.outlineVariant),
        _typeFilterRow(context),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: StreamBuilder<List<SalesInvoiceEntity>>(
            stream: sales.watchForParty(party.id),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load transactions',
                  message: atriaErrorMessage(
                    snapshot.error,
                    retry: 'Try again.',
                  ),
                );
              }
              var docs = snapshot.data ?? const <SalesInvoiceEntity>[];
              if (_typeFilter != 'all') {
                docs = docs
                    .where((d) => d.docType == _typeFilter)
                    .toList(growable: false);
              }
              if (docs.isEmpty) {
                return EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No transactions yet',
                  message:
                      'Invoices, quotations and orders for ${party.name} will '
                      'appear here.',
                  actionLabel: 'New invoice',
                  onAction: () => context.push(
                    '/sales/new?party=${Uri.encodeComponent(party.id)}',
                  ),
                );
              }
              return ListView.separated(
                itemCount: docs.length,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: scheme.outlineVariant),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    leading: AtriaAvatar.glyph(
                      icon: switch (doc.docType) {
                        'quotation' => Icons.request_quote_outlined,
                        'sales_order' => Icons.receipt_outlined,
                        'credit_note' => Icons.assignment_return_outlined,
                        'delivery_note' => Icons.local_shipping_outlined,
                        _ => Icons.receipt_long_outlined,
                      },
                      tone: AtriaAvatarTone.info,
                      radius: AtriaAvatar.row,
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            doc.number.isEmpty ? '(no number)' : doc.number,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (doc.status == 'converted' ||
                            doc.convertedToInvoiceId != null)
                          Text(
                            'converted',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.primary),
                          ),
                      ],
                    ),
                    subtitle: Text(
                      '${_typeLabels[doc.docType] ?? doc.docType} · '
                      '${Formatters.date(doc.invoiceDate)}',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    trailing: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        MoneyText(
                          Money.of(doc.grandTotal),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (doc.balanceDue > 0.0001)
                          Text(
                            'due ${Formatters.money(Money.of(doc.balanceDue))}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: scheme.error),
                          ),
                      ],
                    ),
                    onTap: () => context.push('/sales/detail/${doc.id}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, PartyEntity party) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final subtitle = [
      if ((party.gstin ?? '').isNotEmpty) party.gstin!.toUpperCase(),
      if ((party.phone ?? '').isNotEmpty) party.phone!,
      if ((party.city ?? '').isNotEmpty) party.city!,
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          AtriaAvatar.initials(name: party.name, radius: AtriaAvatar.header),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  party.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Statement of account',
            icon: const Icon(Icons.receipt_long_outlined, size: 20),
            onPressed: () => context.push('/parties/statement/${party.id}'),
          ),
          IconButton(
            tooltip: 'Edit party',
            icon: const Icon(Icons.edit_outlined, size: 20),
            onPressed: () => context.push('/parties/edit/${party.id}'),
          ),
        ],
      ),
    );
  }

  Widget _typeFilterRow(BuildContext context) {
    return AtriaSegmentedFilter<String>(
      scrollable: true,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      segments: [
        for (final entry in _typeLabels.entries)
          AtriaSegment(value: entry.key, label: entry.value),
      ],
      value: _typeFilter,
      onChanged: (type) => setState(() => _typeFilter = type),
    );
  }
}

/// Desktop split: party list (left) + [PartyTransactionsPane] (right).
/// The list keeps its own width per the reference layout (~340px).
class PartiesMasterDetail extends StatelessWidget {
  const PartiesMasterDetail({
    super.key,
    required this.list,
    required this.selectedParty,
  });

  final Widget list;
  final PartyEntity? selectedParty;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ~1/3 for the list, matching the Vyapar reference proportions.
        SizedBox(width: 340, child: list),
        VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outline),
        Expanded(child: PartyTransactionsPane(party: selectedParty)),
      ],
    );
  }
}
