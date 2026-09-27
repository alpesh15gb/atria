import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;

import '../../core/database/app_database.dart';
import '../../core/reports/gst_export_service.dart';
import '../../core/reports/gst_return_builder.dart';
import '../../core/reports/gstr1_report.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';

/// Month under view. Defaults to the current month.
DateTime _monthStart(DateTime now) => DateTime(now.year, now.month, 1);

DateTime _monthEnd(DateTime start) =>
    DateTime(start.year, start.month + 1, 0, 23, 59, 59);

String _fp(DateTime start) =>
    '${start.month.toString().padLeft(2, '0')}${start.year}';

/// GSTR-1 / GSTR-3B / GSTR-2A in one screen. Period = one calendar month
/// (the GST filing unit). Exports land in Documents\atria\gst\<fp>\.
class GstReportsScreen extends ConsumerStatefulWidget {
  const GstReportsScreen({super.key});

  @override
  ConsumerState<GstReportsScreen> createState() => _GstReportsScreenState();
}

class _GstReportsScreenState extends ConsumerState<GstReportsScreen> {
  DateTime _month = _monthStart(DateTime.now());
  String _tab = 'gstr1'; // gstr1 | gstr3b | gstr2a
  bool _busy = false;
  String? _message;

  Gstr2aReconciliation? _reconciliation;

  // Futures are held in state and re-created only when the month changes;
  // building them inline recomputed both returns on every rebuild (any
  // setState: tab switch, message, busy toggle).
  Future<Gstr1Report>? _gstr1Future;
  Future<Gstr3bReport>? _gstr3bFuture;
  DateTime? _futuresMonth;

  void _ensureFutures(AppDatabase db, String firmId) {
    if (_futuresMonth == _month && _gstr1Future != null) return;
    _futuresMonth = _month;
    _gstr1Future = GstReturnBuilder(db, firmId)
        .buildGstr1(from: _month, to: _monthEnd(_month));
    _gstr3bFuture =
        buildGstr3b(db, firmId, from: _month, to: _monthEnd(_month));
  }

  static String _monthLabel(DateTime month) {
    const names = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${names[month.month - 1]} ${month.year}';
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(reportRepositoryProvider);
    final db = ref.watch(appDatabaseProvider);
    final firmId = ref.watch(activeFirmIdProvider);
    final scheme = Theme.of(context).colorScheme;

    if (repo == null || firmId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('GST Reports')),
        body: const EmptyState(
          icon: Icons.storefront_outlined,
          title: 'No business open',
          message: 'Open a business to compute GST returns.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('GST Reports'),
        actions: [
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => setState(() {
              _month = DateTime(_month.year, _month.month - 1, 1);
              _reconciliation = null;
              _futuresMonth = null; // re-compute for the new month
            }),
          ),
          Center(
            child: Text(
              // Was Formatters.date(...).substring(3) — silently broke if
              // the date format ever changed.
              _monthLabel(_month),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => setState(() {
              _month = DateTime(_month.year, _month.month + 1, 1);
              _reconciliation = null;
              _futuresMonth = null; // re-compute for the new month
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'gstr1', label: Text('GSTR-1')),
                ButtonSegment(value: 'gstr3b', label: Text('GSTR-3B')),
                ButtonSegment(value: 'gstr2a', label: Text('GSTR-2A')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _message!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                    ),
              ),
            ),
          Expanded(
            child: _tab == 'gstr2a'
                ? _gstr2aTab(context, db, firmId)
                : _returnsTab(context, db, firmId),
          ),
        ],
      ),
    );
  }

  // ---------------- GSTR-1 / GSTR-3B ---------------------------------

  Widget _returnsTab(BuildContext context, AppDatabase db, String firmId) {
    _ensureFutures(db, firmId);
    return FutureBuilder<Gstr1Report>(
      future: _gstr1Future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not compute GSTR-1',
            message: '${snapshot.error}',
          );
        }
        final gstr1 = snapshot.data!;
        return FutureBuilder<Gstr3bReport>(
          future: _gstr3bFuture,
          builder: (context, snap3b) {
            if (snap3b.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap3b.hasError) {
              // GSTR-3B had no error branch — a failed computation rendered
              // an empty table that looked like a zero-return month.
              return EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Could not compute GSTR-3B',
                message: '${snap3b.error}',
              );
            }
            final gstr3b = snap3b.data;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_tab == 'gstr1') ...[
                  _sectionTitle(context, 'Table 4 — B2B supplies'
                      ' (${gstr1.b2b.length} customers)'),
                  for (final g in gstr1.b2b)
                    for (final inv in g.invoices)
                      _lineTile(
                        context,
                        leading: Icons.business_rounded,
                        title: '${inv.inum} · ${g.ctin}',
                        subtitle:
                            '${inv.idt} · POS ${inv.pos} · ${inv.itms.length} rates',
                        amount: inv.val,
                      ),
                  if (gstr1.b2b.isEmpty) _emptyHint(context, 'No B2B invoices.'),
                  _sectionTitle(context,
                      'Table 7 — B2C small supplies (${gstr1.b2cs.length})'),
                  for (final b in gstr1.b2cs)
                    _lineTile(
                      context,
                      leading: Icons.storefront_rounded,
                      title:
                          '${b.supplyType} · POS ${b.pos} · ${Formatters.percent(b.rate)}',
                      subtitle:
                          'Taxable ${Formatters.money(b.taxableValue)}'
                          ' · Tax ${Formatters.money(b.igst + b.cgst + b.sgst + b.cess)}',
                      amount: b.taxableValue,
                    ),
                  if (gstr1.b2cs.isEmpty)
                    _emptyHint(context, 'No B2C supplies.'),
                  _sectionTitle(context, 'Table 12 — HSN summary'),
                  for (final h in gstr1.hsn)
                    _lineTile(
                      context,
                      leading: Icons.qr_code_rounded,
                      title: '${h.hsn} · ${h.description}',
                      subtitle:
                          'Qty ${h.quantity} ${h.uqc} · Taxable '
                          '${Formatters.money(h.taxableValue)}',
                      amount: h.taxableValue,
                    ),
                  if (gstr1.hsn.isEmpty) _emptyHint(context, 'No HSN lines.'),
                  _sectionTitle(context, 'Table 13 — Documents issued'),
                  for (final d in gstr1.docIssue)
                    _lineTile(
                      context,
                      leading: Icons.receipt_long_rounded,
                      title: '${d.from} → ${d.to}',
                      subtitle:
                          '${d.total} issued · ${d.cancelled} cancelled · '
                          '${d.netIssue} net',
                      amount: Decimal.zero,
                    ),
                ] else if (gstr3b != null) ...[
                  _sectionTitle(context, 'Table 3.1 — Outward supplies'),
                  _kv(context, 'Outward taxable supplies',
                      gstr3b.outwardTaxable),
                  _kv(context, 'IGST', gstr3b.outwardIgst),
                  _kv(context, 'CGST', gstr3b.outwardCgst),
                  _kv(context, 'SGST', gstr3b.outwardSgst),
                  _kv(context, 'Cess', gstr3b.outwardCess),
                  _kv(context, 'Zero-rated (exports/SEZ)', gstr3b.zeroRated),
                  _sectionTitle(context, 'Table 3.2 — Inter-state to'
                      ' unregistered'),
                  for (final s in gstr3b.interStateByPos)
                    _kv(context, 'POS ${s.pos}', s.igst),
                  if (gstr3b.interStateByPos.isEmpty)
                    _emptyHint(context, 'None this period.'),
                  _sectionTitle(context, 'Table 4 — Input tax credit'),
                  _kv(context, 'All other ITC (A5)', gstr3b.itcAllOther),
                  _kv(context, 'ITC reversed (B)', gstr3b.itcReversed),
                  _kv(context, 'Net ITC available (C)', gstr3b.netItc),
                  _sectionTitle(context, 'Net position'),
                  _kv(context, 'Output tax',
                      gstr3b.outwardIgst + gstr3b.outwardCgst +
                          gstr3b.outwardSgst + gstr3b.outwardCess),
                  _kv(context, 'Net tax payable', gstr3b.netPayable,
                      emphasize: true),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.file_download_rounded),
                  label: Text(_tab == 'gstr1'
                      ? 'Export GSTR-1 (JSON + Excel)'
                      : 'Export GSTR-3B (JSON + Excel)'),
                  onPressed: _busy ? null : () => _export(gstr1, gstr3b),
                ),
                const SizedBox(height: 8),
                Text(
                  'Files are written to Documents\\atria\\gst\\${_fp(_month)} — '
                  'upload the JSON via the GST portal Returns Offline Tool.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ---------------- GSTR-2A ------------------------------------------

  Widget _gstr2aTab(BuildContext context, AppDatabase db, String firmId) {
    final rec = _reconciliation;
    if (rec == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_download_outlined, size: 44),
            const SizedBox(height: 12),
            const Text(
              'Import the GSTR-2A JSON you downloaded from the GST portal,'
              ' and Atria matches it against your purchase bills.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.upload_file_rounded),
              label: const Text('Import GSTR-2A JSON'),
              onPressed: _busy
                  ? null
                  : () => _import2a(db, firmId),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            _reconChip(context, 'Matched', rec.matched, Colors.green),
            _reconChip(context, 'In books only', rec.booksOnly, Colors.orange),
            _reconChip(context, 'In portal only', rec.portalOnly, Colors.blue),
            _reconChip(context, 'Value mismatch', rec.mismatch, Colors.red),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Portal ITC ${rec.portalTotalTax.toStringAsFixed(2)} · '
          'Books ITC ${rec.booksTotalTax.toStringAsFixed(2)}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        for (final row in rec.rows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              switch (row.status) {
                'matched' => Icons.check_circle_outline_rounded,
                'books_only' => Icons.edit_note_rounded,
                'portal_only' => Icons.cloud_off_rounded,
                _ => Icons.warning_amber_rounded,
              },
              color: switch (row.status) {
                'matched' => Colors.green,
                'books_only' => Colors.orange,
                'portal_only' => Colors.blue,
                _ => Colors.red,
              },
            ),
            title: Text(row.invoiceNumber),
            subtitle: Text(
              'Books: ${row.booksTaxable?.toStringAsFixed(2) ?? '—'} / '
              'Portal: ${row.portalTaxable?.toStringAsFixed(2) ?? '—'}',
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.table_view_rounded),
          label: const Text('Export reconciliation (Excel)'),
          onPressed: _busy ? null : () => _exportRecon(rec),
        ),
      ],
    );
  }

  Widget _reconChip(BuildContext context, String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Chip(
        avatar: Icon(Icons.circle, size: 10, color: color),
        label: Text('$label $count'),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _import2a(AppDatabase db, String firmId) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final content = utf8.decode(picked.files.single.bytes!);
      final json = jsonDecode(content) as Map<String, dynamic>;
      final gstin = await (db.select(db.firms)
            ..where((t) => t.id.equals(firmId)))
          .getSingleOrNull();
      final rec = await Gstr2aReconciliation.fromPortalJson(
        json,
        db: db,
        firmId: firmId,
        from: _month,
        to: _monthEnd(_month),
        firmGstin: gstin?.gstin ?? '',
      );
      setState(() {
        _reconciliation = rec;
        _message = 'Imported ${picked.files.single.name}';
      });
    } catch (error) {
      setState(() => _message = 'Import failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(Gstr1Report gstr1, Gstr3bReport? gstr3b) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final service = GstExportService();
      final dir = _tab == 'gstr1'
          ? await service.exportGstr1(gstr1)
          : await service.exportGstr3b(gstr3b!, gstin: gstr1.firmGstin);
      setState(() {
        _message = 'Saved to ${dir.path}';
      });
      if (_tab == 'gstr1') {
        await OpenFilex.open(p.join(dir.path,
            'gstr1_${gstr1.firmGstin}_${gstr1.fp}.json'));
      }
    } catch (error) {
      setState(() => _message = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportRecon(Gstr2aReconciliation rec) async {
    setState(() => _busy = true);
    try {
      final dir = await GstExportService()
          .exportReconciliation(rec, rec.firmGstin, _fp(_month));
      setState(() => _message = 'Saved to ${dir.path}');
    } catch (error) {
      setState(() => _message = 'Export failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- Small pieces --------------------------------------

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      );

  Widget _emptyHint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );

  Widget _lineTile(
    BuildContext context, {
    required IconData leading,
    required String title,
    required String subtitle,
    required Decimal amount,
  }) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(leading, size: 20),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        Formatters.money(amount),
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _kv(BuildContext context, String label, Decimal value,
      {bool emphasize = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: emphasize
                  ? Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)
                  : Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Text(
            Formatters.money(value),
            style: emphasize
                ? Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700)
                : Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
