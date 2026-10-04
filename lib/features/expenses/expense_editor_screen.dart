import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/payment_modes.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_form_section.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';

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

  /// Dropdown items for [options], guaranteed to contain [current].
  ///
  /// When the stored value is not one of the known ids it is added as its own
  /// item, showing the raw text. Expenses saved by an earlier build — and by
  /// the demo seeder — stored the human label ("Internet & Telephone") where
  /// the app now stores the id ("internet"), and `DropdownButtonFormField`
  /// asserts unless exactly one item matches its value, so opening such a row
  /// crashed the editor instead of showing the category it was saved with.
  List<DropdownMenuItem<String>> _options(
    List<({String id, String label})> options,
    String current,
  ) {
    return [
      if (!options.any((o) => o.id == current))
        DropdownMenuItem<String>(
          value: current,
          child: Text(current, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      for (final option in options)
        DropdownMenuItem<String>(
          value: option.id,
          child: Text(
            option.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

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
    if (expense == null ||
        expense.isDeleted ||
        // The route's type is fixed by which screen opened it; a mismatch
        // (deep link to an income id through the expense editor) would let
        // the save overwrite the row's category with one from the wrong
        // list — silently recategorizing the record.
        expense.type != widget.type) {
      // The row may have been deleted elsewhere (or is sitting in the bin);
      // bail to the list rather than showing a form whose save would touch
      // a record no list shows.
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
      _gstAmountController.text = expense.gstAmount == 0
          ? ''
          : _formatMoney(expense.gstAmount);
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
    if (picked == null || !mounted) return;
    setState(() {
      _date = picked;
      _dirty = true;
    });
  }

  // ---- Save ---------------------------------------------------------------

  Future<void> _save() async {
    if (await _saveCore() && mounted) context.pop();
  }

  /// Saves, then blanks the entry for the next one — the fast bookkeeping loop.
  /// Category, payment mode and date carry over; the money does not.
  Future<void> _saveAndNew() async {
    if (!await _saveCore() || !mounted) return;
    setState(() {
      _amountController.clear();
      _gstAmountController.clear();
      _vendorController.clear();
      _referenceController.clear();
      _notesController.clear();
      _dirty = false;
    });
  }

  /// Shared body of Save and Save & New. Returns true when the record was
  /// written; false leaves the form exactly as the user left it.
  Future<bool> _saveCore() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = ref.read(expenseRepositoryProvider);
    final firmRepo = ref.read(firmRepositoryProvider);
    final firm = ref.read(activeFirmProvider).valueOrNull;

    if (repo == null || firm == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Open a firm before saving a record.')),
      );
      return false;
    }

    if (!(_formKey.currentState?.validate() ?? false)) return false;

    // Money.parse THROWS on malformed amounts (a typo must never become a
    // ₹0 record) — catch it here and tell the user which field is wrong.
    final amount = Money.tryParse(_amountController.text);
    if (amount == null || amount <= Decimal.zero) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Enter a valid amount greater than zero.'),
        ),
      );
      return false;
    }

    if (_saving) return false; // double-submit guard.

    final gstAmountDraft = _gstIncluded
        ? (Money.tryParse(_gstAmountController.text) ?? Decimal.zero)
        : Decimal.zero;
    if (gstAmountDraft > amount) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('The GST amount cannot exceed the total amount.'),
        ),
      );
      return false;
    }

    setState(() => _saving = true);
    try {
      final vendor = _vendorController.text.trim();
      final reference = _referenceController.text.trim();
      final notes = _notesController.text.trim();
      final gstAmount = gstAmountDraft.toDouble();

      if (_isEditing) {
        final original = _original!;
        await repo.update(
          original.copyWith(
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
          ),
        );
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
      if (!mounted) return false;
      // The screen popped with no confirmation — on a slow device the save
      // looked like the app simply discarded the entry.
      messenger?.showSnackBar(
        SnackBar(content: Text(_isExpense ? 'Expense saved' : 'Income saved')),
      );
      _dirty = false;
      return true;
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save the record: $error')),
      );
      return false;
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
        child: EditorShell(
          title: _isEditing
              ? (_isExpense ? 'Edit Expense' : 'Edit Income')
              : (_isExpense ? 'New Expense' : 'New Income'),
          actions: EditorActions(
            onSave: _save,
            onSaveAndNew: _isEditing ? null : _saveAndNew,
            onExit: () => context.pop(),
            saving: _saving,
          ),
          hint: 'Tab → next field   ·   Ctrl+S → save & close',
          body: _body(repo != null),
        ),
      ),
    );
  }

  Widget _body(bool hasFirm) {
    if (!hasFirm) {
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
    // The money and the date lead, where they sit on an invoice; the
    // classification follows. One Save action, in the action bar — a second
    // button at the foot of the form was a competing primary.
    return EditorShellBody(
      form: Form(
        key: _formKey,
        child: AtriaEditorForm(
          maxContentWidth: 1000,
          header: _amountSection(),
          headerTrailing: _dateSection(),
          sections: [_categorySection(), _paymentSection(), _notesSection()],
        ),
      ),
    );
  }

  /// The figure being recorded, plus how it relates to GST.
  Widget _amountSection() {
    return AtriaFormSection(
      icon: Icons.payments_outlined,
      title: 'Amount',
      children: [
        TextFormField(
          controller: _amountController,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
          textInputAction: TextInputAction.next,
          onChanged: (_) => _markDirty(),
          decoration: InputDecoration(
            labelText: 'Amount *',
            prefixText: '${AppConstants.currencySymbol} ',
          ),
          validator: (value) => Validators.amount(value, allowZero: false),
        ),
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
          const SizedBox(height: 4),
          TextFormField(
            controller: _gstAmountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            textInputAction: TextInputAction.next,
            onChanged: (_) => _markDirty(),
            decoration: InputDecoration(
              labelText: 'GST amount',
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
    );
  }

  Widget _dateSection() {
    return AtriaFormSection(
      icon: Icons.calendar_today_rounded,
      title: 'Date',
      children: [
        InkWell(
          onTap: _pickDate,
          borderRadius: AppRadius.mdAll,
          child: InputDecorator(
            decoration: const InputDecoration(labelText: 'Date *'),
            child: Text(
              Formatters.date(_date),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _categorySection() {
    return AtriaFormSection(
      icon: Icons.category_outlined,
      title: _isExpense ? 'Expense details' : 'Income details',
      children: [
        DropdownButtonFormField<String>(
          iconSize: AppIconSize.md,
          initialValue: _category,
          // isExpanded: a DropdownButton sizes to its WIDEST item, so an
          // unexpanded one overflows the field on a phone.
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Category *',
            prefixIcon: AtriaFieldIcon(Icons.category_outlined),
          ),
          items: _options(
            _isExpense
                ? [
                    for (final c in ExpenseCategory.all)
                      (id: c.id, label: c.label),
                  ]
                : [
                    for (final c in IncomeCategory.all)
                      (id: c.id, label: c.label),
                  ],
            _category,
          ),
          onChanged: (value) {
            _markDirty();
            setState(() => _category = value ?? _category);
          },
        ),
      ],
    );
  }

  Widget _paymentSection() {
    return AtriaFormSection(
      icon: Icons.account_balance_wallet_outlined,
      title: 'Payment',
      children: [
        DropdownButtonFormField<String>(
          iconSize: AppIconSize.md,
          initialValue: _mode,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Payment mode',
            prefixIcon: AtriaFieldIcon(Icons.account_balance_wallet_outlined),
          ),
          items: _options([
            for (final mode in PaymentMode.all)
              (id: mode.id, label: mode.label),
          ], _mode),
          onChanged: (value) {
            _markDirty();
            setState(() => _mode = value ?? _mode);
          },
        ),
        const SizedBox(height: 12),
        AtriaFormFieldRow(
          first: TextFormField(
            controller: _vendorController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _markDirty(),
            decoration: InputDecoration(
              labelText: _isExpense ? 'Vendor / payee' : 'Received from',
              hintText: 'Optional',
              prefixIcon: const AtriaFieldIcon(Icons.storefront_outlined),
            ),
          ),
          second: TextFormField(
            controller: _referenceController,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _markDirty(),
            decoration: const InputDecoration(
              labelText: 'Reference',
              hintText: 'Optional',
              prefixIcon: AtriaFieldIcon(Icons.tag_rounded),
            ),
          ),
        ),
      ],
    );
  }

  Widget _notesSection() {
    return AtriaFormSection(
      icon: Icons.notes_rounded,
      title: 'Notes',
      dense: true,
      children: [
        TextFormField(
          controller: _notesController,
          textCapitalization: TextCapitalization.sentences,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) => _markDirty(),
          decoration: const InputDecoration(
            labelText: 'Notes',
            hintText: 'Anything to remember about this record',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}
