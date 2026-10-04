import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/ledger_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// One editable journal line, held as controllers so the fields survive a
/// rebuild while the user is halfway through typing an amount.
class _Line {
  _Line({
    this.accountId,
    String debit = '',
    String credit = '',
    String narration = '',
  })  : debit = TextEditingController(text: debit),
        credit = TextEditingController(text: credit),
        narration = TextEditingController(text: narration);

  String? accountId;
  final TextEditingController debit;
  final TextEditingController credit;
  final TextEditingController narration;

  // `Money.tryParse`, not `double.tryParse`: an accountant types "1,00,000"
  // with Indian grouping, and `double.tryParse` returns null for the comma —
  // the line would save as ₹0 with no warning, and a voucher that silently
  // drops its amount is how the books stop balancing.
  double get debitValue => Money.tryParse(debit.text)?.toDouble() ?? 0;
  double get creditValue => Money.tryParse(credit.text)?.toDouble() ?? 0;

  void dispose() {
    debit.dispose();
    credit.dispose();
    narration.dispose();
  }
}

/// The journal voucher editor.
///
/// Debits must equal credits before the voucher can be saved — the same rule
/// the repository enforces, shown while it is being typed rather than as an
/// error after the fact. A voucher that does not balance is not a warning; it
/// is the one thing that would make every report in the app wrong.
class JournalEditorScreen extends ConsumerStatefulWidget {
  const JournalEditorScreen({super.key, this.editId});

  final String? editId;

  bool get isEditing => editId != null;

  @override
  ConsumerState<JournalEditorScreen> createState() =>
      _JournalEditorScreenState();
}

class _JournalEditorScreenState extends ConsumerState<JournalEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _narration = TextEditingController();
  final _reference = TextEditingController();
  final _lines = <_Line>[_Line(), _Line()];

  DateTime _date = DateTime.now();
  String? _number;
  bool _loading = false;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) _load();
  }

  @override
  void dispose() {
    _narration.dispose();
    _reference.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null) return;
    setState(() => _loading = true);
    final entry = await repo.journalById(widget.editId!);
    final lines = await repo.journalLinesOf(widget.editId!);
    if (!mounted) return;
    if (entry == null) {
      setState(() => _loading = false);
      _snack('That voucher no longer exists.');
      return;
    }
    _narration.text = entry.narration;
    _reference.text = entry.reference ?? '';
    _date = entry.date;
    _number = entry.number;
    for (final line in _lines) {
      line.dispose();
    }
    _lines
      ..clear()
      ..addAll(lines.map((l) => _Line(
            accountId: l.accountId,
            debit: l.debit == 0 ? '' : l.debit.toStringAsFixed(2),
            credit: l.credit == 0 ? '' : l.credit.toStringAsFixed(2),
            narration: l.narration ?? '',
          )));
    if (_lines.length < 2) _lines.add(_Line());
    setState(() => _loading = false);
  }

  double get _totalDebit {
    var total = 0.0;
    for (final line in _lines) {
      total += line.debitValue;
    }
    return total;
  }

  double get _totalCredit {
    var total = 0.0;
    for (final line in _lines) {
      total += line.creditValue;
    }
    return total;
  }

  double get _difference => _totalDebit - _totalCredit;

  bool get _balanced => _difference.abs() < 0.005 && _totalDebit > 0;

  int get _filledLines =>
      _lines.where((l) => l.accountId != null && (l.debitValue > 0 || l.creditValue > 0)).length;

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(chartOfAccountsProvider).valueOrNull ?? const [];
    final active = accounts.where((a) => a.isActive).toList();

    // A line can point at an account that was archived after the voucher was
    // written — the account is retired from the chart, not from history (see
    // `setAccountActive`). The dropdown asserts that its initial value matches
    // an item, so those accounts have to stay selectable here or editing an
    // old voucher asserts in debug and renders a blank field in release.
    final referenced = <String>{
      for (final line in _lines)
        if (line.accountId != null) line.accountId!,
    };
    final selectable = <AccountEntity>[
      ...active,
      for (final account in accounts)
        if (!account.isActive && referenced.contains(account.id)) account,
    ];

    return SaveShortcut(
      enabled: !_saving && _balanced,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_saving,
        child: EditorShell(
          title: widget.isEditing
              ? 'Journal ${_number ?? ''}'
              : 'New journal entry',
          actions: EditorActions(
            // Kept enabled while the voucher is unbalanced: the shell has no
            // disabled state, and a silent dead button reads as a broken app.
            // [_save] refuses and says why.
            onSave: _save,
            onExit: () => context.pop(),
            saving: _saving,
            saveLabel: 'Save voucher',
          ),
          hint: 'Every rupee needs a debit and a credit   ·   Ctrl+S to save',
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _body(selectable),
        ),
      ),
    );
  }

  Widget _body(List<AccountEntity> accounts) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Form(
      key: _formKey,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              AtriaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _pickDate,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            prefixIcon: Icon(PhosphorIconsRegular.calendarBlank),
                          ),
                          child: Text(Formatters.date(_date)),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: _reference,
                        decoration: const InputDecoration(
                            labelText: 'Reference (optional)'),
                        onChanged: (_) => setState(() => _dirty = true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _narration,
                  autofocus: !widget.isEditing,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Narration',
                    hintText: 'Capital introduced by the proprietor',
                    helperText:
                        'What this voucher is for. A voucher without a reason '
                        'is the hardest thing to audit a year later.',
                  ),
                  validator: (value) => (value ?? '').trim().isEmpty
                      ? 'Say what this voucher is for.'
                      : null,
                  onChanged: (_) => setState(() => _dirty = true),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.lg),
          SectionHeader(
            title: 'Lines',
            subtitle: 'Debit one account, credit another. One side per line.',
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
          ),
          for (var i = 0; i < _lines.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: _LineRow(
                key: ValueKey(_lines[i]),
                line: _lines[i],
                accounts: accounts,
                onChanged: () => setState(() => _dirty = true),
                onRemove: _lines.length > 2
                    ? () => setState(() {
                          _lines[i].dispose();
                          _lines.removeAt(i);
                          _dirty = true;
                        })
                    : null,
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() {
                _lines.add(_Line());
                _dirty = true;
              }),
              icon: const Icon(PhosphorIconsRegular.plus),
              label: const Text('Add line'),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          AtriaCard(
            child: Column(
              children: [
                _TotalRow(label: 'Total debit', value: _totalDebit),
                const SizedBox(height: AppSpace.xs),
                _TotalRow(label: 'Total credit', value: _totalCredit),
                const Divider(height: AppSpace.xl),
                _TotalRow(
                  label: _balanced ? 'Balanced' : 'Difference',
                  value: _balanced ? 0 : _difference.abs(),
                  emphasize: true,
                  color: _balanced
                      ? atriaColors(context).positive
                      : atriaColors(context).negative,
                ),
                if (!_balanced) ...[
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _totalDebit == 0 && _totalCredit == 0
                          ? 'Enter the amounts for at least two lines.'
                          : 'Debits and credits must be the same amount before '
                              'this voucher can be saved.',
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
                if (_filledLines > 0 && _filledLines < 2) ...[
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'A voucher needs at least two lines with an account and '
                      'an amount.',
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xxl),
        ],
      ),
    ),
  ),
);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _dirty = true;
      });
    }
  }

  Future<void> _save() async {
    final repo = ref.read(ledgerRepositoryProvider);
    if (repo == null || _saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (!_balanced) {
      _snack('Debits and credits must match before saving.');
      return;
    }
    final drafts = <JournalLineDraft>[];
    for (final line in _lines) {
      if (line.accountId == null) continue;
      if (line.debitValue == 0 && line.creditValue == 0) continue;
      drafts.add(JournalLineDraft(
        accountId: line.accountId!,
        debit: line.debitValue,
        credit: line.creditValue,
        narration: line.narration.text.trim().isEmpty
            ? null
            : line.narration.text.trim(),
      ));
    }
    if (drafts.length < 2) {
      _snack('A voucher needs at least two lines.');
      return;
    }

    setState(() => _saving = true);
    try {
      if (widget.isEditing) {
        await repo.updateJournal(
          widget.editId!,
          date: _date,
          narration: _narration.text,
          lines: drafts,
          reference: _reference.text.trim().isEmpty
              ? null
              : _reference.text.trim(),
        );
      } else {
        await repo.createJournal(
          date: _date,
          narration: _narration.text,
          lines: drafts,
          reference: _reference.text.trim().isEmpty
              ? null
              : _reference.text.trim(),
        );
      }
      if (!mounted) return;
      _dirty = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(widget.isEditing ? 'Voucher saved' : 'Voucher posted')),
      );
      context.pop();
    } catch (error) {
      _snack('$error'.replaceFirst('Bad state: ', ''));
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({
    super.key,
    required this.line,
    required this.accounts,
    required this.onChanged,
    this.onRemove,
  });

  final _Line line;
  final List<AccountEntity> accounts;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 600;

    final accountField = DropdownButtonFormField<String>(
      initialValue: line.accountId,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Account'),
      items: [
        for (final account in accounts)
          DropdownMenuItem(
            value: account.id,
            child: Text(
              account.isActive
                  ? '${account.code}  ${account.name}'
                  : '${account.code}  ${account.name}  (archived)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) {
        line.accountId = value;
        onChanged();
      },
    );

    final debitField = TextField(
      controller: line.debit,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'Debit'),
      textAlign: TextAlign.right,
      // A line is one side or the other. Clearing the opposite
      // field as it is typed means the invalid state — both filled
      // — cannot be reached through the UI at all.
      onChanged: (value) {
        if (value.isNotEmpty && line.credit.text.isNotEmpty) {
          line.credit.clear();
        }
        onChanged();
      },
    );

    final creditField = TextField(
      controller: line.credit,
      keyboardType:
          const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'Credit'),
      textAlign: TextAlign.right,
      onChanged: (value) {
        if (value.isNotEmpty && line.debit.text.isNotEmpty) {
          line.debit.clear();
        }
        onChanged();
      },
    );

    final removeButton = onRemove != null
        ? IconButton(
            tooltip: 'Remove line',
            onPressed: onRemove,
            icon: const Icon(PhosphorIconsRegular.x),
          )
        : null;

    return AtriaCard(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        children: [
          if (isCompact) ...[
            Row(
              children: [
                Expanded(child: accountField),
                ?removeButton,
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Expanded(child: debitField),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: creditField),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(flex: 4, child: accountField),
                const SizedBox(width: AppSpace.sm),
                Expanded(flex: 2, child: debitField),
                const SizedBox(width: AppSpace.sm),
                Expanded(flex: 2, child: creditField),
                ?removeButton,
              ],
            ),
          ],
          const SizedBox(height: AppSpace.sm),
          TextField(
            controller: line.narration,
            decoration: const InputDecoration(
              labelText: 'Line note (optional)',
              isDense: true,
            ),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({
    required this.label,
    required this.value,
    this.emphasize = false,
    this.color,
  });

  final String label;
  final double value;
  final bool emphasize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: (emphasize ? text.titleMedium : text.bodyMedium)
              ?.copyWith(color: emphasize ? (color ?? muted) : muted),
        ),
        Text(
          Formatters.money(Money.of(value)),
          style: (emphasize ? text.titleMedium : text.bodyMedium)?.copyWith(
            color: color,
            fontWeight: emphasize ? FontWeight.w600 : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
