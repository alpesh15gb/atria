import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/purchase_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/sync/scan_seed.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_utils.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_form_section.dart';
import '../../shared/widgets/atria_grid_cell.dart';
import '../../shared/widgets/atria_line_grid.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/editor_totals.dart';
import '../../shared/widgets/item_type_ahead.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/tax_mode_toggle.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Sentinel dropdown value that opens the party editor instead of selecting a
/// supplier.
const String _kAddNewSupplier = '__add_new_supplier__';

/// Creates or edits a purchase bill. Pass [editId] to edit; leave it null to
/// create.
class PurchaseEditorScreen extends ConsumerStatefulWidget {
  const PurchaseEditorScreen({
    super.key,
    this.editId,
    this.docType = 'bill',
    this.convertFromId,
    this.scanSeed,
  });

  final String? editId;

  /// 'bill', 'purchase_order', or 'debit_note' (purchase return). A debit
  /// note still restores stock — you received the goods back — but does not
  /// add to payables.
  final String docType;

  /// When set (and [editId] is null), a NEW bill is seeded from a scanned
  /// supplier bill: the scan screen reviewed the model's reading and this is
  /// what survived. The supplier is matched by GSTIN/name, created when no
  /// match exists, and everything remains editable exactly like a typed bill.
  final ScannedBillSeed? scanSeed;

  /// When set (and [editId] is null), a NEW document of [docType] is created
  /// seeded from that purchase order: party, lines and adjustments are
  /// copied, the number is fresh, and after save the source is marked
  /// `converted` so it cannot be converted twice.
  final String? convertFromId;

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
  /// TDS percentage deducted at source on this bill. Zero for none.
  final _tdsRateController = TextEditingController(text: '0');
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
    _tdsRateController.dispose();
    _notesController.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  /// Id of the purchase order this document was converted from, if any.
  /// Cleared on successful save after the source is marked converted.
  String? _convertSourceId;

  /// Applies the scan screen's reviewed reading to the empty form. Runs in
  /// the same post-first-frame slot as the conversion flow, so the supplier
  /// lookup sees the loaded list.
  Future<void> _applyScanSeed(ScannedBillSeed seed) async {
    final firm = ref.read(activeFirmProvider).valueOrNull;

    _supplierInvoiceController.text = seed.invoiceNumber ?? '';
    _shippingController.text =
        seed.shippingCharge == 0 ? '' : _formatAmount(seed.shippingCharge);
    _otherChargesController.text =
        seed.otherCharges == 0 ? '' : _formatAmount(seed.otherCharges);
    if (seed.billDate != null) _billDate = seed.billDate!;
    if (seed.dueDate != null) _dueDate = seed.dueDate;

    // Supplier: match an existing one by GSTIN first (the reliable key), then
    // by case-insensitive name; create one when nothing matches so the bill
    // links properly instead of floating on a free-text name.
    if (seed.supplierName != null || seed.supplierGstin != null) {
      final match = seed.matchSupplier(_suppliers);
      if (match != null) {
        _selectSupplier(match.id);
      } else if (seed.supplierName != null) {
        try {
          final partyRepo = ref.read(partyRepositoryProvider);
          if (partyRepo != null) {
            final gstin = seed.supplierGstin;
            final created = await partyRepo.create(
              name: seed.supplierName!,
              type: 'supplier',
              gstin: gstin,
              gstType:
                  (gstin == null || gstin.isEmpty) ? 'unregistered' : 'registered',
              phone: seed.supplierPhone,
              addressLine1: seed.supplierAddress,
              stateCode: seed.placeOfSupply,
            );
            if (!mounted) return;
            final suppliers = await partyRepo.all(type: 'supplier', limit: 1000);
            if (!mounted) return;
            setState(() => _suppliers = suppliers);
            _selectSupplier(created.id);
          }
        } on Object {
          // A supplier that failed to create must not block the scanned
          // lines: the bill can still be saved and the supplier fixed after.
        }
      }
    }

    // Fall back to deriving the inter-state split from the scanned state
    // code when no supplier was resolved.
    if (_selectedSupplierId == null &&
        seed.placeOfSupply != null &&
        firm != null) {
      _isInterState = resolveGstSplit(
            supplierState: seed.placeOfSupply,
            buyerState: firm.stateCode,
          ) ==
          GstSplit.interState;
    }

    for (final scanned in seed.lines) {
      final line = _LineState(id: IdUtils.newId());
      line.nameController.text = scanned.name;
      if (scanned.hsn != null && scanned.hsn!.isNotEmpty) {
        line.hsnController.text = scanned.hsn!;
      }
      line.unit = scanned.unit.isEmpty ? 'pcs' : scanned.unit;
      line.quantityController.text = Formatters.qty(Money.of(scanned.quantity));
      line.rateController.text = _formatAmount(scanned.rate);
      if (scanned.discountPercent != 0) {
        line.discountController.text =
            _formatAmount(scanned.discountPercent);
      }
      line.gstRate = scanned.gstRate;
      line.cessRate = scanned.cessRate;
      _lines.add(line);
    }
    if (seed.lines.isEmpty) {
      _lines.add(_LineState(id: IdUtils.newId()));
    }
    if (mounted) setState(() {});
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
      // A binned bill must not open for editing: the save path's upsert
      // would clear its isDeleted flag and resurrect it (stock re-posted,
      // payables re-counted). Same treatment as a missing row.
      if (bill != null && bill.isDeleted) bill = null;
      billItems = bill == null
          ? const []
          : await purchaseRepo.itemsFor(bill.id);
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

    // Scan seed: apply the reviewed reading after the first frame, the same
    // slot the conversion flow uses, so supplier lookups see loaded lists.
    if (widget.scanSeed != null && mounted && !_isEditing) {
      await _applyScanSeed(widget.scanSeed!);
    }

    // Conversion: seed the new document from a purchase order. Runs after
    // the first frame so _selectSupplier's lookups see the loaded lists.
    if (widget.convertFromId != null && purchaseRepo != null && mounted) {
      final source = await purchaseRepo.getById(widget.convertFromId!);
      if (source != null && mounted && !_isEditing) {
        _prefill(source, await purchaseRepo.itemsFor(source.id));
        _billDate = DateTime.now();
        _dueDate = null;
        _supplierInvoiceController.clear();
        _convertSourceId = source.id;
        if (mounted) setState(() {});
      }
    }

    // Prefilling a bill being edited is not an unsaved change.
    _dirty = false;
  }

  void _prefill(PurchaseBillEntity bill, List<PurchaseBillItemEntity> items) {
    _supplierInvoiceController.text = bill.supplierInvoiceNumber ?? '';
    _invoiceDiscountController.text = _formatAmount(
      bill.invoiceDiscountPercent,
    );
    _shippingController.text = _formatAmount(bill.shippingCharge);
    _otherChargesController.text = _formatAmount(bill.otherCharges);
    _tdsRateController.text = Formatters.rateInput(bill.tdsRate);
    _notesController.text = bill.notes ?? '';
    _billDate = bill.billDate;
    _dueDate = bill.dueDate;
    _selectedSupplierId = bill.partyId;
    _isInterState = bill.isInterState;
    _reverseCharge = bill.reverseCharge;
    // The stored round-off figure is the only record of the flag the bill
    // was saved with — hardcoding true here silently re-rounded bills that
    // were saved with round-off off (the sale editor already recovers it
    // this way).
    _applyRoundOff = bill.roundOff.abs() > 0.000001;

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
    final createdId = await context.push<String>('/parties/new?type=supplier');
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
      _isInterState =
          resolveGstSplit(
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
    // A due date before the bill date is not a credit period, it is a bug:
    // the bill would land in payables ageing as instantly overdue. Legacy
    // rows can still carry one, so clamp the initial date instead of letting
    // showDatePicker assert.
    final firstDate = isBillDate ? DateTime(2000) : _billDate;
    var initialDate = isBillDate
        ? _billDate
        : (_dueDate ?? _billDate.add(const Duration(days: 30)));
    if (initialDate.isBefore(firstDate)) initialDate = firstDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate,
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

    // The bill may have been deleted (or never found) after this editor
    // opened. Both `_existing!` reads below would crash on the not-found
    // path — reachable because the save shortcut stays live over the
    // not-found empty state — and the upsert would resurrect a binned one.
    if (_isEditing) {
      final live = _existing == null
          ? null
          : await repo.getById(_existing!.id);
      if (live == null || live.isDeleted) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('This bill no longer exists — it may have been '
                'deleted. Nothing was saved.'),
          ),
        );
        return false;
      }
    }

    final lines = _lines
        .where((line) => line.isValid)
        .map((line) => line.toDraft())
        .toList();
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
              switch (widget.docType) {
                'debit_note' => DocSequence.debitNote,
                'purchase_order' => DocSequence.purchaseOrder,
                _ => DocSequence.purchase,
              },
              date: _billDate,
            );
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
        tdsRate: Money.tryParse(_tdsRateController.text) ?? Decimal.zero,
        applyRoundOff: _applyRoundOff,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        sequence: _isEditing ? _existing!.sequence : 0,
      );

      await repo.save(
        draft,
        // An order is a promise, not goods received — the bill raised
        // against it does the stock work (mirrors the sales-side rule).
        affectStock: widget.docType != 'purchase_order',
      );
      // A converted purchase order is flagged so it shows its badge in the
      // list and cannot be converted a second time.
      final sourceId = _convertSourceId;
      if (sourceId != null) {
        await repo.markConverted(sourceId);
        _convertSourceId = null;
      }
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
      _tdsRateController.text = '0';
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
          hint:
              'Tab → next cell   ·   Enter → next line   ·   '
              'Ctrl+S → save & close',
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
      // One column, exactly like the sale editor: the totals sit under the
      // last line instead of in a side rail, so the whole bill — supplier,
      // lines, tax — is read top-to-bottom in a single sweep, and the sheet
      // takes the width of the window rather than a fixed strip of it.
      child: EditorShellBody(
        form: Form(
          key: _formKey,
          child: AtriaEditorForm(
            header: _supplierSection(),
            headerTrailing: _metaSection(),
            lines: _lineGrid(),
            totals: _totalsSection(),
            sections: [
              EditorLinkSection(
                icon: Icons.percent_rounded,
                title: 'Tax treatment',
                initiallyOpen: true,
                builder: (_) => _taxSection(),
              ),
              EditorLinkSection(
                icon: Icons.discount_outlined,
                title: 'Discount, charges and round off',
                builder: (_) => _chargesSection(),
              ),
              EditorLinkSection(
                icon: Icons.note_add_rounded,
                title: 'Add Notes',
                builder: (_) => _notesSection(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The line sheet's columns — kept in step with the sale editor so a bill is
  /// entered with the same eye movement as an invoice.
  // Byte-for-byte the invoice's column set and shares — a bill and an
  // invoice put the same figures in the same places.
  static const List<AtriaLineColumn> _lineColumns = [
    AtriaLineColumn('Item / Description', flex: 6),
    AtriaLineColumn('HSN/SAC', flex: 2),
    AtriaLineColumn('Qty', flex: 3, numeric: true),
    AtriaLineColumn('Rate', flex: 3, numeric: true),
    AtriaLineColumn('Disc %', flex: 2, numeric: true),
    AtriaLineColumn('GST', flex: 3),
    AtriaLineColumn('Amount', flex: 3, numeric: true),
  ];

  Widget _lineGrid() {
    return AtriaLineGrid(
      columns: _lineColumns,
      addLabel: 'Add lines',
      onAddRow: () => _addLine(focus: true),
      rows: [
        for (var i = 0; i < _lines.length; i++)
          AtriaLineGridRow(
            cells: _lineCells(i),
            onRemove: _lines.length == 1 ? null : () => _deleteLine(_lines[i]),
          ),
      ],
    );
  }

  List<Widget> _lineCells(int index) {
    final line = _lines[index];
    final isLastRow = index == _lines.length - 1;
    final scheme = Theme.of(context).colorScheme;

    void advance() {
      if (isLastRow) {
        _addLine(focus: true);
      } else {
        FocusScope.of(context).nextFocus();
      }
    }

    final lineTotals = GstEngine.computeLine(line.toTaxLine(), _split);

    return [
      ItemTypeAheadField(
        key: ValueKey('${line.id}-item'),
        controller: line.nameController,
        focusNode: line.nameFocus,
        label: 'Item',
        hintText: 'Item or service',
        validator: (value) =>
            (value == null || value.trim().isEmpty) ? 'Required' : null,
        decoration: (context) =>
            AtriaGridCell.decorationFor(context, hint: 'Item or service'),
        items: [
          for (final item in _items)
            ItemSuggestion(
              name: item.name,
              salePrice: item.purchasePrice,
              unit: item.unit,
            ),
        ],
        onPickItem: (s) {
          final match = _items
              .where((i) => i.name == s.name)
              .cast<ItemEntity?>()
              .firstWhere((i) => i != null, orElse: () => null);
          if (match != null) {
            line.applyItem(match, _formatAmount);
            _changed();
          }
        },
        onCreateItem: (name) => _createItemFromLine(line, name),
      ),
      AtriaGridInput(
        key: ValueKey('${line.id}-hsn'),
        controller: line.hsnController,
        hint: 'HSN',
        textCapitalization: TextCapitalization.characters,
        onChanged: (_) => _changed(),
      ),
      Row(
        key: ValueKey('${line.id}-qty'),
        children: [
          Expanded(
            child: AtriaGridInput(
              controller: line.quantityController,
              numeric: true,
              textAlign: TextAlign.right,
              onChanged: (_) => _changed(),
              onSubmitted: advance,
              validator: (value) {
                final qty = Money.tryParse(value ?? '');
                if (qty == null || qty <= Decimal.zero) {
                  return 'Must be greater than 0';
                }
                return null;
              },
            ),
          ),
          ConstrainedBox(
            // Wider when boxed: the stacked card gives the unit its own box
            // inside the Qty cell, and 50px leaves no room for it.
            constraints: BoxConstraints(
              maxWidth: AtriaGridCellMode.boxedOf(context) ? 78 : 50,
            ),
            child: AtriaUnitPicker(
              value: line.unit,
              onChanged: (unit) => _changed(() => line.unit = unit),
            ),
          ),
        ],
      ),
      AtriaGridInput(
        key: ValueKey('${line.id}-rate'),
        controller: line.rateController,
        numeric: true,
        textAlign: TextAlign.right,
        prefix: '₹ ',
        onChanged: (_) => _changed(),
        onSubmitted: advance,
      ),
      AtriaGridInput(
        key: ValueKey('${line.id}-disc'),
        controller: line.discountController,
        numeric: true,
        textAlign: TextAlign.right,
        onChanged: (_) => _changed(),
        onSubmitted: advance,
      ),
      Row(
        key: ValueKey('${line.id}-gst'),
        children: [
          Expanded(
            child: AtriaGstRatePicker(
              value: line.gstRate,
              onChanged: (rate) => _changed(() => line.gstRate = rate),
            ),
          ),
          if (line.gstRate > 0)
            AtriaTaxModePill(
              value: line.taxMode,
              onChanged: (mode) => _changed(() => line.taxMode = mode),
            ),
        ],
      ),
      Padding(
        key: ValueKey('${line.id}-amount'),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        // Bare in the sheet, hairline-boxed in the stacked card, where every
        // other cell is a box too.
        child: Container(
          decoration: AtriaGridCell.boxDecorationOf(context),
          padding: EdgeInsets.symmetric(
            horizontal: AtriaGridCellMode.boxedOf(context) ? 10 : 0,
            vertical: AtriaGridCellMode.boxedOf(context) ? 12 : 0,
          ),
          alignment: AtriaGridCellMode.boxedOf(context)
              ? Alignment.centerRight
              : null,
          child: MoneyText(
            lineTotals.total,
            colorize: false,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ),
      ),
    ];
  }

  /// The same breakdown every document shows, so a purchase bill and an
  /// invoice can never disagree about what a total means.
  Widget _totalsSection() {
    final result = _totals;
    final shipping = Money.tryParse(_shippingController.text) ?? Decimal.zero;
    final other = Money.tryParse(_otherChargesController.text) ?? Decimal.zero;
    final tdsRate = Money.tryParse(_tdsRateController.text) ?? Decimal.zero;
    // Deducted, not charged: TDS reduces what the supplier is paid, so it comes
    // off the total the same way a discount does.
    final tds = GstEngine.settlementTax(
      taxableValue: result.taxableValue,
      rate: tdsRate,
    );
    return AtriaTotalsBlock(
      totals: result,
      extraCharges: shipping + other - tds,
      extraRows: [
        if (shipping > Decimal.zero) EditorTotalsRow('Shipping', shipping),
        if (other > Decimal.zero) EditorTotalsRow('Other charges', other),
        if (tds > Decimal.zero)
          EditorTotalsRow(
            'TDS ${Formatters.percent(tdsRate.toDouble())}',
            -tds,
            signed: true,
          ),
      ],
      isInterState: _split == GstSplit.interState,
      footer: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: const Text('Round off total'),
        value: _applyRoundOff,
        onChanged: (value) => _changed(() => _applyRoundOff = value),
      ),
    );
  }

  Widget _supplierSection() {
    final supplier = _supplierWithId(_selectedSupplierId);
    return AtriaFormSection(
      icon: Icons.storefront_outlined,
      title: 'Supplier',
      trailing: TextButton.icon(
        onPressed: _addNewSupplier,
        icon: const Icon(Icons.person_add_alt_outlined, size: 18),
        label: const Text('New'),
      ),
      children: [
        _supplierField(),
        if (supplier != null) _supplierInfo(supplier),
      ],
    );
  }

  /// Who this bill is from, at a glance — the facts that decide the tax split,
  /// without opening the party record.
  Widget _supplierInfo(PartyEntity supplier) {
    final scheme = Theme.of(context).colorScheme;
    final details = [
      if ((supplier.gstin ?? '').isNotEmpty) supplier.gstin!.toUpperCase(),
      if ((supplier.phone ?? '').isNotEmpty) supplier.phone!,
      if (supplier.stateCode != null)
        'Place of supply: '
            '${IndianStates.byCode(supplier.stateCode)?.name ?? supplier.stateCode}',
    ];
    if (details.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          details.join('  •  '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }

  Widget _metaSection() {
    return AtriaFormSection(
      icon: Icons.event_outlined,
      title: 'Dates & reference',
      children: [
        AtriaFormFieldRow(
          minWidth: 420,
          first: _dateField(
            label: 'Bill date *',
            icon: Icons.calendar_today_rounded,
            value: _billDate,
            onTap: () => _pickDate(isBillDate: true),
          ),
          second: _dateField(
            label: 'Due date',
            icon: Icons.event_rounded,
            value: _dueDate,
            placeholder: 'Not set',
            onTap: () => _pickDate(isBillDate: false),
            onClear: _dueDate == null
                ? null
                : () => setState(() => _dueDate = null),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _supplierInvoiceController,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Supplier invoice no.',
            hintText: 'Their bill reference',
            prefixIcon: AtriaFieldIcon(Icons.receipt_outlined),
          ),
        ),
      ],
    );
  }

  Widget _taxSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Inter-state purchase'),
          subtitle: Text(
            _isInterState
                ? 'IGST applies (different states)'
                : 'CGST + SGST apply (same state)',
          ),
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
    );
  }

  Widget _supplierField() {
    return DropdownButtonFormField<String?>(
      iconSize: AppIconSize.md,
      initialValue: _selectedSupplierId,
      // isExpanded: a DropdownButton sizes to its WIDEST item, so an
      // unexpanded one overflows the field on a phone.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Supplier *',
        prefixIcon: AtriaFieldIcon(Icons.storefront_outlined),
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
              Flexible(
                child: Text(
                  'Add new supplier',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
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
          prefixIcon: AtriaFieldIcon(icon),
          suffixIcon: onClear == null
              ? null
              : IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: AppIconSize.md,
                  ),
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

  /// Appends a line; [focus] puts the caret in the new line's item cell —
  /// Enter at the end of the sheet.
  void _addLine({bool focus = false}) {
    final line = _LineState(id: IdUtils.newId());
    _changed(() => _lines.add(line));
    if (!focus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.nameFocus.requestFocus();
    });
  }

  void _deleteLine(_LineState line) {
    _changed(() {
      _lines.remove(line);
      line.dispose();
    });
  }

  Widget _chargesSection() {
    // No card of its own: the link section above it is already the surface.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AtriaFormFieldRow(
          first: TextFormField(
            controller: _invoiceDiscountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            decoration: const InputDecoration(
              labelText: 'Invoice discount',
              suffixText: '%',
              prefixIcon: AtriaFieldIcon(Icons.discount_outlined),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? null
                : Validators.gstRate(value),
            onChanged: (_) => _changed(),
          ),
          second: TextFormField(
            controller: _shippingController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            decoration: const InputDecoration(
              labelText: 'Shipping / freight',
              prefixIcon: AtriaFieldIcon(Icons.local_shipping_outlined),
            ),
            validator: _optionalAmount,
            onChanged: (_) => _changed(),
          ),
        ),
        const SizedBox(height: 12),
        AtriaFormFieldRow(
          first: TextFormField(
            controller: _otherChargesController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            decoration: const InputDecoration(
              labelText: 'Other charges',
              prefixIcon: AtriaFieldIcon(Icons.add_circle_outline_rounded),
            ),
            validator: _optionalAmount,
            onChanged: (_) => _changed(),
          ),
          second: TextFormField(
            controller: _tdsRateController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
            decoration: const InputDecoration(
              labelText: 'TDS %',
              helperText: '0 for none',
              prefixIcon: AtriaFieldIcon(Icons.percent_rounded),
            ),
            // Deducted on the taxable value, which is what a 194Q deduction is
            // taken on (the GST the buyer also pays is not the supplier's
            // income). The row in the totals panel shows the amount.
            onChanged: (_) => _changed(),
          ),
        ),
      ],
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
    return TextFormField(
      controller: _notesController,
      textCapitalization: TextCapitalization.sentences,
      maxLines: 3,
      minLines: 2,
      decoration: const InputDecoration(
        labelText: 'Notes',
        hintText: 'Anything to remember about this purchase',
        alignLabelWithHint: true,
      ),
    );
  }
}

/// Mutable state for one line of the bill.
class _LineState {
  _LineState({required this.id});

  final String id;

  /// Focus target for the line's item cell — Enter at the end of the sheet
  /// lands here.
  final FocusNode nameFocus = FocusNode();

  String? itemId;
  String unit = 'pcs';
  double gstRate = 0;
  double cessRate = 0;
  TaxMode taxMode = TaxMode.exclusive;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController hsnController = TextEditingController();
  final TextEditingController quantityController = TextEditingController(
    text: '1',
  );
  final TextEditingController rateController = TextEditingController();
  final TextEditingController discountController = TextEditingController();

  String get hsn => hsnController.text.trim().toUpperCase();

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
    hsnController.text = entity.hsn ?? '';
    unit = entity.unit;
    quantityController.text = Formatters.qty(Money.of(entity.quantity));
    rateController.text = Formatters.number(Money.of(entity.rate));
    discountController.text = entity.discountPercent == 0
        ? ''
        : Formatters.number(Money.of(entity.discountPercent));
    gstRate = entity.gstRate;
    cessRate = entity.cessRate;
    taxMode = entity.taxMode == 'inclusive'
        ? TaxMode.inclusive
        : TaxMode.exclusive;
  }

  void applyItem(ItemEntity item, String Function(double) formatAmount) {
    itemId = item.id;
    nameController.text = item.name;
    hsnController.text = item.hsn ?? '';
    unit = item.unit;
    rateController.text = formatAmount(item.purchasePrice);
    gstRate = item.gstRate;
    cessRate = item.cessRate;
    taxMode = item.taxMode == 'inclusive'
        ? TaxMode.inclusive
        : TaxMode.exclusive;
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
    nameFocus.dispose();
    nameController.dispose();
    hsnController.dispose();
    quantityController.dispose();
    rateController.dispose();
    discountController.dispose();
  }
}
