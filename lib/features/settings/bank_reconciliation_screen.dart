import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/services/bank_reconciliation.dart';
import '../../core/state/providers.dart';

class BankReconciliationScreen extends ConsumerStatefulWidget {
  const BankReconciliationScreen({super.key});
  @override
  ConsumerState<BankReconciliationScreen> createState() =>
      _BankReconciliationState();
}

class _BankReconciliationState extends ConsumerState<BankReconciliationScreen> {
  List<BankStatementRow> _rows = [];
  List<BankCandidate> _docs = [];
  Map<String, String> _aliases = {};
  final Map<BankStatementRow, BankCandidate> _selected = {};
  String? _account, _message;
  bool _busy = false;
  Future<void> _import() async {
    final firm = ref.read(activeFirmIdProvider);
    if (firm == null) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'pdf'],
        withData: true,
      );
      if (picked == null) return;
      final f = picked.files.single;
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
      if (bytes.length > 30 * 1024 * 1024) {
        throw const FormatException('Choose a statement smaller than 30 MB.');
      }
      var csv = '';
      if (f.extension?.toLowerCase() == 'pdf') {
        final extracted = await extractBankPdf(bytes);
        if (!mounted) return;
        final controller = TextEditingController(
          text: 'Date,Description,Debit,Credit,Reference\n',
        );
        final approved = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Review PDF transactions'),
            content: SizedBox(
              width: 1000,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'PDF columns vary by bank. Copy transactions into the CSV fields below, preserving debit/credit direction. Nothing is posted until you confirm the next preview.',
                    ),
                    SizedBox(
                      height: 240,
                      child: SingleChildScrollView(
                        child: SelectableText(extracted),
                      ),
                    ),
                    TextField(
                      controller: controller,
                      maxLines: 10,
                      decoration: const InputDecoration(
                        labelText: 'Transaction CSV',
                        helperText: 'Date,Description,Debit,Credit,Reference',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Preview matches'),
              ),
            ],
          ),
        );
        csv = controller.text;
        controller.dispose();
        if (approved != true) return;
      } else {
        csv = utf8.decode(bytes);
      }
      final rows = parseBankCsv(csv);
      final db = ref.read(appDatabaseProvider);
      final docs = await BankReconciler(db, firm).documents();
      final saved = await db.settingsRepository.get(
        'bank_reconciliation_aliases',
        firmId: firm,
      );
      final aliases = saved == null
          ? <String, String>{}
          : Map<String, String>.from(jsonDecode(saved) as Map);
      if (!mounted || ref.read(activeFirmIdProvider) != firm) return;
      final suggestions = <BankStatementRow, BankCandidate>{};
      final allocated = <String, double>{};
      final reconciler = BankReconciler(db, firm);
      for (final row in rows) {
        final ranked = reconciler.suggest(row, docs, aliases: aliases);
        if (ranked.isEmpty) continue;
        final best = ranked.first;
        final used = allocated[best.id] ?? 0;
        if (best.score >= 60 &&
            (ranked.length == 1 || best.score - ranked[1].score >= 15) &&
            used + row.amount.abs() <= best.balance + .005) {
          suggestions[row] = best;
          allocated[best.id] = used + row.amount.abs();
        }
      }
      setState(() {
        _rows = rows;
        _docs = docs;
        _aliases = aliases;
        _selected.clear();
        _selected.addAll(suggestions);
        _message =
            '${rows.length} transactions imported, ${suggestions.length} matches suggested. Review selections before confirming; no payment has been recorded.';
      });
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _alias(BankStatementRow row, BankCandidate candidate) async {
    if (candidate.partyId == null) return;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remember alias for ${candidate.party}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(row.description),
            TextField(
              controller: c,
              decoration: const InputDecoration(
                labelText: 'Bank name fragment (e.g. Keystone)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remember'),
          ),
        ],
      ),
    );
    final key = bankNameKey(c.text);
    c.dispose();
    if (ok != true || key.length < 3) return;
    final firm = ref.read(activeFirmIdProvider);
    if (firm == null) return;
    final previous = _aliases[key];
    if (previous != null && previous != candidate.partyId) {
      setState(
        () => _message = 'This alias already belongs to another party. Use a more specific fragment.',
      );
      return;
    }
    _aliases[key] = candidate.partyId!;
    await ref
        .read(appDatabaseProvider)
        .settingsRepository
        .set('bank_reconciliation_aliases', jsonEncode(_aliases), firmId: firm);
    if (mounted) setState(() {});
  }

  Future<void> _confirm() async {
    final firm = ref.read(activeFirmIdProvider), account = _account;
    if (firm == null || account == null || _selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Record selected bank payments?'),
        content: Text(
          '${_selected.length} payments will be recorded and linked document balances updated. Partial payments remain partially paid. Review each selection before continuing.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Back to preview'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm payments'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final count = await BankReconciler(
        ref.read(appDatabaseProvider),
        firm,
      ).confirm(Map.of(_selected), account);
      if (mounted) {
        setState(() {
          _selected.clear();
          _rows = [];
          _message =
              '$count payments recorded. Reimporting the same statement rows will not post them twice.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firm = ref.watch(activeFirmIdProvider);
    ref.listen(activeFirmIdProvider, (previous, next) {
      if (previous != next && mounted) {
        setState(() {
          _rows = [];
          _docs = [];
          _selected.clear();
          _aliases = {};
          _account = null;
        });
      }
    });
    final db = ref.watch(appDatabaseProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Bank reconciliation')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Import → review matches → confirm. Short names never mark documents paid automatically. Saved aliases help suggestions on this device.',
            ),
            StreamBuilder<List<BankAccountEntity>>(
              stream:
                  (db.select(db.bankAccounts)
                        ..where(
                          (a) =>
                              a.firmId.equals(firm ?? '') &
                              a.isArchived.equals(false),
                        )
                        ..orderBy([(a) => OrderingTerm.asc(a.name)]))
                      .watch(),
              builder: (context, snapshot) => DropdownButtonFormField<String>(
                initialValue: _account,
                decoration: const InputDecoration(labelText: 'Bank account'),
                items: [
                  for (final a in snapshot.data ?? <BankAccountEntity>[])
                    DropdownMenuItem(value: a.id, child: Text(a.name)),
                ],
                onChanged: _busy ? null : (v) => setState(() => _account = v),
              ),
            ),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: _busy || firm == null ? null : _import,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import PDF / CSV'),
                ),
                OutlinedButton(
                  onPressed: _busy || _account == null || _selected.isEmpty
                      ? null
                      : _confirm,
                  child: Text('Confirm ${_selected.length} selected payments'),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_message != null)
              Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
            Expanded(
              child: ListView.builder(
                itemCount: _rows.length,
                itemBuilder: (ctx, index) {
                  final row = _rows[index];
                  final candidates = BankReconciler(
                    db,
                    firm!,
                  ).suggest(row, _docs, aliases: _aliases);
                  final chosen = _selected[row];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${row.date.toIso8601String().substring(0, 10)}  ${row.amount > 0 ? 'Credit' : 'Debit'} ₹${row.amount.abs().toStringAsFixed(2)}  ${row.reference}',
                          ),
                          Text(row.description),
                          DropdownButtonFormField<String>(
                            key: ValueKey('${row.fingerprint}-${chosen?.id}'),
                            initialValue: chosen?.id,
                            isExpanded: true,
                            hint: const Text(
                              'Unmatched — choose a document after review',
                            ),
                            items: [
                              for (final c in candidates)
                                DropdownMenuItem(
                                  value: c.id,
                                  child: Text(
                                    '${c.party} · ${c.number} · balance ${c.balance.toStringAsFixed(2)} · ${c.reason.isEmpty ? 'manual match' : c.reason}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (id) => setState(() {
                                    _selected[row] = candidates.firstWhere(
                                      (c) => c.id == id,
                                    );
                                  }),
                          ),
                          if (chosen != null)
                            Wrap(
                              children: [
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => setState(
                                          () => _selected.remove(row),
                                        ),
                                  child: const Text('Clear match'),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _alias(row, chosen),
                                  child: const Text('Remember party alias'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
