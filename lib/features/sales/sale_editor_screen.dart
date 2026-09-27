import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/constants/gst.dart';
import '../../core/constants/indian_states.dart';
import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/sales_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_utils.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/editor_totals.dart';
import '../../shared/widgets/item_type_ahead.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/tax_mode_toggle.dart';
import '../../shared/widgets/unsaved_guard.dart';

class SaleEditorScreen extends ConsumerStatefulWidget {
  const SaleEditorScreen({
    super.key,
    required this.docType,
    this.editId,
    this.convertFromId,
    this.presetPartyId,
  });

  final String docType;
  final String? editId;

  /// When set (and [editId] is null), a NEW document of [docType] is created
  /// seeded from that quotation/sales-order: party, lines and adjustments are
  /// copied, the number is fresh, and after save the source is marked
  /// `converted` so it cannot be converted twice.
  final String? convertFromId;

  /// Preselects the customer once the party list loads (`/sales/new?party=`).
  final String? presetPartyId;

  @override
  ConsumerState<SaleEditorScreen> createState() => _SaleEditorScreenState();
}

class _SaleEditorScreenState extends ConsumerState<SaleEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  bool _loading = false;
  bool _isEditing = false;

  /// The stored document's status, kept so an edit never re-activates a
  /// cancelled or converted document (was hardcoded to 'confirmed').
  String? _existingStatus;

  // Document fields
  PartyEntity? _party;
  late DateTime _invoiceDate;
  DateTime? _dueDate;
  final _notesController = TextEditingController();

  // Invoice-level adjustments
  final _discountPercentController = TextEditingController(text: '0');
  final _discountAmountController = TextEditingController(text: '0');
  final _shippingController = TextEditingController(text: '0');
  bool _applyRoundOff = true;

  /// One-tap settlement: records a payment covering the invoice as soon as
  /// it is saved, so a cash sale shows Paid instead of Unpaid.
  bool _markPaid = false;

  // Lines
  final List<_LineController> _lines = [];

  // Catalog lookups
  List<ItemEntity> _items = const [];
  List<PartyEntity> _parties = const [];

  /// Live item feed so the line picker sees items saved after this editor
  /// opened. Nulled on dispose; [_bootstrap] owns the subscription.
  StreamSubscription<List<ItemEntity>>? _itemsSub;

  bool _dirty = false;
  void _markDirty() => _dirty = true;

  /// Party's current receivable (live documents only) and their credit
  /// limit — refreshed on party selection. Drives the advisory banner in
  /// the totals panel: the sale is never blocked, like Vyapar.
  double _partyOutstanding = 0;
  double? _partyCreditLimit;

  String? get _creditLimitMessage {
    final limit = _partyCreditLimit;
    if (limit == null || limit <= 0) return null;
    final grandTotal = _totals.grandTotal +
        (Money.tryParse(_shippingController.text) ?? Decimal.zero);
    final projected =
        _partyOutstanding + grandTotal.toDouble();
    if (projected <= limit) return null;
    String fmt(double v) => Formatters.money(
        Decimal.tryParse(v.toStringAsFixed(2)) ?? Decimal.zero);
    return 'Credit limit exceeded: ${fmt(_partyOutstanding)} '
        'outstanding + this ${fmt(grandTotal.toDouble())} crosses the '
        '${fmt(limit)} limit. You can still save.';
  }

  Future<void> _loadPartyCreditInfo() async {
    final party = _party;
    final repo = ref.read(partyRepositoryProvider);
    if (party == null || repo == null || party.id.isEmpty) {
      if (mounted) {
        setState(() {
          _partyOutstanding = 0;
          _partyCreditLimit = party?.creditLimit;
        });
      }
      return;
    }
    final outstanding = await repo.outstandingFor(party.id);
    if (!mounted) return;
    setState(() {
      _partyOutstanding = outstanding;
      _partyCreditLimit = party.creditLimit;
    });
  }

  /// Id of the quotation / sales order this document was converted from, if
  /// any. Cleared on successful save after the source is marked converted.
  String? _convertSourceId;

  bool get _isQuotation => widget.docType == 'quotation';
  bool get _isOrder => widget.docType == 'sales_order';
  bool get _isDeliveryNote => widget.docType == 'delivery_note';

  /// Stock/ledger impact: invoices and credit notes move stock (a credit
  /// note adds the goods back — without this, returned goods vanish from the
  /// stock ledger while the paper trail says they came back). Quotations,
  /// sales orders and delivery notes are paper-only; a delivery note converts
  /// into an invoice that then does the stock work.
  bool get _affectsStockAndBalances =>
      !_isQuotation && !_isOrder && !_isDeliveryNote;

  String get _docNoun => switch (widget.docType) {
        'quotation' => 'Quotation',
        'sales_order' => 'Sales Order',
        'delivery_note' => 'Delivery Note',
        'credit_note' => 'Credit Note',
        _ => 'Invoice',
      };

  String get _title =>
      '${_isEditing ? 'Edit' : 'New'} $_docNoun';

  @override
  void initState() {
    super.initState();
    _invoiceDate = DateTime.now();
    _dueDate = DateTime.now().add(const Duration(days: 15));
    for (final controller in [
      _notesController,
      _discountPercentController,
      _discountAmountController,
      _shippingController,
    ]) {
      controller.addListener(_markDirty);
    }
    _addLine();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    unawaited(_itemsSub?.cancel());
    _notesController.dispose();
    _discountPercentController.dispose();
    _discountAmountController.dispose();
    _shippingController.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _loading = true);
    final itemRepo = ref.read(itemRepositoryProvider);
    final partyRepo = ref.read(partyRepositoryProvider);
    if (itemRepo != null) {
      _items = await itemRepo.all(limit: 2000);
      // Keep the line-item picker live: an item saved after this editor
      // opened (e.g. added from the Items tab, or created during the same
      // session) must appear without reopening the editor. Pushed into
      // existing line controllers too, so open lines see it immediately.
      _itemsSub = itemRepo.watchAll().listen((items) {
        if (!mounted) return;
        setState(() => _items = items);
        for (final line in _lines) {
          line.items = items;
        }
      });
    }
    if (partyRepo != null) {
      _parties = await partyRepo.all(type: 'customer', limit: 2000);
      if (_parties.isEmpty) {
        _parties = await partyRepo.all(limit: 2000);
      }
      // ?party=<id>: the Parties pane's "New invoice" affordance lands here
      // with the customer already chosen.
      final preset = widget.presetPartyId;
      if (_party == null && preset != null) {
        _party = _parties
            .where((p) => p.id == preset)
            .cast<PartyEntity?>()
            .firstWhere((p) => p != null, orElse: () => null);
      }
    }

    if (widget.convertFromId != null) {
      // Conversion: build the new document from a quotation / sales order.
      // Stays in "new" mode — fresh number, docType from the route — and the
      // source is marked converted only after a successful save.
      final sales = ref.read(salesRepositoryProvider);
      final doc = await sales?.getById(widget.convertFromId!);
      if (doc != null && mounted) {
        _invoiceDate = DateTime.now();
        _dueDate = DateTime.now().add(const Duration(days: 15));
        _notesController.text = doc.notes ?? '';
        _discountPercentController.text =
            doc.invoiceDiscountPercent.toStringAsFixed(2);
        _discountAmountController.text =
            doc.invoiceDiscountAmount.toStringAsFixed(2);
        _shippingController.text = doc.shippingCharge.toStringAsFixed(2);
        _applyRoundOff = doc.roundOff.abs() > 0.000001;
        _party = _parties
            .where((p) => p.id == doc.partyId)
            .cast<PartyEntity?>()
            .firstWhere((p) => p?.id == doc.partyId, orElse: () => null);
        if (_party == null && doc.partyName != null) {
          final now = DateTime.now();
          _party = PartyEntity(
            id: doc.partyId ?? '',
            firmId: doc.firmId,
            name: doc.partyName!,
            type: 'customer',
            gstin: doc.partyGstin,
            gstType: doc.partyGstType ?? 'unregistered',
            phone: doc.partyPhone,
            openingBalance: 0,
            openingBalanceType: 'dr',
            isDeleted: false,
            createdAt: now,
            updatedAt: now,
          );
        }
        final sourceLines = await sales!.itemsFor(doc.id);
        _lines.clear();
        for (final l in sourceLines) {
          _lines.add(_LineController.fromEntity(l, _items,
              onChanged: _onLineChanged));
        }
        if (_lines.isEmpty) _addLine();
        _convertSourceId = doc.id;
        _recalcPartyDerived();
      }
    } else if (widget.editId != null) {
      final sales = ref.read(salesRepositoryProvider);
      final doc = await sales?.getById(widget.editId!);
      if (doc != null && mounted) {
        _isEditing = true;
        _existingStatus = doc.status;
        _invoiceDate = doc.invoiceDate;
        _dueDate = doc.dueDate;
        _notesController.text = doc.notes ?? '';
        _discountPercentController.text =
            doc.invoiceDiscountPercent.toStringAsFixed(2);
        _discountAmountController.text =
            doc.invoiceDiscountAmount.toStringAsFixed(2);
        _shippingController.text = doc.shippingCharge.toStringAsFixed(2);
        _applyRoundOff = doc.roundOff.abs() > 0.000001;
        _party = _parties
            .where((p) => p.id == doc.partyId)
            .cast<PartyEntity?>()
            .firstWhere((p) => p?.id == doc.partyId, orElse: () => null);
        if (_party == null && doc.partyName != null) {
          final now = DateTime.now();
          _party = PartyEntity(
            id: doc.partyId ?? '',
            firmId: doc.firmId,
            name: doc.partyName!,
            type: 'customer',
            gstin: doc.partyGstin,
            gstType: doc.partyGstType ?? 'unregistered',
            phone: doc.partyPhone,
            openingBalance: 0,
            openingBalanceType: 'dr',
            isDeleted: false,
            createdAt: now,
            updatedAt: now,
          );
        }
        final savedLines = await sales!.itemsFor(doc.id);
        _lines.clear();
        for (final l in savedLines) {
          _lines.add(_LineController.fromEntity(l, _items,
              onChanged: _onLineChanged));
        }
        if (_lines.isEmpty) _addLine();
        _recalcPartyDerived();
      }
    } else {
      // Pre-select the last-used customer for convenience.
      if (_parties.isNotEmpty) {
        _selectParty(_parties.first);
      }
    }
    // Neither prefilling an existing document nor pre-selecting the usual
    // customer counts as an edit the user would lose by going back.
    _dirty = false;
    if (mounted) setState(() => _loading = false);
  }

  void _onLineChanged() {
    _markDirty();
    _recalc();
  }

  void _addLine() {
    setState(() {
      _lines.add(_LineController(items: _items, onChanged: _onLineChanged));
    });
    _recalc();
  }

  void _removeLine(int index) {
    if (_lines.length == 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('At least one line is required.')),
      );
      return;
    }
    setState(() {
      _lines[index].dispose();
      _lines.removeAt(index);
      _dirty = true;
    });
    _recalc();
  }

  void _selectParty(PartyEntity? party) {
    setState(() {
      _party = party;
      _dirty = true;
    });
    _recalcPartyDerived();
    _loadPartyCreditInfo();
  }

  void _recalcPartyDerived() {
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (_party == null || firm == null) return;
    setState(() {
      for (final line in _lines) {
        if (line.itemId != null) {
          final item = _items.where((i) => i.id == line.itemId).firstOrNull;
          if (item != null) {
            line.gstRate = item.gstRate;
            line.taxMode = item.taxMode == 'inclusive'
                ? TaxMode.inclusive
                : TaxMode.exclusive;
          }
        }
      }
    });
    _recalc();
  }

  void _recalc() {
    if (!mounted) return;
    setState(() {});
  }

  bool get _isInterState {
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (_party == null || firm == null || _party!.stateCode == null) {
      return false;
    }
    if ((firm.gstin ?? '').isEmpty || (_party!.gstin ?? '').isEmpty) {
      return false;
    }
    return _party!.stateCode != firm.stateCode;
  }

  /// Vyapar flow: a typed item name that matches nothing is SAVED as a new
  /// item without asking anything, and the line links to it. Rate/type
  /// defaults come from the line the user typed into (0-rate items read as
  /// services when stock is off — matching the item editor's defaults).
  Future<void> _createItemFromLine(_LineController line, String name) async {
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null) return;
    try {
      final item = await repo.create(
        name: name,
        unit: line.unit,
        salePrice: line.rateDecimal.toDouble(),
        gstRate: line.gstRate,
        taxMode: line.taxMode == TaxMode.inclusive ? 'inclusive' : 'exclusive',
        isService: false,
        stockType: 'untracked',
      );
      if (!mounted) return;
      line.applyItem(item);
      setState(() {});
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save item "$name": $error')),
      );
    }
  }

  GstResult get _totals {
    final lines = _lines
        .where((l) => l.isValid)
        .map((l) => TaxLine(
              id: l.id,
              itemId: l.itemId,
              name: l.name.isEmpty ? 'Item' : l.name,
              hsn: l.hsn,
              quantity: l.qtyDecimal,
              unit: l.unit,
              rate: l.rateDecimal,
              discountPercent: l.discountPercentDecimal,
              gstRate: l.gstRate,
              cessRate: l.cessRate,
              taxMode: l.taxMode,
            ))
        .toList();
    final discountPercent =
        Money.tryParse(_discountPercentController.text) ?? Decimal.zero;
    final discountAmount =
        Money.tryParse(_discountAmountController.text) ?? Decimal.zero;
    return GstEngine.computeDocument(
      lines: lines,
      split: _isInterState ? GstSplit.interState : GstSplit.intraState,
      invoiceDiscountPercent: discountPercent,
      invoiceDiscountAmount: discountAmount,
      applyRoundOff: _applyRoundOff,
    );
  }

  /// Shared body of Save and Save & New. Returns true when the document was
  /// written (and the snackbar shown); false leaves the form exactly as the
  /// user left it.
  Future<bool> _saveCore() async {
    if (_loading) return false; // double-submit guard.
    if (!(_formKey.currentState?.validate() ?? false)) return false;
    if (_party == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a customer.')),
      );
      return false;
    }
    final validLines = _lines.where((l) => l.isValid).toList();
    if (validLines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one item with a quantity.')),
      );
      return false;
    }

    setState(() => _loading = true);
    try {
      final sales = ref.read(salesRepositoryProvider);
      final firm = ref.read(activeFirmProvider).valueOrNull;
      if (sales == null || firm == null) return false;

      String number;
      int sequence;
      if (_isEditing) {
        final existing = await sales.getById(widget.editId!);
        number = existing?.number ?? 'INV-1';
        sequence = existing?.sequence ?? 0;
      } else {
        final docSequence = switch (widget.docType) {
          'quotation' => DocSequence.quotation,
          'sales_order' => DocSequence.salesOrder,
          'delivery_note' => DocSequence.deliveryNote,
          'credit_note' => DocSequence.creditNote,
          _ => DocSequence.invoice,
        };
        number = await ref
            .read(firmRepositoryProvider)
            .nextNumber(firm, docSequence, date: _invoiceDate);
        sequence = 0;
      }

      final shipping = Money.tryParse(_shippingController.text) ?? Decimal.zero;
      final discountPercent =
          Money.tryParse(_discountPercentController.text) ?? Decimal.zero;
      final discountAmount =
          Money.tryParse(_discountAmountController.text) ?? Decimal.zero;

      final draft = SalesDraft(
        id: _isEditing ? widget.editId! : IdUtils.newId(),
        number: number,
        docType: widget.docType,
        partyId: _party!.id.isEmpty ? null : _party!.id,
        invoiceDate: _invoiceDate,
        dueDate: _dueDate,
        // Keep the stored status when editing: hardcoding 'confirmed' here
        // silently re-activated a cancelled/converted document on any edit.
        status: _isEditing ? (_existingStatus ?? 'confirmed') : 'confirmed',
        lines: validLines
            .map((l) => SalesLineDraft(
                  id: l.id.isEmpty ? IdUtils.newId() : l.id,
                  itemId: l.itemId,
                  name: l.name,
                  hsn: l.hsn,
                  quantity: l.qtyDecimal,
                  unit: l.unit,
                  rate: l.rateDecimal,
                  discountPercent: l.discountPercentDecimal,
                  gstRate: l.gstRate,
                  cessRate: l.cessRate,
                  taxMode: l.taxMode,
                ))
            .toList(),
        partyName: _party!.name,
        partyGstin: _party!.gstin,
        partyGstType: _party!.gstType,
        partyPhone: _party!.phone,
        billingAddress: _partyAddress(_party),
        shippingAddress: _partyAddress(_party),
        placeOfSupply: _party!.stateCode,
        isInterState: _isInterState,
        invoiceDiscountPercent: discountPercent,
        invoiceDiscountAmount: discountAmount,
        shippingCharge: shipping,
        applyRoundOff: _applyRoundOff,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
        terms: firm.invoiceTerms,
        sequence: sequence,
      );

      // An edit keeps the document id so [SalesRepository.save] rewrites the
      // row in place: that reversal keeps payments attached (they key off
      // invoiceId) and lets the save undo the previous stock deduction before
      // posting the new one.
      // Non-invoice document types must not touch stock or party balances:
      // the repository already special-cases credit notes and quotations,
      // and delivery notes get the same treatment.
      await sales.save(draft, affectStock: _affectsStockAndBalances);

      // One-tap "Mark as fully paid": settle the invoice immediately with a
      // payment_in, the way a counter sale is completed on the desktop
      // suites. The saved row is read back so the payment equals what was
      // actually written (round-off and shipping included).
      if (_markPaid && _affectsStockAndBalances) {
        final payments = ref.read(paymentRepositoryProvider);
        final saved = await sales.getById(draft.id);
        final due = saved?.balanceDue ?? 0.0;
        if (payments != null && due > 0.001) {
          final paymentNumber = await ref
              .read(firmRepositoryProvider)
              .nextNumber(firm, DocSequence.paymentIn, date: _invoiceDate);
          await payments.create(
            type: 'payment_in',
            number: paymentNumber,
            partyId: _party!.id.isEmpty ? null : _party!.id,
            partyName: _party!.name,
            amount: due,
            date: _invoiceDate,
            mode: 'cash',
            linkedInvoiceId: draft.id,
            linkedInvoiceNumber: number,
            onLinked: (id, amt) =>
                sales.applyPayment(invoiceId: id, amount: amt),
          );
        }
      }

      // A converted quotation/order is flagged so it shows its badge in the
      // list and cannot be converted a second time.
      final sourceId = _convertSourceId;
      if (sourceId != null) {
        await sales.markConverted(sourceId);
        _convertSourceId = null;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_title.replaceFirst('New ', '')} saved')),
        );
        _dirty = false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save: $e')),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final saved = await _saveCore();
    if (saved && mounted) context.pop();
  }

  /// Saves, then resets the form for another document of the same type —
  /// the fast-billing loop of the desktop suites. A failed save keeps every
  /// value so nothing is lost.
  Future<void> _saveAndNew() async {
    final saved = await _saveCore();
    if (!saved || !mounted) return;
    setState(() {
      _isEditing = false;
      _markPaid = false;
      _invoiceDate = DateTime.now();
      _dueDate = DateTime.now().add(const Duration(days: 15));
      _notesController.clear();
      _discountPercentController.text = '0';
      _discountAmountController.text = '0';
      _shippingController.text = '0';
      _applyRoundOff = true;
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      _addLine();
      _dirty = false;
    });
    _recalcPartyDerived();
  }

  String _partyAddress(PartyEntity? party) {
    if (party == null) return '';
    return [
      party.addressLine1,
      party.addressLine2,
      [party.city, party.pincode]
          .where((e) => e != null && e.isNotEmpty)
          .join(' '),
    ].where((e) => e != null && e.trim().isNotEmpty).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final totals = _totals;

    return SaveShortcut(
      enabled: !_loading,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_loading,
        child: EditorShell(
          title: _title,
          floatingActionButton: _lines.isNotEmpty
              ? FloatingActionButton.extended(
                  onPressed: _loading ? null : _save,
                  icon: const Icon(Icons.check_rounded),
                  label: Text(_isEditing ? 'Update' : 'Save'),
                )
              : null,
          actions: EditorActions(
            onSave: _save,
            onSaveAndNew: _isEditing ? null : _saveAndNew,
            onExit: () => context.pop(),
            saving: _loading,
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : EditorShellBody(
                  form: Form(
                    key: _formKey,
                    child: _FormColumn(
                      partySection: _PartySection(
                        parties: _parties,
                        selected: _party,
                        onChanged: _selectParty,
                        onAddNew: () async {
                          // Lands on a customer form and selects the
                          // party that was just created.
                          final createdId =
                              await context.push<String>(
                                  '/parties/new?type=customer');
                          if (!mounted || createdId == null) return;
                          final partyRepo =
                              ref.read(partyRepositoryProvider);
                          if (partyRepo == null) return;
                          final created =
                              await partyRepo.getById(createdId);
                          if (created != null && mounted) {
                            setState(
                                () => _parties = [..._parties, created]);
                            _selectParty(created);
                          }
                        },
                      ),
                      metaSection: _MetaSection(
                        invoiceDate: _invoiceDate,
                        dueDate: _dueDate,
                        onDateChanged: (d) => setState(() {
                          _invoiceDate = d ?? DateTime.now();
                          _dirty = true;
                        }),
                        onDueChanged: (d) => setState(() {
                          _dueDate = d;
                          _dirty = true;
                        }),
                        isQuotation: _isQuotation,
                      ),
                      lineCards: [
                        for (var i = 0; i < _lines.length; i++)
                          _LineCard(
                            key: ValueKey(_lines[i].id),
                            controller: _lines[i],
                            index: i,
                            isInterState: _isInterState,
                            onRemove: () => _removeLine(i),
                            onCreateItem: _createItemFromLine,
                          ),
                      ],
                      onAddLine: _addLine,
                      addItemNoun: 'Add item',
                      sections: [
                        EditorLinkSection(
                          icon: Icons.note_add_rounded,
                          title: 'Add Notes',
                          builder: (_) =>
                              _NotesSection(controller: _notesController),
                        ),
                        EditorLinkSection(
                          icon: Icons.discount_outlined,
                          title: 'Add Discount & Charges',
                          builder: (_) => _AdjustmentsSection(
                            discountPercentController:
                                _discountPercentController,
                            discountAmountController:
                                _discountAmountController,
                            shippingController: _shippingController,
                            applyRoundOff: _applyRoundOff,
                            onRoundOffChanged: (v) => setState(() {
                              _applyRoundOff = v;
                              _dirty = true;
                            }),
                            onChanged: _recalc,
                          ),
                        ),
                      ],
                    ),
                  ),
                  summary: _TotalsPanelSection(
                    totals: totals,
                    shipping: Money.tryParse(_shippingController.text) ??
                        Decimal.zero,
                    isInterState: _isInterState,
                    markPaid: _markPaid,
                    canMarkPaid: _affectsStockAndBalances,
                    creditLimitMessage: _creditLimitMessage,
                    onMarkPaidChanged: (v) => setState(() {
                      _markPaid = v;
                      _dirty = true;
                    }),
                  ),
                ),
        ),
      ),
    );
  }
}

/// The scrollable form column: party + dates, line cards, dashed add-item
/// strip, then the collapsed Add-Notes / Add-Charges links.
class _FormColumn extends StatelessWidget {
  const _FormColumn({
    required this.partySection,
    required this.metaSection,
    required this.lineCards,
    required this.onAddLine,
    required this.addItemNoun,
    required this.sections,
  });

  final Widget partySection;
  final Widget metaSection;
  final List<Widget> lineCards;
  final VoidCallback onAddLine;
  final String addItemNoun;
  final List<Widget> sections;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          partySection,
          const SizedBox(height: 12),
          metaSection,
          const SizedBox(height: 16),
          ...lineCards,
          _AddItemStrip(label: addItemNoun, onTap: onAddLine),
          const SizedBox(height: 12),
          ...sections,
        ],
      ),
    );
  }
}

/// The dashed "＋ Add Item" strip, like the reference editor's affordance for
/// appending another line.
class _AddItemStrip extends StatelessWidget {
  const _AddItemStrip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
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
                label,
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

/// The summary panel contents for the sale editor: the breakdown rows plus
/// the "Mark as fully paid" footer on stock-affecting document types.
class _TotalsPanelSection extends StatelessWidget {
  const _TotalsPanelSection({
    required this.totals,
    required this.shipping,
    required this.isInterState,
    required this.markPaid,
    required this.canMarkPaid,
    required this.onMarkPaidChanged,
    this.creditLimitMessage,
  });

  final GstResult totals;
  final Decimal shipping;
  final bool isInterState;
  final bool markPaid;
  final bool canMarkPaid;
  final ValueChanged<bool> onMarkPaidChanged;

  /// Set when the party's outstanding balance would cross their credit
  /// limit. Advisory (Vyapar warns but allows), never blocks the sale.
  final String? creditLimitMessage;

  @override
  Widget build(BuildContext context) {
    final grandTotal = totals.grandTotal + shipping;
    final scheme = Theme.of(context).colorScheme;
    final rows = <EditorTotalsRow>[
      EditorTotalsRow('Subtotal', totals.subTotal),
      if (totals.itemDiscountTotal > Decimal.zero)
        EditorTotalsRow('Item discount', -totals.itemDiscountTotal,
            signed: true),
      if (totals.invoiceDiscount > Decimal.zero)
        EditorTotalsRow('Invoice discount', -totals.invoiceDiscount,
            signed: true),
      EditorTotalsRow('Taxable value', totals.taxableValue, emphasize: true),
      if (!isInterState) ...[
        if (totals.cgstTotal > Decimal.zero)
          EditorTotalsRow(
              'CGST ${Formatters.percent(_cgstRate)}', totals.cgstTotal),
        if (totals.sgstTotal > Decimal.zero)
          EditorTotalsRow(
              'SGST ${Formatters.percent(_cgstRate)}', totals.sgstTotal),
      ] else if (totals.igstTotal > Decimal.zero)
        EditorTotalsRow('IGST', totals.igstTotal),
      if (totals.cessTotal > Decimal.zero)
        EditorTotalsRow('Cess', totals.cessTotal),
      if (shipping > Decimal.zero)
        EditorTotalsRow('Shipping', shipping),
      if (totals.roundOff.abs() > Decimal.zero)
        EditorTotalsRow('Round off', totals.roundOff, signed: true),
    ];

    return EditorTotalsPanel(
      rows: rows,
      total: grandTotal,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (creditLimitMessage != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(Icons.credit_card_off_rounded,
                      size: 16, color: scheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      creditLimitMessage!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          if (canMarkPaid)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Mark as fully paid',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              subtitle: Text(
                markPaid
                    ? 'A cash payment for the full balance is recorded on save'
                    : 'Settle this invoice in one tap on save',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              value: markPaid,
              onChanged: (v) => onMarkPaidChanged(v ?? false),
            ),
        ],
      ),
    );
  }

  /// Effective CGST/SGST split of the document's total tax rate — derived
  /// from the rate-wise summary, shown in the row labels the way desktop
  /// suites do ("SGST @6%" not a bare "SGST").
  double get _cgstRate {
    if (totals.rateWise.isEmpty) return 0;
    return totals.rateWise.first.rate / 2;
  }
}

/// Mutable state for one invoice line.
class _LineController {
  _LineController({required this.items, required this.onChanged}) {
    id = IdUtils.newId();
    _listen();
  }

  /// Hooks the editors up to [onChanged]. Called at the end of both
  /// constructors so the programmatic `text =` assignments above it — which
  /// fire listeners — land before the hook is in place, and prefilling an
  /// existing document does not mark the form dirty.
  void _listen() {
    for (final controller in [
      _nameController,
      _hsnController,
      _qtyController,
      _rateController,
      _discountController,
    ]) {
      controller.addListener(onChanged);
    }
  }

  factory _LineController.fromEntity(
      SalesInvoiceItemEntity e, List<ItemEntity> items,
      {required VoidCallback onChanged}) {
    final c = _LineController(items: items, onChanged: onChanged);
    c.id = e.id;
    c.itemId = e.itemId;
    c._nameController.text = e.name;
    c._hsnController.text = e.hsn ?? '';
    c._qtyController.text = Formatters.qty(Decimal.parse(e.quantity.toString()));
    c._unit = e.unit;
    c._rateController.text =
        Formatters.indianGroup(e.rate.toStringAsFixed(2));
    c._discountController.text = e.discountPercent.toStringAsFixed(2);
    c.gstRate = e.gstRate;
    c.cessRate = e.cessRate;
    c.taxMode =
        e.taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
    c.items = items;
    c._listen();
    return c;
  }

  List<ItemEntity> items;
  VoidCallback onChanged;

  late String id;
  String? itemId;
  final _nameController = TextEditingController();
  final _hsnController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _rateController = TextEditingController(text: '0');
  final _discountController = TextEditingController(text: '0');
  String _unit = 'pcs';
  double gstRate = 18;
  double cessRate = 0;
  TaxMode _taxMode = TaxMode.exclusive;

  set taxMode(TaxMode value) {
    if (value == _taxMode) return;
    _taxMode = value;
    onChanged();
  }

  TaxMode get taxMode => _taxMode;

  TextEditingController get nameController => _nameController;
  TextEditingController get hsnController => _hsnController;
  TextEditingController get qtyController => _qtyController;
  TextEditingController get rateController => _rateController;
  TextEditingController get discountController => _discountController;
  String get unit => _unit;
  set unit(String value) {
    _unit = value;
    onChanged();
  }

  String get name => _nameController.text.trim();
  String get hsn => _hsnController.text.trim().toUpperCase();

  Decimal get qtyDecimal =>
      Money.tryParse(_qtyController.text) ?? Decimal.zero;
  Decimal get rateDecimal =>
      Money.tryParse(_rateController.text) ?? Decimal.zero;
  Decimal get discountPercentDecimal =>
      Money.tryParse(_discountController.text) ?? Decimal.zero;

  bool get isValid {
    if (name.isEmpty) return false;
    if (qtyDecimal <= Decimal.zero) return false;
    return true;
  }

  Decimal get lineGross => qtyDecimal * rateDecimal;

  void applyItem(ItemEntity item) {
    itemId = item.id;
    _nameController.text = item.name;
    _hsnController.text = item.hsn ?? '';
    _unit = item.unit;
    _rateController.text =
        Formatters.indianGroup(item.salePrice.toStringAsFixed(2));
    gstRate = item.gstRate;
    cessRate = item.cessRate;
    taxMode =
        item.taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
    onChanged();
  }

  void dispose() {
    _nameController.dispose();
    _hsnController.dispose();
    _qtyController.dispose();
    _rateController.dispose();
    _discountController.dispose();
  }
}

class _PartySection extends StatelessWidget {
  const _PartySection({
    required this.parties,
    required this.selected,
    required this.onChanged,
    required this.onAddNew,
  });

  final List<PartyEntity> parties;
  final PartyEntity? selected;
  final ValueChanged<PartyEntity?> onChanged;
  final VoidCallback onAddNew;

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Customer',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            TextButton.icon(
              onPressed: onAddNew,
              icon: const Icon(Icons.person_add_alt_outlined, size: 17),
              label: const Text('New'),
            ),
          ],
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<PartyEntity>(
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Select customer',
              prefixIcon: Icon(PhosphorIconsRegular.user, size: 19),
            ),
            items: [
              for (final p in parties)
                DropdownMenuItem(
                  value: p,
                  // ONE line in the selected view. The old two-line Column
                  // overflowed the input decorator by ~13px whenever the
                  // party had a GSTIN/phone (the closed button is single-line
                  // height) — the "BOTTOM OVERFLOWED BY 13 PIXELS" on Edit
                  // Invoice. The details live in the info panel below and in
                  // the open menu, which has room for two lines.
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: onChanged,
            validator: (value) =>
                value == null ? 'Please select a customer' : null,
          ),
          if (selected != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(PhosphorIconsRegular.mapPinLine,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // GSTIN + phone first (moved from the dropdown's
                        // closed view, where they overflowed), then address.
                        if ((selected!.gstin ?? '').isNotEmpty ||
                            (selected!.phone ?? '').isNotEmpty)
                          Text(
                            [
                              selected!.gstin?.toUpperCase(),
                              selected!.phone,
                            ]
                                .where((e) => e != null && e.isNotEmpty)
                                .join(' • '),
                            style: Theme.of(context).textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(
                          [
                            selected!.addressLine1,
                            selected!.city,
                            selected!.pincode,
                          ]
                              .where((e) => e != null && e.isNotEmpty)
                              .join(', '),
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (selected!.stateCode != null)
                          Text(
                            'Place of supply: ${IndianStates.byCode(selected!.stateCode)?.name ?? selected!.stateCode}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MetaSection extends StatelessWidget {
  const _MetaSection({
    required this.invoiceDate,
    required this.dueDate,
    required this.onDateChanged,
    required this.onDueChanged,
    required this.isQuotation,
  });

  final DateTime invoiceDate;
  final DateTime? dueDate;
  final ValueChanged<DateTime?> onDateChanged;
  final ValueChanged<DateTime?> onDueChanged;
  final bool isQuotation;

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: _DateField(
              label: isQuotation ? 'Quotation date' : 'Invoice date',
              value: invoiceDate,
              onChanged: onDateChanged,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _DateField(
              label: isQuotation ? 'Valid till' : 'Due date',
              value: dueDate,
              onChanged: onDueChanged,
              clearable: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.clearable = false,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onChanged(picked);
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: clearable && value != null
              ? IconButton(
                  tooltip: 'Clear date',
                  icon: const Icon(Icons.close_rounded, size: 16),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_rounded, size: 17),
        ),
        child: Text(
          value == null ? 'Not set' : Formatters.date(value),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _LineCard extends StatefulWidget {
  const _LineCard({
    super.key,
    required this.controller,
    required this.index,
    required this.isInterState,
    required this.onRemove,
    required this.onCreateItem,
  });

  final _LineController controller;
  final int index;
  final bool isInterState;
  final VoidCallback onRemove;

  /// The line's typed name matched nothing in the catalogue — persist it as
  /// a new item silently (Vyapar-style) and link the line to it.
  final void Function(_LineController line, String name) onCreateItem;

  @override
  State<_LineCard> createState() => _LineCardState();
}

class _LineCardState extends State<_LineCard> {
  @override
  void initState() {
    super.initState();
    // Compose with the parent's callback instead of overwriting it: the
    // controller's onChanged is the editor's _onLineChanged (marks the form
    // dirty and recalcs totals). Overwriting it here left the sticky totals
    // stale and the form never dirty on item/tax changes.
    final parentOnChanged = widget.controller.onChanged;
    widget.controller.onChanged = () {
      parentOnChanged();
      _refresh();
    };
    for (final c in [
      widget.controller.qtyController,
      widget.controller.rateController,
      widget.controller.discountController,
    ]) {
      c.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      widget.controller.qtyController,
      widget.controller.rateController,
      widget.controller.discountController,
    ]) {
      c.removeListener(_refresh);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    final lineTotals = GstEngine.computeLine(
      TaxLine(
        id: c.id,
        itemId: c.itemId,
        name: c.name.isEmpty ? 'Item' : c.name,
        hsn: c.hsn,
        quantity: c.qtyDecimal,
        unit: c.unit,
        rate: c.rateDecimal,
        discountPercent: c.discountPercentDecimal,
        gstRate: c.gstRate,
        cessRate: c.cessRate,
        taxMode: c.taxMode,
      ),
      widget.isInterState ? GstSplit.interState : GstSplit.intraState,
    );

    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${widget.index + 1}',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                // Type-ahead, Vyapar-style: typing filters the catalogue, and
                // a name matching nothing is saved as a NEW item silently —
                // no dialog, no extra step. (Was a closed dropdown over a
                // snapshot: unknown names were impossible to add.)
                child: ItemTypeAheadField(
                  controller: c.nameController,
                  items: [
                    for (final item in c.items)
                      ItemSuggestion(
                        name: item.name,
                        salePrice: item.salePrice,
                        unit: item.unit,
                      ),
                  ],
                  onPickItem: (s) {
                    final match = c.items
                        .where((i) => i.name == s.name)
                        .cast<ItemEntity?>()
                        .firstWhere((i) => i != null, orElse: () => null);
                    if (match != null) {
                      c.applyItem(match);
                      _refresh();
                    }
                  },
                  onCreateItem: (name) {
                    widget.onCreateItem(c, name);
                    _refresh();
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
                color: scheme.onSurfaceVariant,
                onPressed: widget.onRemove,
                tooltip: 'Remove line',
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: c.nameController,
            decoration: const InputDecoration(
              labelText: 'Description',
              isDense: true,
            ),
            validator: (value) => (value == null || value.trim().isEmpty)
                ? 'Required'
                : null,
          ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: c.qtyController,
                    decoration: InputDecoration(
                      labelText: 'Qty',
                      isDense: true,
                      suffixText: Unit.symbolOf(c.unit),
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    // Invalid lines used to be silently dropped at save (the
                    // invoice saved as N-1 lines); now the field itself blocks
                    // the save and says why.
                    validator: (value) {
                      final qty = Money.tryParse(value ?? '');
                      if (qty == null || qty <= Decimal.zero) {
                        return 'Must be greater than 0';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 4,
                  child: TextFormField(
                    controller: c.rateController,
                    decoration: const InputDecoration(
                      labelText: 'Rate',
                      prefixText: '₹ ',
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: c.discountController,
                    decoration: const InputDecoration(
                      labelText: 'Disc %',
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              children: [
                // Was a read-only "GST 18%" label — a user billing at 5%/12%
                // had no in-editor fix (items default to 18%). Same dropdown
                // as the purchase editor now.
                DropdownButton<double>(
                  value: c.gstRate,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  items: [
                    for (final rate in GstRate.standard)
                      DropdownMenuItem<double>(
                        value: rate.rate,
                        child: Text(
                          rate.rate > 0 ? rate.label : 'No GST',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    // Keep a non-standard rate (imported/custom item) selectable.
                    if (GstRate.fromDouble(c.gstRate) == null)
                      DropdownMenuItem<double>(
                        value: c.gstRate,
                        child: Text(
                          Formatters.percent(c.gstRate),
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null || value == c.gstRate) return;
                    setState(() => c.gstRate = value);
                    widget.controller.onChanged();
                  },
                ),
                const SizedBox(width: 8),
                // Inclusive = the entered rate already contains GST (GST
                // EXCLUDED = tax added on top). Per line, like Vyapar; the
                // item's own taxMode seeds it via applyItem.
                if (c.gstRate > 0) ...[
                  TaxModeToggle(
                    value: c.taxMode,
                    onChanged: (mode) {
                      setState(() => c.taxMode = mode);
                    },
                  ),
                ],
                const Spacer(),
                Text(
                  'Amount',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                c.hsn.isEmpty ? 'HSN/SAC —' : 'HSN ${c.hsn}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              MoneyText(
                lineTotals.total,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                colorize: false,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdjustmentsSection extends StatelessWidget {
  const _AdjustmentsSection({
    required this.discountPercentController,
    required this.discountAmountController,
    required this.shippingController,
    required this.applyRoundOff,
    required this.onRoundOffChanged,
    required this.onChanged,
  });

  final TextEditingController discountPercentController;
  final TextEditingController discountAmountController;
  final TextEditingController shippingController;
  final bool applyRoundOff;
  final ValueChanged<bool> onRoundOffChanged;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Adjustments',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: discountPercentController,
                  decoration: const InputDecoration(
                    labelText: 'Invoice discount %',
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => onChanged(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: shippingController,
                  decoration: const InputDecoration(
                    labelText: 'Shipping / freight',
                    prefixText: '₹ ',
                    isDense: true,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => onChanged(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Round off grand total'),
            subtitle: const Text(
                'Round to the nearest rupee, as per Section 170'),
            value: applyRoundOff,
            onChanged: onRoundOffChanged,
          ),
        ],
      ),
    );
  }
}

class _NotesSection extends StatelessWidget {
  const _NotesSection({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Notes',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'Thank you for your business…',
            ),
          ),
        ],
      ),
    );
  }
}

