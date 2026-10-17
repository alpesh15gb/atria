import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'money_text.dart';
import 'status_chip.dart';

/// The phone's page chrome. Desktop continues to use AtriaListPage's frame.
class MobileListPage extends StatelessWidget {
  const MobileListPage({
    super.key,
    required this.title,
    required this.body,
    this.header,
    this.subtitle,
    this.actions = const [],
    this.toolbar = const [],
  });
  final String title;
  final Widget body;
  final Widget? header;
  final String? subtitle;
  final List<Widget> actions;
  final List<Widget> toolbar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: NestedScrollView(
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -.7,
                                  ),
                            ),
                            if (subtitle != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                subtitle!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (actions.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: actions,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?header,
                ...toolbar,
              ],
            ),
          ),
        ],
        body: body,
      ),
    );
  }
}

/// Bills share Sales / Purchases / Quotations tabs, without changing branches.
class MobileDocumentTabs extends StatelessWidget {
  const MobileDocumentTabs({super.key, required this.active});
  final String active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const tabs = [
      ('Sales', '/sales?type=invoice'),
      ('Purchases', '/purchase?type=bill'),
      ('Quotations', '/sales?type=quotation'),
    ];
    return Material(
      color: scheme.surface,
      child: Row(
        children: [
          for (final tab in tabs)
            Expanded(
              child: InkWell(
                onTap: () => context.go(tab.$2),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: active == tab.$1
                            ? scheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    tab.$1,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active == tab.$1
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'More document types',
            onSelected: (route) => context.go(route),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: '/sales?type=sales_order',
                child: Text('Sales orders'),
              ),
              PopupMenuItem(
                value: '/sales?type=delivery_note',
                child: Text('Delivery notes'),
              ),
              PopupMenuItem(
                value: '/sales?type=credit_note',
                child: Text('Credit notes'),
              ),
              PopupMenuItem(
                value: '/purchase?type=purchase_order',
                child: Text('Purchase orders'),
              ),
              PopupMenuItem(
                value: '/purchase?type=debit_note',
                child: Text('Debit notes'),
              ),
            ],
            child: const SizedBox(
              width: 58,
              height: 52,
              child: Center(
                child: Text('More', style: TextStyle(fontSize: 13)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps every money digit visible without changing the desktop MoneyText.
class MobileAmount extends StatelessWidget {
  const MobileAmount(this.amount, {super.key, this.style});
  final Decimal amount;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: MoneyText(amount, colorize: false, style: style),
  );
}

class MobileDocumentCard extends StatelessWidget {
  const MobileDocumentCard({
    super.key,
    required this.title,
    required this.number,
    required this.date,
    required this.amount,
    required this.status,
    required this.statusKind,
    required this.onTap,
    required this.menu,
    this.onLongPress,
    this.selected = false,
    this.selection,
  });
  final String title, number, date, status;
  final Decimal amount;
  final ChipKind statusKind;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget menu;
  final bool selected;
  final Widget? selection;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected ? scheme.primaryContainer : scheme.surface,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  ?selection,
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.receipt_long_outlined,
                      color: scheme.primary,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          number,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        StatusChip(label: status, kind: statusKind),
                        const SizedBox(height: 5),
                        MobileAmount(
                          amount,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: scheme.outline),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      date,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  menu,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
