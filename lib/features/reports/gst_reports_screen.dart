import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../core/database/app_database.dart';
import '../../core/reports/gst_export_service.dart';
import '../../core/reports/gst_return_builder.dart';
import '../../core/reports/gstr1_report.dart';
import '../../core/state/providers.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_list_toolbar.dart';
import '../../shared/widgets/common_widgets.dart';

/// Turns a caught error into something a shopkeeper can act on.
///
/// The raw exception was previously interpolated straight into a snackbar and
/// into the screen's STATUS LINE — a successful-looking GSTR-3B screen whose
/// subtitle read `SqliteException(1): no such table: sales_invoices`. The
/// detail goes to debugPrint (nothing secret is involved in a local read or a
/// file write) and the user gets a sentence.
String _humanError(String what, Object error) {
  debugPrint('gst-reports: $what failed: $error');
  if (error is FileSystemException) {
    return '$what could not be saved. There may be no free space left on '
        'this device.';
  }
  if (error is FormatException) {
    return '$what could not be read. Check you picked the right file.';
  }
  return '$what failed. Nothing was changed — please try again.';
}

/// The reconciliation's totals arrive as raw `double`s from the database; the
/// formatters and the screen want exact [Decimal]s.
Decimal _dec(num value) => Decimal.parse(value.toStringAsFixed(2));

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
          const SizedBox(height: 4),
          AtriaSegmentedFilter<String>(
            segments: const [
              AtriaSegment(value: 'gstr1', label: 'GSTR-1'),
              AtriaSegment(value: 'gstr3b', label: 'GSTR-3B'),
              AtriaSegment(value: 'gstr2a', label: 'GSTR-2A'),
            ],
            value: _tab,
            onChanged: (tab) => setState(() => _tab = tab),
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
    // Retry re-runs both return builds. These are local SQLite aggregates, so
    // a failure is always worth retrying; the futures were previously cached
    // per month with no way to invalidate them.
    void retry() => setState(() {
          _futuresMonth = null;
          _ensureFutures(db, firmId);
        });

    return FutureBuilder<Gstr1Report>(
      future: _gstr1Future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          debugPrint('gst-reports: GSTR-1 build failed: ${snapshot.error}');
          return EmptyState(
            icon: Icons.error_outline_rounded,
            title: 'Could not compute GSTR-1',
            message: 'This return could not be read from your books. Nothing '
                'has been changed.',
            actionLabel: 'Try again',
            onAction: retry,
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
              // an empty table that looked like a zero-return month. Showing
              // '${snap3b.error}' here put a raw SqliteException on screen.
              debugPrint('gst-reports: GSTR-3B build failed: ${snap3b.error}');
              return EmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Could not compute GSTR-3B',
                message: 'This return could not be read from your books. '
                    'Nothing has been changed.',
                actionLabel: 'Try again',
                onAction: retry,
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
                  _sectionTitle(context, 'Table 5 — B2C large supplies'
                      ' (${gstr1.b2cl.length} states)'),
                  for (final b in gstr1.b2cl)
                    for (final inv in b.invoices)
                      _lineTile(
                        context,
                        leading: Icons.local_shipping_rounded,
                        title: '${inv.inum} · POS ${b.pos}',
                        subtitle:
                            '${inv.idt} · ${inv.itms.length} rates',
                        amount: inv.val,
                      ),
                  if (gstr1.b2cl.isEmpty) _emptyHint(context, 'No B2C large invoices.'),
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
                  _sectionTitle(context, 'Table 9B — Credit / debit notes (registered)'
                      ' (${gstr1.cdnr.length} parties)'),
                  for (final c in gstr1.cdnr)
                    for (final n in c.notes)
                      _lineTile(
                        context,
                        leading: Icons.assignment_return_rounded,
                        title: '${n.ntNum} · ${c.ctin}',
                        subtitle:
                            '${n.ntDt} · POS ${n.pos} · Type ${n.ntty}',
                        amount: n.val,
                      ),
                  if (gstr1.cdnr.isEmpty) _emptyHint(context, 'No registered credit / debit notes.'),
                  _sectionTitle(context, 'Table 10 — Credit / debit notes (unregistered)'
                      ' (${gstr1.cdnur.length})'),
                  for (final n in gstr1.cdnur)
                    _lineTile(
                      context,
                      leading: Icons.assignment_return_outlined,
                      title: '${n.ntNum} · POS ${n.pos}',
                      subtitle:
                          '${n.ntDt} · ${n.supplyType} · Type ${n.ntty}',
                      amount: n.val,
                    ),
                  if (gstr1.cdnur.isEmpty) _emptyHint(context, 'No unregistered credit / debit notes.'),
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
                  // Every field the report exposes is printed, not just the
                  // ones that fit. 3.1(c) nil-rated and 3.1(d) reverse charge
                  // were both missing, and 3.1(d) feeds `netPayable` — so the
                  // payable figure on screen contained a cash-RCM component
                  // the user could not see and therefore could not reconcile
                  // against the portal. Table 5 was absent entirely. The
                  // screen has to agree with `gstr3b_summary.csv` or it is
                  // worse than useless: it is a filing aid that disagrees
                  // with the file it produces.
                  _sectionTitle(context, 'Table 3.1 — Outward supplies'),
                  _kv(context, '3.1(a) Outward taxable supplies',
                      gstr3b.outwardTaxable),
                  _kv(context, 'IGST', gstr3b.outwardIgst),
                  _kv(context, 'CGST', gstr3b.outwardCgst),
                  _kv(context, 'SGST', gstr3b.outwardSgst),
                  _kv(context, 'Cess', gstr3b.outwardCess),
                  _kv(context, '3.1(b) Zero-rated (exports/SEZ)',
                      gstr3b.zeroRated),
                  _kv(context, '3.1(c) Nil-rated / exempt', gstr3b.nilRated),
                  // Cash reverse charge — payable in cash through the
                  // electronic cash ledger, never as input credit.
                  _kv(context, '3.1(d) Reverse charge tax (pay in cash)',
                      gstr3b.reverseChargeTax),
                  _sectionTitle(context, 'Table 3.2 — Inter-state to'
                      ' unregistered'),
                  for (final s in gstr3b.interStateByPos)
                    _kv2(
                      context,
                      'POS ${s.pos}',
                      s.taxableValue,
                      s.igst,
                    ),
                  if (gstr3b.interStateByPos.isEmpty)
                    _emptyHint(context, 'None this period.'),
                  _sectionTitle(context, 'Table 4 — Input tax credit'),
                  _kv(context, 'ITC on imports (A1)', gstr3b.itcImport),
                  _kv(context, 'ITC on reverse charge (A3)',
                      gstr3b.itcReverseCharge),
                  _kv(context, 'ITC inward from ISD (A4)',
                      gstr3b.itcInwardIsd),
                  _kv(context, 'All other ITC (A5)', gstr3b.itcAllOther),
                  _kv(context, 'ITC reversed (B) — rules 42/43',
                      gstr3b.itcReversedRule4243),
                  _kv(context, 'ITC reversed (B) — others',
                      gstr3b.itcReversedOther),
                  _kv(context, 'ITC available (A)', gstr3b.itcAvailable),
                  _kv(context, 'Net ITC available (C)', gstr3b.netItc),
                  _sectionTitle(context, 'Table 5 — Nil-rated / non-GST inward'),
                  _kv(context, 'Nil-rated / exempt inward',
                      gstr3b.inwardNilRated),
                  _kv(context, 'Non-GST inward supplies', gstr3b.inwardNonGst),
                  _sectionTitle(context, 'Net position'),
                  _kv(context, 'Output tax',
                      gstr3b.outwardIgst + gstr3b.outwardCgst +
                          gstr3b.outwardSgst + gstr3b.outwardCess),
                  _kv(context, 'Less net ITC available',
                      -gstr3b.netItc),
                  _kv(context, 'Plus cash reverse charge',
                      gstr3b.reverseChargeTax),
                  _kv(context, 'Net tax payable', gstr3b.netPayable,
                      emphasize: true),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.file_download_rounded),
                        // "JSON + CSV", not "JSON + Excel": the service writes one .json plus
                        // six per-table .csv files and never a .xlsx. A
                        // button that promises a format it does not produce
                        // teaches the user that this screen's labels cannot
                        // be trusted.
                        label: Text(_tab == 'gstr1'
                            ? 'Export GSTR-1 (JSON + CSV)'
                            : 'Export GSTR-3B (JSON + CSV)'),
                        onPressed:
                            _busy ? null : () => _export(gstr1, gstr3b),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_view_month_rounded),
                        label: const Text('Export FY to date'),
                        onPressed: _busy
                            ? null
                            : () => _exportFiscalYear(db, firmId, gstr1),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Fiscal-year to date covers April to the month above, month by '
                  'month, in one sheet. Returns are still filed a month at a '
                  'time.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  // No hand-typed path. It was wrong on both counts: it
                  // used Windows backslashes (meaningless on Android) and it
                  // omitted the <GSTIN> level that `_periodDir` actually
                  // inserts, so the folder it named did not exist.
                  'Files are written to your Documents folder under '
                  'atria/gst/<your GSTIN>/${_fp(_month)}. Upload the JSON via '
                  'the GST portal Returns Offline Tool.',
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
    if (rec != null) {
      // Four ~120-150dp chips in a bare Row is ~550dp of children in 328dp of
      // a 360dp phone: a guaranteed overflow on every handset, in the middle
      // of the one screen a CA uses on a shop counter. Wrap lets them reflow.
      final chips = <Widget>[
        _reconChip(context, 'Matched', rec.matched, Colors.green),
        _reconChip(context, 'In books only', rec.booksOnly, Colors.orange),
        _reconChip(context, 'In portal only', rec.portalOnly, Colors.blue),
        _reconChip(context, 'Value mismatch', rec.mismatch, Colors.red),
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Wrap(spacing: 8, runSpacing: 4, children: chips),
          const SizedBox(height: 8),
          Text(
          // Money through the app's own formatter, not `toStringAsFixed` on
          // the raw double: this line is the screen's headline figure and it
          // used to print an unformatted "12345.6".
          'Portal ITC ${Formatters.money(_dec(rec.portalTotalTax))} · '
          'Books ITC ${Formatters.money(_dec(rec.booksTotalTax))}',
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
              'Books: ${row.booksTaxable == null ? '—' : Formatters.money(_dec(row.booksTaxable!))}'
              ' / Portal: ${row.portalTaxable == null ? '—' : Formatters.money(_dec(row.portalTaxable!))}',
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.table_view_rounded),
          // CSV, like the other two exports — this writes
          // `gstr2a_reconciliation.csv`, never a workbook.
          label: const Text('Export reconciliation (CSV)'),
          onPressed: _busy ? null : () => _exportRecon(rec),
        ),
      ],
    );
    }
    // Nothing imported yet: explain the one thing this tab does.
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
            onPressed: _busy ? null : () => _import2a(db, firmId),
          ),
        ],
      ),
    );
  }

  Widget _reconChip(BuildContext context, String label, int count, Color color) {
    // No trailing Padding — the wrapping [Wrap] owns the spacing now, and
    // keeping both doubled the gap on the wide layout.
    return Chip(
      avatar: Icon(Icons.circle, size: 8, color: color),
      label: Text('$label $count'),
      visualDensity: VisualDensity.compact,
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
      final picked2 = picked.files.single;
      // `bytes` is null once the file passes file_picker's in-memory
      // threshold (it hands back a `path` instead). A GSTR-2A export for a
      // busy supplier is comfortably over that, so `bytes!` threw a bare
      // "Null check operator used on a null value" and the user was told the
      // import failed on a file that was perfectly fine.
      final String content;
      if (picked2.bytes != null) {
        content = utf8.decode(picked2.bytes!);
      } else if ((picked2.path ?? '').isNotEmpty) {
        content = await File(picked2.path!).readAsString();
      } else {
        setState(() => _message =
            'That file could not be read. Try picking it again.');
        return;
      }
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
      if (!mounted) return;
      setState(() {
        _reconciliation = rec;
        _message = 'Imported ${picked2.name} · '
            '${rec.rows.length} supplier invoices matched against your books';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _humanError('Import', error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(Gstr1Report gstr1, Gstr3bReport? gstr3b) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    // The export and the open are TWO DIFFERENT FACTS and must not share one
    // try/catch. `setState('Saved to ...')` followed by `await OpenFilex.open`
    // inside the same try meant that on a device with no handler registered
    // for `.json` — routine on Android — the catch replaced a *successful*
    // export's confirmation with "Export failed", and the user re-ran a
    // return they had already filed.
    Directory? dir;
    String? label;
    try {
      final service = GstExportService();
      if (_tab == 'gstr1') {
        dir = await service.exportGstr1(gstr1);
        label = 'GSTR-1';
      } else {
        dir = await service.exportGstr3b(gstr3b!, gstin: gstr1.firmGstin);
        label = 'GSTR-3B';
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _humanError('$label export', error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    // Reached only when the try completed, so `dir` is assigned.
    if (!mounted) return;
    // The JSON is the artefact that has to reach the portal; the CSVs sit
    // beside it for the accountant.
    final json = p.join(
      dir.path,
      _tab == 'gstr1'
          ? 'gstr1_${gstr1.firmGstin}_${gstr1.fp}.json'
          : 'gstr3b_${gstr3b!.fp}.json',
    );
    final opened = await _tryOpen(json);
    if (!mounted) return;
    setState(() {
      _message = opened
          ? '$label exported and opened.'
          : '$label exported, but nothing on this device can open a .json '
              'file. Use Share to send it to the GST portal’s offline tool.';
    });
    if (!opened) _showExportActions(dir, json);
  }

  /// April-to-now summary of the fiscal year containing the selected month.
  ///
  /// Deliberately a working paper rather than an upload: GSTR-1 and 3B are
  /// filed monthly, so a year's worth of them concatenated is something to
  /// reconcile against, not something the portal would accept.
  Future<void> _exportFiscalYear(
    AppDatabase db,
    String firmId,
    Gstr1Report gstr1,
  ) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    String label = '';
    Directory? dir;
    String? file;
    try {
      final fyStartYear = _month.month >= 4 ? _month.year : _month.year - 1;
      label = '$fyStartYear-${(fyStartYear + 1) % 100}';
      final rows = <FiscalYearGstRow>[];
      var cursor = DateTime(fyStartYear, 4, 1);
      while (!cursor.isAfter(_month)) {
        final report = await buildGstr3b(
          db,
          firmId,
          from: cursor,
          to: _monthEnd(cursor),
        );
        rows.add(FiscalYearGstRow(
          period: '${cursor.month.toString().padLeft(2, '0')}-${cursor.year}',
          taxable: report.outwardTaxable,
          igst: report.outwardIgst,
          cgst: report.outwardCgst,
          sgst: report.outwardSgst,
          cess: report.outwardCess,
          itc: report.netItc,
          netPayable: report.netPayable,
          zeroRated: report.zeroRated,
          nilRated: report.nilRated,
        ));
        cursor = DateTime(cursor.year, cursor.month + 1, 1);
      }
      dir = await GstExportService().exportFiscalYear(
        gstin: gstr1.firmGstin,
        fyLabel: label,
        months: rows,
      );
      file = p.join(dir.path, 'fy_${label}_gst_summary.csv');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _humanError('Fiscal-year export', error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    // Reached only when the try completed, so both are assigned.
    if (!mounted) return;
    final opened = await _tryOpen(file);
    if (!mounted) return;
    setState(() {
      _message = opened
          ? 'Fiscal year $label exported and opened.'
          : 'Fiscal year $label exported. Use Share to send the summary to '
              'your accountant.';
    });
    if (!opened) _showExportActions(dir, file);
  }

  Future<void> _exportRecon(Gstr2aReconciliation rec) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    Directory? dir;
    String? file;
    try {
      dir = await GstExportService()
          .exportReconciliation(rec, rec.firmGstin, _fp(_month));
      file = p.join(dir.path, 'gstr2a_reconciliation.csv');
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = _humanError('Reconciliation export', error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    // Reached only when the try completed, so both are assigned.
    if (!mounted) return;
    final opened = await _tryOpen(file);
    if (!mounted) return;
    setState(() {
      _message = opened
          ? 'Reconciliation exported and opened.'
          : 'Reconciliation exported. Use Share to send it to your '
              'accountant.';
    });
    if (!opened) _showExportActions(dir, file);
  }

  /// Opens [path] with the system handler. Returns false instead of throwing
  /// so a caller can carry on: "the file was written but nothing here can
  /// display a .json" is a different, and much less alarming, fact than
  /// "the export failed".
  Future<bool> _tryOpen(String path) async {
    try {
      if (!File(path).existsSync()) return false;
      final result = await OpenFilex.open(path);
      return result.type == ResultType.done;
    } catch (error) {
      debugPrint('gst-reports: could not open $path: $error');
      return false;
    }
  }

  /// Open + Share for an export the platform could not display itself.
  ///
  /// On Android `OpenFilex` has no handler for `.json` and often none for
  /// `.csv`, and the export directory is not browsable by any file manager.
  /// The share sheet is the only route the file has out of the app, so it is
  /// offered explicitly rather than left to a snackbar containing a path the
  /// user cannot act on. Same pattern as `backup_restore_screen.dart`.
  void _showExportActions(Directory dir, String primary) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    // No path in the copy. On Android the file lives somewhere no file
    // manager goes, so "saved to /storage/emulated/0/Android/data/…" is
    // information the user cannot use; the two actions are the whole message.
    messenger.showSnackBar(SnackBar(
      content: const Text(
        'Nothing on this device can show that file type. Share it to your '
        'accountant or to the GST portal’s offline tool.',
      ),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: 'Share',
        onPressed: () => Share.shareXFiles(
          [XFile(primary)],
          subject: p.basenameWithoutExtension(primary),
        ),
      ),
    ));
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

  /// A label with a taxable value AND the tax on it — the shape Table 3.2
  /// actually takes. It used to print `igst` alone against a "POS nn"
  /// heading, so the taxable value the portal's Table 3.2 asks for was
  /// nowhere on the screen.
  Widget _kv2(
    BuildContext context,
    String label,
    Decimal taxable,
    Decimal tax,
  ) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: text.bodyMedium),
                Text(
                  'Taxable ${Formatters.money(taxable)} · '
                  'Tax ${Formatters.money(tax)}',
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
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
