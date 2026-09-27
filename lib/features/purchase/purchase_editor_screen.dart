import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/gst.dart';
import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/purchase_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_utils.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/editor_totals.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/item_type_ahead.dart';
import '../../shared/widgets/tax_mode_toggle.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Sentinel dropdown value that opens the party editor instead of selecting a
/// supplier.
const String _kAddNewSupplier = '__add_new_supplier__';

/// Creates or edits a purchase bill. Pass [editId] to edit; leave it null to
/// create.
class PurchaseEditorScreen extends ConsumerStatefulWidget {
  const PurchaseEditorScreen({super.key, this.editId, this.docType = 'bill'});

  final String? editId;

  /// 'bill' or 'debit_note' (purchase return). A debit note still restores
  /// stock — you received the goods back — but does not add to payables.
  final String docType;

  @override
  ConsumerState<PurchaseEditorScreen> createState() =>
      _PurchaseEditorScreenState();
}

class _PurchaseEditorScreenState extends ConsumerState<PurchaseEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _supplierInvoiceController = TextEditingController();
  final _invoiceDiscountController = TextEditingController();
  final _shippingController = TextEditingController();
  final _otherChargesController = TextEditingController();
  final _notesController = TextEditingController();

  final List<_LineState> _lines = <_LineState>[];
  List<PartyEntity> _suppliers = const [];
  List<ItemEntity> _items = const [];

  /// Live item feed so the line picker sees items saved after this editor
  /// opened. Nulled on dispose; [_load] owns the subscription.
  StreamSubscription<List<ItemEntity>>? _itemsSub;

  PurchaseBillEntity? _existing;
  DateTime _billDate = DateTime.now();
  DateTime? _dueDate;
  String? _selectedSupplierId;
  bool _isInterState = false;
  bool _reverseCharge = false;
  bool _applyRoundOff = true;

  bool _loading = true;
  bool _saving = false;
  bool _notFound = false;

  /// Every editor field routes its `onChanged` through here, so a rebuild and
  /// a dirty flag can never drift apart.
  void _changed([void Function()? mutate]) {
    mutate?.call();
    _dirty = true;
    setState(() {});
  }

  bool _dirty = false;

  /// Vyapar flow: a typed item name that matches nothing is SAVED as a new
  /// item without asking anything, and the line links to it. Rate defaults
  /// come from the line the user typed into.
  Future<void> _createItemFromLine(_LineState line, String name) async {
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null) return;
    try {
      final item = await repo.create(
        name: name,
        unit: line.unit,
        purchasePrice: line.rate.toDouble(),
        gstRate: line.gstRate,
        taxMode: line.taxMode == TaxMode.inclusive ? 'inclusive' : 'exclusive',
        isService: false,
        stockType: 'tracked',
      );
      if (!mounted) return;
      line.applyItem(item, _formatAmount);
      _changed();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save item "$name": $error')),
      );
    }
  }

  bool get _isEditing => widget.editId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    unawaited(_itemsSub?.cancel());
    _supplierInvoiceController.dispose();
    _invoiceDiscountController.dispose();
    _shippingController.dispose();
    _otherChargesController.dispose();
    _notesController.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final partyRepo = ref.read(partyRepositoryProvider);
    final itemRepo = ref.read(itemRepositoryProvider);
    final purchaseRepo = ref.read(purchaseRepositoryProvider);

    final suppliers = partyRepo == null
        ? const <PartyEntity>[]
        : await partyRepo.all(type: 'supplier', limit: 1000);
    final items = itemRepo == null
        ? const <ItemEntity>[]
        : await itemRepo.all(limit: 1000);

    // Keep the line-item picker live: an item saved after this editor opened
    // must appear without reopening the editor. _LineCard reads `_items` at
    // build time, so a setState re-render is enough to refresh open lines.
    _itemsSub = itemRepo?.watchAll().listen((items) {
      if (mounted) setState(() => _items = items);
    });

    PurchaseBillEntity? bill;
    List<PurchaseBillItemEntity> billItems = const [];
    if (widget.editId != null && purchaseRepo != null) {
      bill = await purchaseRepo.getById(widget.editId!);
      billItems = bill == null ? const [] : await purchaseRepo.itemsFor(bill.id);
    }

    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _items = items;
      _existing = bill;
      if (bill != null) {
        _prefill(bill, billItems);
      } else if (widget.editId != null) {
        _notFound = true;
        _loading = false;
        return;
      } else {
        _lines.add(_LineState(id: IdUtils.newId()));
      }
      _loading = false;
    });
    // Prefilling a bill being edited is not an unsaved change.
    _dirty = false;
  }

  void _prefill(PurchaseBillEntity bill, List<PurchaseBillItemEntity> items) {
    _supplierInvoiceController.text = bill.supplierInvoiceNumber ?? '';
    _invoiceDiscountController.text = _formatAmount(bill.invoiceDiscountPercent);
    _shippingController.text = _formatAmount(bill.shippingCharge);
    _otherChargesController.text = _formatAmount(bill.otherCharges);
    _notesController.text = bill.notes ?? '';
    _billDate = bill.billDate;
    _dueDate = bill.dueDate;
    _selectedSupplierId = bill.partyId;
    _isInterState = bill.isInterState;
    _reverseCharge = bill.reverseCharge;
    _applyRoundOff = true;

    for (final item in items) {
      _lines.add(_LineState(id: item.id)..applyEntity(item));
    }
  }

  /// Groups digits the Indian way and drops ".0" for whole numbers.
  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return Formatters.indianGroup(value.toInt().toString());
    }
    return Formatters.number(Money.of(value));
  }

  PartyEntity? _supplierWithId(String? id) {
    if (id == null) return null;
    for (final supplier in _suppliers) {
      if (supplier.id == id) return supplier;
    }
    return null;
  }

  Future<void> _addNewSupplier() async {
    // `type=supplier` puts the party editor in supplier mode, and the popped
    // id lets us select the party that was just created. Without it the
    // dropdown stayed on nothing and the sentinel stayed "selected".
    final createdId =
        await context.push<String>('/parties/new?type=supplier');
    if (!mounted || createdId == null) return;
    final partyRepo = ref.read(partyRepositoryProvider);
    if (partyRepo == null) return;
    final suppliers = await partyRepo.all(type: 'supplier', limit: 1000);
    if (!mounted) return;
    setState(() {
      _suppliers = suppliers;
      _selectSupplier(createdId);
      _dirty = true;
    });
  }

  void _selectSupplier(String? supplierId) {
    final firm = ref.read(activeFirmProvider).valueOrNull;
    final supplier = _supplierWithId(supplierId);
    setState(() {
      _selectedSupplierId = supplierId;
      if (supplier == null || firm == null) return;
      _isInterState = resolveGstSplit(
            supplierState: supplier.stateCode,
            buyerState: firm.stateCode,
          ) ==
          GstSplit.interState;
    });
  }

  GstSplit get _split =>
      _isInterState ? GstSplit.interState : GstSplit.intraState;

  GstResult get _totals {
    final lines = _lines.where((line) => line.isValid).toList();
    if (lines.isEmpty) return GstResult.empty();
    return GstEngine.computeDocument(
      lines: lines.map((line) => line.toTaxLine()).toList(),
      split: _split,
      invoiceDiscountPercent:
          Money.tryParse(_invoiceDiscountController.text) ?? Decimal.zero,
      applyRoundOff: _applyRoundOff,
    );
  }

  Future<void> _pickDate({required bool isBillDate}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isBillDate
          ? _billDate
          : (_dueDate ?? _billDate.add(const Duration(days: 30))),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    _changed(() {
      if (isBillDate) {
        _billDate = picked;
        if (_dueDate != null && _dueDate!.isBefore(picked)) {
          _dueDate = null;
        }
      } else {
        _dueDate = picked;
      }
    });
  }

  // ---- Save ---------------------------------------------------------------

  Future<bool> _saveCore() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = ref.read(purchaseRepositoryProvider);
    final firmRepo = ref.read(firmRepositoryProvider);
    final firm = ref.read(activeFirmProvider).valueOrNull;

    if (repo == null || firm == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Open a firm before saving a bill.')),
      );
      return false;
    }

    if (!(_formKey.currentState?.validate() ?? false)) return false;

    final lines = _lines.where((line) => line.isValid).map((line) => line.toDraft()).toList();
    if (lines.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Add at least one line with a name and quantity.'),
        ),
      );
      return false;
    }

    if (_saving) return false; // double-submit guard.

    setState(() => _saving = true);
    try {
      final number = _isEditing
          ? _existing!.number
          : await firmRepo.nextNumber(
              firm,
              widget.docType == 'debit_note'
                  ? DocSequence.debitNote
                  : DocSequence.purchase,
              date: _billDate);
      final supplier = _supplierWithId(_selectedSupplierId);
      final address = [
        supplier?.addressLine1,
        supplier?.addressLine2,
        supplier?.city,
        supplier?.pincode,
      ].where((part) => part != null && part.trim().isNotEmpty).join(', ');

      final draft = PurchaseDraft(
        id: _isEditing ? _existing!.id : IdUtils.newId(),
        number: number,
        docType: widget.docType,
        partyId: supplier?.id,
        supplierInvoiceNumber: _supplierInvoiceController.text.trim().isEmpty
            ? null
            : _supplierInvoiceController.text.trim(),
        billDate: _billDate,
        dueDate: _dueDate,
        // Keep the stored status when editing: hardcoding 'confirmed'
        // silently re-activated a cancelled bill on any edit.
        status: _isEditing ? (_existing?.status ?? 'confirmed') : 'confirmed',
        lines: lines,
        partyName: supplier?.name,
        partyGstin: supplier?.gstin,
        partyGstType: supplier?.gstType,
        partyPhone: supplier?.phone,
        billingAddress: address.isEmpty ? null : address,
        placeOfSupply: supplier?.stateCode,
        isInterState: _isInterState,
        reverseCharge: _reverseCharge,
        invoiceDiscountPercent:
            Money.tryParse(_invoiceDiscountController.text) ?? Decimal.zero,
        invoiceDiscountAmount: Decimal.zero,
        shippingCharge:
            Money.tryParse(_shippingController.text) ?? Decimal.zero,
        otherCharges:
            Money.tryParse(_otherChargesController.text) ?? Decimal.zero,
        applyRoundOff: _applyRoundOff,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        sequence: _isEditing ? _existing!.sequence : 0,
      );

      await repo.save(draft, affectStock: true);
      if (!mounted) return false;
      _dirty = false;
      return true;
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save the bill: $error')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final saved = await _saveCore();
    if (saved && mounted) context.pop();
  }

  /// Saves this bill, then blanks the form for the next one — supplier and
  /// tax mode carry over, everything else resets. A failed save keeps every
  /// value so nothing is lost.
  Future<void> _saveAndNew() async {
    final saved = await _saveCore();
    if (!saved || !mounted) return;
    _changed(() {
      _supplierInvoiceController.clear();
      _invoiceDiscountController.text = '0';
      _shippingController.text = '0';
      _otherChargesController.text = '0';
      _notesController.clear();
      _billDate = DateTime.now();
      _dueDate = null;
      _applyRoundOff = true;
      for (final line in _lines) {
        line.dispose();
      }
      _lines.clear();
      _lines.add(_LineState(id: IdUtils.newId()));
      _dirty = false;
    });
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(purchaseRepositoryProvider);
    return SaveShortcut(
      enabled: !_saving,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_saving,
        child: EditorShell(
          title: _isEditing
              ? (widget.docType == 'debit_note'
                  ? 'Edit Debit Note'
                  : 'Edit Purchase Bill')
              : (widget.docType == 'debit_note'
                  ? 'New Debit Note'
                  : 'New Purchase Bill'),
          actions: EditorActions(
            onSave: _save,
            onSaveAndNew: _isEditing || repo == null ? null : _saveAndNew,
            onExit: () => context.pop(),
            saving: _saving,
          ),
          body: _body(repo),
        ),
      ),
    );
  }

  Widget _body(PurchaseRepository? repo) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (repo == null) {
      return const EmptyState(
        icon: Icons.business_center_outlined,
        title: 'No firm selected',
        message: 'Choose or create a firm to start recording purchases.',
      );
    }
    if (_notFound) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Bill not found',
        message: 'This bill may have been deleted from another device.',
      );
    }
    return SafeArea(
      child: EditorShellBody(
        form: _form(),
        summary: _summaryPanel(),
      ),
    );
  }

  /// The sticky summary: charges are edited in the form, so the panel shows
  /// the tax breakdown, grand total, and the inter-state / reverse-charge
  /// state the document will be saved with.
  Widget _summaryPanel() {
    final result = _totals;
    final shipping =
        Money.tryParse(_shippingController.text) ?? Decimal.zero;
    final other = Money.tryParse(_otherChargesController.text) ?? Decimal.zero;
    final grandTotal = result.grandTotal + shipping + other;

    final rows = <EditorTotalsRow>[
      EditorTotalsRow('Subtotal', result.subTotal),
      if (result.itemDiscountTotal > Decimal.zero)
        EditorTotalsRow('Item discount', -result.itemDiscountTotal,
            signed: true),
      if (result.invoiceDiscount > Decimal.zero)
        EditorTotalsRow('Invoice discount', -result.invoiceDiscount,
            signed: true),
      EditorTotalsRow('Taxable value', result.taxableValue, emphasize: true),
      if (_split == GstSplit.intraState) ...[
        if (result.cgstTotal > Decimal.zero)
          EditorTotalsRow('CGST', result.cgstTotal),
        if (result.sgstTotal > Decimal.zero)
          EditorTotalsRow('SGST', result.sgstTotal),
      ] else if (result.igstTotal > Decimal.zero)
        EditorTotalsRow('IGST', result.igstTotal),
      if (result.roundOff.abs() > Decimal.zero)
        EditorTotalsRow('Round off', result.roundOff, signed: true),
      if (shipping > Decimal.zero) EditorTotalsRow('Shipping', shipping),
      if (other > Decimal.zero) EditorTotalsRow('Other charges', other),
    ];

    return EditorTotalsPanel(
      rows: rows,
      total: grandTotal,
      footer: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Round off total'),
        value: _applyRoundOff,
        onChanged: (value) => _changed(() => _applyRoundOff = value),
      ),
    );
  }

  Widget _form() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.isCompact ? double.infinity : 900,
            ),
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _supplierSection(),
                    const SizedBox(height: 12),
                    ..._lines.map(
                      (line) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _LineCard(
                          line: line,
                          items: _items,
                          split: _split,
                          onChanged: _changed,
                          onDeleted: () => _deleteLine(line),
                          onCreateItem: _createItemFromLine,
                        ),
                      ),
                    ),
                    _addLineStrip(),
                    const SizedBox(height: 12),
                    EditorLinkSection(
                      icon: Icons.discount_outlined,
                      title: 'Add Discount & Charges',
                      builder: (_) => _chargesSection(),
                    ),
                    const SizedBox(height: 10),
                    EditorLinkSection(
                      icon: Icons.note_add_rounded,
                      title: 'Add Notes',
                      builder: (_) => _notesSection(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionCard(Widget child) =>
      AtriaCard(padding: const EdgeInsets.all(16), child: child);

  Widget _supplierSection() {
    return _sectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Supplier & dates',
            subtitle: 'Supplier invoice number helps match their bill',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          _supplierField(),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _supplierInvoiceController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Supplier invoice no.',
                hintText: 'Their bill reference',
                prefixIcon: Icon(Icons.receipt_outlined),
              ),
            ),
            second: _dateField(
              label: 'Bill date *',
              icon: Icons.calendar_today_rounded,
              value: _billDate,
              onTap: () => _pickDate(isBillDate: true),
            ),
          ),
          const SizedBox(height: 12),
          _dateField(
            label: 'Due date',
            icon: Icons.event_rounded,
            value: _dueDate,
            placeholder: 'Not set',
            onTap: () => _pickDate(isBillDate: false),
            onClear: _dueDate == null
                ? null
                : () => setState(() => _dueDate = null),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Inter-state purchase'),
            subtitle: Text(_isInterState
                ? 'IGST applies (different states)'
                : 'CGST + SGST apply (same state)'),
            value: _isInterState,
            onChanged: (value) => _changed(() => _isInterState = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reverse charge'),
            subtitle: const Text('Tax is paid by you directly to the authority'),
            value: _reverseCharge,
            onChanged: (value) => _changed(() => _reverseCharge = value),
          ),
        ],
      ),
    );
  }

  Widget _supplierField() {
    return DropdownButtonFormField<String?>(
      initialValue: _selectedSupplierId,
      decoration: const InputDecoration(
        labelText: 'Supplier *',
        prefixIcon: Icon(Icons.storefront_outlined),
      ),
      items: [
        for (final supplier in _suppliers)
          DropdownMenuItem<String?>(
            value: supplier.id,
            child: Text(
              supplier.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        const DropdownMenuItem<String?>(
          value: _kAddNewSupplier,
          child: Row(
            children: [
              Icon(Icons.person_add_rounded, size: 18),
              SizedBox(width: 6),
              Text('Add new supplier'),
            ],
          ),
        ),
      ],
      onChanged: (value) {
        if (value == _kAddNewSupplier) {
          _addNewSupplier();
          return;
        }
        _selectSupplier(value);
      },
      validator: (value) =>
          value == null ? 'Select a supplier, or add a new one' : null,
    );
  }

  Widget _dateField({
    required String label,
    required IconData icon,
    required DateTime? value,
    String placeholder = 'Not set',
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: onClear == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Clear',
                  onPressed: onClear,
                ),
        ),
        child: Text(
          value == null ? placeholder : Formatters.date(value),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: value == null
                    ? Theme.of(context).colorScheme.onSurfaceVariant
                    : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ),
    );
  }

  void _addLine() {
    _changed(() => _lines.add(_LineState(id: IdUtils.newId())));
  }

  void _deleteLine(_LineState line) {
    _changed(() {
      _lines.remove(line);
      line.dispose();
    });
  }

  Widget _chargesSection() {
    return _sectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Charges & adjustments',
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          _FieldRow(
            first: TextFormField(
              controller: _invoiceDiscountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
              decoration: const InputDecoration(
                labelText: 'Invoice discount',
                suffixText: '%',
                prefixIcon: Icon(Icons.discount_outlined),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? null
                  : Validators.gstRate(value),
              onChanged: (_) => _changed(),
            ),
            second: TextFormField(
              controller: _shippingController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
              decoration: const InputDecoration(
                labelText: 'Shipping / freight',
                prefixIcon: Icon(Icons.local_shipping_outlined),
              ),
              validator: _optionalAmount,
              onChanged: (_) => _changed(),
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _otherChargesController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
              decoration: const InputDecoration(
                labelText: 'Other charges',
                prefixIcon: Icon(Icons.add_circle_outline_rounded),
              ),
              validator: _optionalAmount,
              onChanged: (_) => _changed(),
            ),
            second: SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Round off'),
              subtitle: const Text('Round the total to the nearest rupee'),
              value: _applyRoundOff,
              onChanged: (value) => _changed(() => _applyRoundOff = value),
            ),
          ),
        ],
      ),
    );
  }

  String? _optionalAmount(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = Money.tryParse(value);
    if (parsed == null) return 'Enter a valid amount';
    if (parsed < Decimal.zero) return 'Amount cannot be negative';
    return null;
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
              hintText: 'Anything to remember about this purchase',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }

  /// The dashed "＋ Add line" strip, same affordance as the sale editor.
  Widget _addLineStrip() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        onTap: _addLine,
        borderRadius: AppRadius.mdAll,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: AppRadius.mdAll,
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.45),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Add line',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mutable state for one line of the bill.
class _LineState {
  _LineState({required this.id});

  final String id;
  String? itemId;
  String? hsn;
  String unit = 'pcs';
  double gstRate = 0;
  double cessRate = 0;
  TaxMode taxMode = TaxMode.exclusive;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController quantityController =
      TextEditingController(text: '1');
  final TextEditingController rateController = TextEditingController();
  final TextEditingController discountController = TextEditingController();

  Decimal get quantity =>
      Money.tryParse(quantityController.text) ?? Decimal.zero;
  Decimal get rate => Money.tryParse(rateController.text) ?? Decimal.zero;
  Decimal get discountPercent =>
      Money.tryParse(discountController.text) ?? Decimal.zero;

  /// A line only lands in the saved bill when it has both a name and a
  /// positive quantity. [_totals] filters on this too, so the footer the
  /// user reads always describes the bill that will actually be written.
  bool get isValid =>
      quantity > Decimal.zero && nameController.text.trim().isNotEmpty;

  void applyEntity(PurchaseBillItemEntity entity) {
    itemId = entity.itemId;
    nameController.text = entity.name;
    hsn = entity.hsn;
    unit = entity.unit;
    quantityController.text = Formatters.qty(Money.of(entity.quantity));
    rateController.text = Formatters.number(Money.of(entity.rate));
    discountController.text = entity.discountPercent == 0
        ? ''
        : Formatters.number(Money.of(entity.discountPercent));
    gstRate = entity.gstRate;
    cessRate = entity.cessRate;
    taxMode =
        entity.taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
  }

  void applyItem(ItemEntity item, String Function(double) formatAmount) {
    itemId = item.id;
    nameController.text = item.name;
    hsn = item.hsn;
    unit = item.unit;
    rateController.text = formatAmount(item.purchasePrice);
    gstRate = item.gstRate;
    cessRate = item.cessRate;
    taxMode =
        item.taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
  }

  TaxLine toTaxLine() => TaxLine(
        id: id,
        itemId: itemId,
        name: nameController.text.trim().isEmpty
            ? 'Untitled line'
            : nameController.text.trim(),
        hsn: hsn,
        quantity: quantity,
        unit: unit,
        rate: rate,
        discountPercent: discountPercent,
        gstRate: gstRate,
        cessRate: cessRate,
        taxMode: taxMode,
      );

  PurchaseLineDraft toDraft() => PurchaseLineDraft(
        id: id,
        itemId: itemId,
        name: nameController.text.trim(),
        hsn: hsn,
        quantity: quantity,
        unit: unit,
        rate: rate,
        discountPercent: discountPercent,
        gstRate: gstRate,
        cessRate: cessRate,
        taxMode: taxMode,
      );

  void dispose() {
    nameController.dispose();
    quantityController.dispose();
    rateController.dispose();
    discountController.dispose();
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.line,
    required this.items,
    required this.split,
    required this.onChanged,
    required this.onDeleted,
    required this.onCreateItem,
  });

  final _LineState line;
  final List<ItemEntity> items;
  final GstSplit split;
  final VoidCallback onChanged;
  final VoidCallback onDeleted;

  /// The typed name matched nothing in the catalogue — persist it silently
  /// (Vyapar-style) and link the line to it.
  final void Function(_LineState line, String name) onCreateItem;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final totals = GstEngine.computeLine(line.toTaxLine(), split);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: scheme.outline, width: 0.9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _itemField()),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete line',
                onPressed: onDeleted,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: atriaColors(context).negative,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: line.nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              labelText: 'Description *',
              hintText: 'Item or service name',
              isDense: true,
            ),
            validator: (value) => Validators.name(value),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 1,
                child: TextFormField(
                  controller: line.quantityController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [IndianAmountInputFormatter(decimals: 3)],
                  onChanged: (_) => onChanged(),
                  decoration: InputDecoration(
                    labelText: 'Qty',
                    isDense: true,
                    suffixText: Unit.symbolOf(line.unit),
                  ),
                  validator: (value) => Validators.amount(value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: line.rateController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
                  onChanged: (_) => onChanged(),
                  decoration: const InputDecoration(
                    labelText: 'Rate',
                    isDense: true,
                    prefixText: '₹ ',
                  ),
                  validator: (value) => Validators.amount(value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 1,
                child: TextFormField(
                  controller: line.discountController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
                  onChanged: (_) => onChanged(),
                  decoration: const InputDecoration(
                    labelText: 'Disc.',
                    isDense: true,
                    suffixText: '%',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 112,
                child: DropdownButtonFormField<double>(
                  key: ValueKey<double>(line.gstRate),
                  initialValue: line.gstRate,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'GST',
                    isDense: true,
                  ),
                  items: [
                    for (final rate in GstRate.standard)
                      DropdownMenuItem<double>(
                        value: rate.rate,
                        child: Text(rate.label),
                      ),
                  ],
                  onChanged: (value) {
                    line.gstRate = value ?? 0;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Per-line inclusive/exclusive, same as the sale editor.
              if (line.gstRate > 0) ...[
                TaxModeToggle(
                  value: line.taxMode,
                  onChanged: (mode) {
                    line.taxMode = mode;
                    onChanged();
                  },
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Text(
                  'Taxable ${Formatters.money(totals.taxable)}  ·  '
                  'Tax ${Formatters.money(totals.tax)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _itemField() {
    // Type-ahead, Vyapar-style: typing filters the catalogue, and a name
    // matching nothing is saved as a NEW item silently — no dialog, no
    // extra step. (Was a closed dropdown over a snapshot.)
    return ItemTypeAheadField(
      controller: line.nameController,
      items: [
        for (final item in items)
          ItemSuggestion(
            name: item.name,
            salePrice: item.purchasePrice,
            unit: item.unit,
          ),
      ],
      onPickItem: (s) {
        final match = items
            .where((i) => i.name == s.name)
            .cast<ItemEntity?>()
            .firstWhere((i) => i != null, orElse: () => null);
        if (match != null) {
          line.applyItem(match, _formatAmount);
          onChanged();
        }
      },
      onCreateItem: (name) {
        onCreateItem(line, name);
        onChanged();
      },
    );
  }

  /// Groups digits the Indian way and drops ".0" for whole numbers.
  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return Formatters.indianGroup(value.toInt().toString());
    }
    return Formatters.number(Money.of(value));
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
