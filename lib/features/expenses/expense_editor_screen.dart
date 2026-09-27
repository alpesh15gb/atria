import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/payment_modes.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';

/// Records a business expense or other income. [type] is 'expense' or 'income'
/// and is fixed by the caller.
class ExpenseEditorScreen extends ConsumerStatefulWidget {
  const ExpenseEditorScreen({super.key, this.type = 'expense', this.editId});

  /// 'expense' or 'income' — decides categories, labels and the doc sequence.
  final String type;

  /// When set, the editor loads and updates that record instead of creating
  /// one. [type] must match the stored record's type.
  final String? editId;

  @override
  ConsumerState<ExpenseEditorScreen> createState() =>
      _ExpenseEditorScreenState();
}

class _ExpenseEditorScreenState extends ConsumerState<ExpenseEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _vendorController = TextEditingController();
  final _referenceController = TextEditingController();
  final _notesController = TextEditingController();
  final _gstAmountController = TextEditingController();

  late String _category = widget.type == 'income'
      ? IncomeCategory.all.first.id
      : ExpenseCategory.all.first.id;
  DateTime _date = DateTime.now();
  String _mode = PaymentMode.cash.id;
  bool _gstIncluded = false;

  bool _saving = false;
  bool _loading = false;
  bool _dirty = false;
  ExpenseEntity? _original;

  void _markDirty() {
    if (_dirty) return;
    _dirty = true;
    if (mounted) setState(() {});
  }

  bool get _isExpense => widget.type == 'expense';
  bool get _isEditing => widget.editId != null;

  @override
  void initState() {
    super.initState();
    if (widget.editId != null) {
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    setState(() => _loading = true);
    final repo = ref.read(expenseRepositoryProvider);
    final expense = await repo?.getById(widget.editId!);
    if (!mounted) return;
    if (expense == null) {
      // The row may have been deleted elsewhere; bail to the list rather
      // than showing a form that would overwrite nothing.
      context.pop();
      return;
    }
    setState(() {
      _original = expense;
      _category = expense.category;
      _date = expense.date;
      _mode = expense.mode;
      _gstIncluded = expense.gstAmount > 0;
      _amountController.text = _formatMoney(expense.amount);
      _gstAmountController.text =
          expense.gstAmount == 0 ? '' : _formatMoney(expense.gstAmount);
      _vendorController.text = expense.vendorName ?? '';
      _referenceController.text = expense.reference ?? '';
      _notesController.text = expense.notes ?? '';
      _loading = false;
    });
  }

  String _formatMoney(double value) {
    final decimal = Money.of(value);
    return decimal.toStringAsFixed(2);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _vendorController.dispose();
    _referenceController.dispose();
    _notesController.dispose();
    _gstAmountController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;                    setState(() {
                      _date = picked;
                      _dirty = true;
                    });
  }

  // ---- Save ---------------------------------------------------------------

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = ref.read(expenseRepositoryProvider);
    final firmRepo = ref.read(firmRepositoryProvider);
    final firm = ref.read(activeFirmProvider).valueOrNull;

    if (repo == null || firm == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Open a firm before saving a record.')),
      );
      return;
    }

    if (!(_formKey.currentState?.validate() ?? false)) return;

    // Money.parse THROWS on malformed amounts (a typo must never become a
    // ₹0 record) — catch it here and tell the user which field is wrong.
    final amount = Money.tryParse(_amountController.text);
    if (amount == null || amount <= Decimal.zero) {
      messenger?.showSnackBar(const SnackBar(
        content: Text('Enter a valid amount greater than zero.'),
      ));
      return;
    }

    if (_saving) return; // double-submit guard.

    setState(() => _saving = true);
    try {
      final vendor = _vendorController.text.trim();
      final reference = _referenceController.text.trim();
      final notes = _notesController.text.trim();
      final gstAmount = _gstIncluded
          ? (Money.tryParse(_gstAmountController.text) ?? Decimal.zero)
              .toDouble()
          : 0.0;

      if (_isEditing) {
        final original = _original!;
        await repo.update(original.copyWith(
          category: _category,
          amount: amount.toDouble(),
          date: _date,
          mode: _mode,
          // Nullable columns need drift's Value wrapper so clearing a field
          // actually writes NULL instead of being treated as "unchanged".
          vendorName: Value(vendor.isEmpty ? null : vendor),
          reference: Value(reference.isEmpty ? null : reference),
          gstAmount: gstAmount,
          notes: Value(notes.isEmpty ? null : notes),
        ));
      } else {
        final number = await firmRepo.nextNumber(
          firm,
          DocSequence.expense,
          date: _date,
        );
        await repo.create(
          type: widget.type,
          number: number,
          category: _category,
          amount: amount.toDouble(),
          date: _date,
          mode: _mode,
          vendorName: vendor.isEmpty ? null : vendor,
          reference: reference.isEmpty ? null : reference,
          gstAmount: gstAmount,
          notes: notes.isEmpty ? null : notes,
        );
      }
      if (!mounted) return;
      // The screen popped with no confirmation — on a slow device the save
      // looked like the app simply discarded the entry.
      messenger?.showSnackBar(
        SnackBar(
            content: Text(_isExpense ? 'Expense saved' : 'Income saved')),
      );
      context.pop();
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save the record: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(expenseRepositoryProvider);
    return SaveShortcut(
      enabled: !_saving,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_saving,
        child: Scaffold(
          appBar: EditorAppBar(
            title: _isEditing
                ? (_isExpense ? 'Edit Expense' : 'Edit Income')
                : (_isExpense ? 'New Expense' : 'New Income'),
            saving: _saving,
            enabled: repo != null,
            onSave: _save,
            onExit: () => context.pop(),
          ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (repo == null) {
              return const Center(
                child: EmptyState(
                  icon: Icons.business_center_outlined,
                  title: 'No firm selected',
                  message: 'Choose or create a firm to record expenses.',
                ),
              );
            }
            if (_loading) {
              return const Center(child: CircularProgressIndicator());
            }
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 720,
                ),
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _categorySection(),
                        const SizedBox(height: 16),
                        _paymentSection(),
                        const SizedBox(height: 16),
                        _notesSection(),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _saving ? null : _save,
                          child: Text(
                            _saving
                                ? 'Saving…'
                                : _isEditing
                                    ? 'Save Changes'
                                    : _isExpense
                                        ? 'Save Expense'
                                        : 'Save Income',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
        ),
      ),
    );
  }

  Widget _sectionCard(Widget child) =>
      AtriaCard(padding: const EdgeInsets.all(16), child: child);

  Widget _categorySection() {
    return _sectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: _isExpense ? 'Expense details' : 'Income details',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(
              labelText: 'Category *',
              prefixIcon: Icon(Icons.category_outlined),
            ),
            items: _isExpense
                ? [
                    for (final category in ExpenseCategory.all)
                      DropdownMenuItem<String>(
                        value: category.id,
                        child: Text(category.label),
                      ),
                  ]
                : [
                    for (final category in IncomeCategory.all)
                      DropdownMenuItem<String>(
                        value: category.id,
                        child: Text(category.label),
                      ),
                  ],
            onChanged: (value) => setState(() => _category = value ?? _category),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _amountController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Amount *',
              prefixIcon: const Icon(Icons.payments_outlined),
              prefixText: '${AppConstants.currencySymbol} ',
            ),
            validator: (value) =>
                Validators.amount(value, allowZero: false),
          ),
          const SizedBox(height: 16),
          InkWell(
            onTap: _pickDate,
            borderRadius: AppRadius.mdAll,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Date *',
                prefixIcon: Icon(Icons.calendar_today_rounded),
              ),
              child: Text(
                Formatters.date(_date),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentSection() {
    return _sectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Payment', padding: EdgeInsets.zero),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: 'Payment mode',
              prefixIcon: Icon(Icons.account_balance_wallet_outlined),
            ),
            items: [
              for (final mode in PaymentMode.all)
                DropdownMenuItem<String>(
                  value: mode.id,
                  child: Text(mode.label),
                ),
            ],
            onChanged: (value) {
              _markDirty();
              setState(() => _mode = value ?? _mode);
            },
          ),
          const SizedBox(height: 16),
          _FieldRow(
            first: TextFormField(
              controller: _vendorController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: _isExpense ? 'Vendor / payee' : 'Received from',
                hintText: 'Optional',
                prefixIcon: const Icon(Icons.storefront_outlined),
              ),
            ),
            second: TextFormField(
              controller: _referenceController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Reference',
                hintText: 'Optional',
                prefixIcon: Icon(Icons.tag_rounded),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: const Text('GST included'),
            subtitle: const Text(
              'Turn on if the amount above already contains GST',
            ),
            value: _gstIncluded,
            onChanged: (value) {
              _markDirty();
              setState(() => _gstIncluded = value);
            },
          ),
          if (_gstIncluded) ...[
            const SizedBox(height: 8),
            TextFormField(
              controller: _gstAmountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'GST amount',
                prefixIcon: const Icon(Icons.percent_rounded),
                prefixText: '${AppConstants.currencySymbol} ',
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) return null;
                final parsed = Money.tryParse(value);
                if (parsed == null) return 'Enter a valid amount';
                if (parsed < Decimal.zero) return 'Amount cannot be negative';
                return null;
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _notesSection() {
    return _sectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Notes', padding: EdgeInsets.zero),
          const SizedBox(height: 16),
          TextFormField(
            controller: _notesController,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Notes',
              hintText: 'Anything to remember about this record',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two fields side by side on wide content areas, stacked on narrow ones.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: 12),
              second,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: first),
              const SizedBox(width: 12),
              Expanded(child: second),
            ],
          ),
        );
      },
    );
  }
}
