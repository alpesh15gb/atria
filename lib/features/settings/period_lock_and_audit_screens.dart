import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/state/providers.dart';
import '../../shared/widgets/common_widgets.dart';

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

  Future<void> _pickDate() async {
    if (_busy) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _lockedUpto ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      helpText: 'Lock books through this date',
    );
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final firmId = ref.read(activeFirmIdProvider);
      final lock = ref.read(periodLockProvider);
      await lock.lockThrough(picked, firmId: firmId);
      final db = ref.read(appDatabaseProvider);
      await db.auditRepository.log(
        action: 'lock',
        entity: 'settings',
        firmId: firmId,
        summary:
            'Books locked through ${DateFormat('d MMM yyyy').format(picked)}',
      );
      await _load();
    } catch (e) {
      // A failed lock used to look identical to a successful one.
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not lock the books: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unlock() async {
    if (_busy) return;
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
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final firmId = ref.read(activeFirmIdProvider);
      final lock = ref.read(periodLockProvider);
      await lock.unlock(firmId: firmId);
      final db = ref.read(appDatabaseProvider);
      await db.auditRepository.log(
        action: 'unlock',
        entity: 'settings',
        firmId: firmId,
        summary: 'Books unlocked',
      );
      await _load();
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not unlock the books: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Period lock')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
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
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.lock_rounded, size: 18),
                            label: Text(_lockedUpto == null
                                ? 'Lock through a date'
                                : 'Change lock date'),
                            onPressed: _busy ? null : _pickDate,
                          ),
                          if (_lockedUpto != null) ...[
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.lock_open_rounded,
                                  size: 18),
                              label: const Text('Unlock'),
                              onPressed: _busy ? null : _unlock,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
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

  static const _entities = <String?>[
    null,
    'sales_invoices',
    'purchase_bills',
    'payments',
    'expenses',
    'parties',
    'items',
    'settings',
  ];

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
                value: _entityFilter,
                hint: const Text('All'),
                items: [
                  for (final e in _entities)
                    DropdownMenuItem(
                      value: e,
                      child: Text(e == null
                          ? 'All'
                          : switch (e) {
                              'sales_invoices' => 'Sales',
                              'purchase_bills' => 'Purchases',
                              'payments' => 'Payments',
                              'expenses' => 'Expenses',
                              'parties' => 'Parties',
                              'items' => 'Items',
                              'settings' => 'Settings',
                              _ => e,
                            }),
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
              message: '${snapshot.error}',
            );
          }
          if (rows.isEmpty) {
            return const EmptyState(
              icon: Icons.fact_check_outlined,
              title: 'Nothing logged yet',
              message: 'Actions appear here as you create, edit and delete '
                  'transactions.',
            );
          }
          return ListView.separated(
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
          );
        },
      ),
    );
  }
}
