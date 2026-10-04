import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/state/providers.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../core/theme/app_sizes.dart';
import '../../shared/widgets/atria_content_width.dart';

/// Freeze the books through a date: transactions dated on or before it can
/// no longer be created, edited or deleted (see PeriodLock + the
/// `assertDateEditable` checks in the repositories). Reports stay readable.
class PeriodLockScreen extends ConsumerStatefulWidget {
  const PeriodLockScreen({super.key});

  @override
  ConsumerState<PeriodLockScreen> createState() => _PeriodLockScreenState();
}

class _PeriodLockScreenState extends ConsumerState<PeriodLockScreen> {
  DateTime? _lockedUpto;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final lock = ref.read(periodLockProvider);
    final firmId = ref.read(activeFirmIdProvider);
    final value = await lock.lockedUpto(firmId: firmId);
    if (!mounted) return;
    setState(() {
      _lockedUpto = value;
      _loading = false;
    });
  }

  /// One `auditRepository.log` call, isolated from the change it describes.
  ///
  /// A failed write used to be reported as a failed lock/unlock even when the
  /// lock itself had already landed, which teaches the operator to distrust a
  /// correct message.
  Future<void> _audit(
    String action,
    String summary, {
    required String? firmId,
  }) async {
    try {
      await ref.read(appDatabaseProvider).auditRepository.log(
            action: action,
            entity: 'settings',
            firmId: firmId,
            summary: summary,
          );
    } on Object catch (e) {
      // Nothing useful to do but say so: the books are closed either way.
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('The books are changed, but the audit log entry '
            'could not be written: $e')),
      );
    }
  }

  Future<void> _pickDate() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final picked = await showDatePicker(
      context: context,
      initialDate: _lockedUpto ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      helpText: 'Lock books through this date',
    );
    if (picked == null || !mounted) return;

    // Locking is the direction that does damage: unlocking only reopens
    // editing, which is why IT has always asked first. Without this dialog a
    // stray tap froze every document dated on or before the chosen day —
    // including anything entered with a back-date today.
    final formatted = DateFormat('d MMM yyyy').format(picked);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_lockedUpto == null
            ? 'Lock the books through $formatted?'
            : 'Change the lock to $formatted?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Every invoice, bill, payment and expense dated on or before '
              '$formatted becomes uneditable — it can no longer be edited, '
              'deleted or created.',
            ),
            const SizedBox(height: 10),
            Text(
              'Anything you enter with a date in that period after this will '
              'be refused until you unlock it again. Reports and searches are '
              'not affected.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            if (_lockedUpto != null) ...[
              const SizedBox(height: 10),
              Text(
                'The books are currently locked through '
                '${DateFormat('d MMM yyyy').format(_lockedUpto!)}.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Lock the books'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final firmId = ref.read(activeFirmIdProvider);
    try {
      await ref.read(periodLockProvider).lockThrough(picked, firmId: firmId);
    } on Object catch (e) {
      // A failed lock used to look identical to a successful one.
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not lock the books: $e')),
      );
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _load();
    messenger?.showSnackBar(
      SnackBar(content: Text('Books locked through $formatted')),
    );
    await _audit('lock', 'Books locked through $formatted', firmId: firmId);
  }

  Future<void> _unlock() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    // Unlocking reopens filed books — worth one confirmation.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unlock the books?'),
        content: const Text(
          'Transactions dated on or before the lock date will be editable '
          'again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final firmId = ref.read(activeFirmIdProvider);
    try {
      await ref.read(periodLockProvider).unlock(firmId: firmId);
    } on Object catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not unlock the books: $e')),
      );
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _load();
    messenger?.showSnackBar(const SnackBar(content: Text('Books unlocked')));
    await _audit('unlock', 'Books unlocked', firmId: firmId);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Period lock')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : AtriaContentWidth(
              maxWidth: 720,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  AtriaCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _lockedUpto == null
                                  ? Icons.lock_open_rounded
                                  : Icons.lock_rounded,
                              color: _lockedUpto == null
                                  ? scheme.primary
                                  : scheme.error,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _lockedUpto == null
                                    ? 'Books are open'
                                    : 'Locked through '
                                          '${DateFormat('d MMM yyyy').format(_lockedUpto!)}',
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'A period lock closes your books: nobody can add, '
                          'edit or delete a transaction dated on or before the '
                          'lock date. Use it after filing GST or closing a '
                          'month so past figures stay stable. Reports and '
                          'searches are never affected.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 16),
                        // Busy state for the destructive direction. Without it
                        // the card looks completely untouched between the tap
                        // and the headline changing, which reads as "nothing
                        // happened" on the one action that closes the books.
                        if (_busy)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2.2),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'Updating the books…',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: scheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          )
                        // Wrap, not Row: the two labelled buttons together need
                        // ~300dp and a 360dp window leaves ~296dp for them (less
                        // still at the 1.15 text scale the app allows), so the
                        // pair used to overflow. A Wrap drops the second button
                        // onto its own line instead of overflowing, whatever the
                        // labels end up measuring.
                        else
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                icon: const Icon(Icons.lock_rounded, size: 18),
                                label: Text(
                                  _lockedUpto == null
                                      ? 'Lock through a date'
                                      : 'Change lock date',
                                ),
                                onPressed: _pickDate,
                              ),
                              if (_lockedUpto != null)
                                OutlinedButton.icon(
                                  icon: const Icon(
                                    Icons.lock_open_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Unlock'),
                                  onPressed: _unlock,
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// The append-only audit trail, newest first. Read-only by design — the only
/// way rows leave is wiping the firm's data.
class AuditLogScreen extends ConsumerStatefulWidget {
  const AuditLogScreen({super.key});

  @override
  ConsumerState<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends ConsumerState<AuditLogScreen> {
  late Future<List<AuditLogEntity>> _future;
  String? _entityFilter;

  /// Every entity the app can write an audit row for.
  ///
  /// This list used to stop at eight entries, which meant the two places an
  /// operator is most likely to look — "who emptied the recycle bin?" and the
  /// journal/accounts trail — were unfilterable: the `purge` row Settings writes
  /// under `recycle_bin` showed under *All* and nowhere else. Kept in step with
  /// the `entity:` arguments across `core/database/repositories`.
  static const _entities = <String?>[
    null,
    'sales_invoices',
    'sales_invoice_items',
    'purchase_bills',
    'purchase_bill_items',
    'payments',
    'expenses',
    'parties',
    'items',
    'categories',
    'units',
    'stock_movements',
    'accounts',
    'journal_entries',
    'journal_lines',
    'firms',
    'recycle_bin',
    'settings',
  ];

  /// Friendly name for an entity filter value.
  static String _entityLabel(String? entity) => switch (entity) {
        null => 'All',
        'sales_invoices' => 'Sales',
        'sales_invoice_items' => 'Invoice lines',
        'purchase_bills' => 'Purchases',
        'purchase_bill_items' => 'Purchase lines',
        'payments' => 'Payments',
        'expenses' => 'Expenses',
        'parties' => 'Parties',
        'items' => 'Items',
        'categories' => 'Categories',
        'units' => 'Units',
        'stock_movements' => 'Stock movements',
        'accounts' => 'Accounts',
        'journal_entries' => 'Journal vouchers',
        'journal_lines' => 'Journal lines',
        'firms' => 'Businesses',
        'recycle_bin' => 'Recycle bin',
        'settings' => 'Settings',
        _ => entity,
      };

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final db = ref.read(appDatabaseProvider);
    final firmId = ref.read(activeFirmIdProvider);
    _future = db.auditRepository.list(firmId: firmId, entity: _entityFilter);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit log'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                iconSize: AppIconSize.md,
                value: _entityFilter,
                hint: const Text('All'),
                items: [
                  for (final e in _entities)
                    DropdownMenuItem(
                      value: e,
                      child: Text(_entityLabel(e)),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _entityFilter = v;
                  _load();
                }),
              ),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<AuditLogEntity>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snapshot.data ?? const <AuditLogEntity>[];
          if (snapshot.hasError) {
            // An error used to render the same "Nothing logged yet" empty
            // state — a broken audit log is not an empty one.
            return EmptyState(
              icon: Icons.error_outline_rounded,
              title: 'Could not load the audit log',
              message: atriaErrorMessage(snapshot.error, retry: 'Try again.'),
            );
          }
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Nothing logged yet',
              message:
                  'Actions appear here as you create, edit and delete '
                  'transactions.',
            );
          }
          return AtriaContentWidth(
            maxWidth: 720,
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: scheme.outlineVariant),
              itemBuilder: (context, index) {
                final row = rows[index];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    switch (row.action) {
                      'create' => Icons.add_circle_outline_rounded,
                      'update' => Icons.edit_outlined,
                      'delete' => Icons.delete_outline_rounded,
                      'restore' => Icons.restore_rounded,
                      'purge' => Icons.delete_forever_rounded,
                      'lock' => Icons.lock_rounded,
                      'unlock' => Icons.lock_open_rounded,
                      _ => Icons.info_outline_rounded,
                    },
                    size: 20,
                    color: switch (row.action) {
                      'delete' || 'purge' => scheme.error,
                      'restore' => scheme.primary,
                      'create' => scheme.secondary,
                      _ => scheme.onSurfaceVariant,
                    },
                  ),
                  title: Text(
                    row.summary ?? '${row.action} ${row.entity}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${row.action} · ${row.entity}'
                    '${row.actor == null ? '' : ' · ${row.actor}'} · '
                    '${DateFormat('d MMM yyyy, h:mm a').format(row.createdAt.toLocal())}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
