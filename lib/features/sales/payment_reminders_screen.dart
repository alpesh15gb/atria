import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/database/app_database.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/whatsapp_links.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';

/// Vyapar-style payment reminders: every overdue invoice in one list with a
/// one-tap WhatsApp nudge (message pre-filled with number, amount and days
/// late) and a call shortcut. Nothing is sent automatically — the user
/// reviews the message in their WhatsApp before it goes out.
class PaymentRemindersScreen extends ConsumerWidget {
  const PaymentRemindersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sales = ref.watch(salesRepositoryProvider);
    if (sales == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Payment Reminders')),
        body: const EmptyState(
          icon: Icons.notifications_active_outlined,
          title: 'No business open',
          message: 'Open a business to see overdue payments.',
        ),
      );
    }

    final overdue = sales.watchOverdue();

    return Scaffold(
      appBar: AppBar(title: const Text('Payment Reminders')),
      body: StreamBuilder<List<SalesInvoiceEntity>>(
        stream: overdue,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data ?? const <SalesInvoiceEntity>[];
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.verified_outlined,
              title: 'Nothing overdue',
              message: 'Every invoice is paid or still within its due date.',
            );
          }
          final total = rows.fold<Decimal>(
            Decimal.zero,
            (sum, r) => sum + Decimal.parse(r.balanceDue.toStringAsFixed(2)),
          );
          final scheme = Theme.of(context).colorScheme;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: AtriaCard(
                  background: scheme.errorContainer.withValues(alpha: 0.35),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${rows.length} overdue invoice${rows.length == 1 ? '' : 's'}',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            MoneyText(total,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _OverdueRow(invoice: rows[index]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _OverdueRow extends StatelessWidget {
  const _OverdueRow({required this.invoice});

  final SalesInvoiceEntity invoice;

  int get _daysLate => invoice.dueDate == null
      ? 0
      : DateTime.now().difference(invoice.dueDate!).inDays;

  String get _party => invoice.partyName ?? 'Walk-in customer';

  String get _digits =>
      (invoice.partyPhone ?? '').replaceAll(RegExp(r'[^\d]'), '');

  Future<void> _nudge(BuildContext context) async {
    final days = _daysLate;
    final text = 'Hello $_party, a gentle reminder that invoice '
        '${invoice.number} for ${Formatters.money(
            Decimal.parse(invoice.balanceDue.toStringAsFixed(2)))} '
        'was due ${invoice.dueDate == null ? 'earlier' : DateFormat('d MMM').format(invoice.dueDate!)}'
        '${days > 0 ? ' ($days day${days == 1 ? '' : 's'} ago)' : ''}. '
        'Please arrange the payment at your earliest convenience. Thank you!';
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (_digits.isEmpty) {
      messenger?.showSnackBar(const SnackBar(
          content: Text('This party has no phone number saved.')));
      return;
    }
    final uri = WhatsAppLinks.chat(_digits, message: text);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      messenger?.showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return AtriaCard(
      onTap: () => context.push('/sales/detail/${invoice.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_party,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  '${invoice.number} · due ${invoice.dueDate == null ? '-' : DateFormat('d MMM yyyy').format(invoice.dueDate!)} · ${_daysLate}d late',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          MoneyText(
            Decimal.parse(invoice.balanceDue.toStringAsFixed(2)),
            style: text.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.error,
            ),
          ),
          IconButton(
            tooltip: 'WhatsApp reminder',
            icon: const Icon(Icons.chat_rounded),
            color: scheme.primary,
            onPressed: () => _nudge(context),
          ),
          if (_digits.isNotEmpty)
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call_rounded),
              onPressed: () =>
                  launchUrl(Uri.parse('tel:${invoice.partyPhone}')),
            ),
        ],
      ),
    );
  }
}
