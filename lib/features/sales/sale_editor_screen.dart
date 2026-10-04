import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/sales_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_utils.dart';
import '../../core/utils/money.dart';
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

  /// TCS percentage. Defaults to the firm's `invoiceTcsRate` on a new invoice
  /// and comes from the stored document on an edit, so a shop that always
  /// collects 0.1% under s.206C(1H) types it once in the firm profile.
  final _tcsRateController = TextEditingController(text: '0');
  bool _applyRoundOff = true;

  /// One-tap settlement: records a payment covering the invoice as soon as
  /// it is saved, so a cash sale shows Paid instead of Unpaid.
  bool _markPaid = false;

  // Lines
  final List<_LineController> _lines = [];

  // Catalog lookups
  List<ItemEntity> _items = const [];

  /// Firm-defined units, for the line-grid unit picker.
  List<UnitEntity> _customUnits = const [];
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

  /// The firm's own TCS rate (0 when it collects none) — the default this
  /// invoice's field is prefilled with.
  double get _firmTcsRate =>
      ref.read(activeFirmProvider).valueOrNull?.invoiceTcsRate ?? 0;

  String get _firmTcsRateText => Formatters.rateInput(_firmTcsRate);

  String? get _creditLimitMessage {
    final limit = _partyCreditLimit;
    if (limit == null || limit <= 0) return null;
    final grandTotal =
        _totals.grandTotal +
        (Money.tryParse(_shippingController.text) ?? Decimal.zero);
    final projected = _partyOutstanding + grandTotal.toDouble();
    if (projected <= limit) return null;
    String fmt(double v) => Formatters.money(
      Decimal.tryParse(v.toStringAsFixed(2)) ?? Decimal.zero,
    );
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

  String get _title => '${_isEditing ? 'Edit' : 'New'} $_docNoun';

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
      // TCS was missing from this list, so typing a rate called `_recalc()`
      // (the totals redrew) while `UnsavedGuard.hasChanges` stayed false —
      // Back or Escape then discarded the rate with no warning.
      _tcsRateController,
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
    _tcsRateController.dispose();
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
      // The firm's own units, so a unit created in the item editor stays
      // selectable on a line. Without these the picker offered only the
      // standard set, and changing a line's unit made the custom one vanish
      // with no way back to it.
      _customUnits = await itemRepo.units();
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
      // with the customer already chosen. The preset has to survive the rest of
      // this method — nothing below may fall back to "pick something" (see the
      // plain-new branch further down), which is what used to make this deep
      // link dead.
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
        _discountPercentController.text = doc.invoiceDiscountPercent
            .toStringAsFixed(2);
        _discountAmountController.text = doc.invoiceDiscountAmount
            .toStringAsFixed(2);
        _shippingController.text = doc.shippingCharge.toStringAsFixed(2);
        _tcsRateController.text = Formatters.rateInput(doc.tcsRate);
        _applyRoundOff =
            doc.roundOff.abs() > 0.000001 ||
            (doc.grandTotal - doc.grandTotal.round()).abs() < 0.001;
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
          _lines.add(
            _LineController.fromEntity(l, _items, onChanged: _onLineChanged),
          );
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
        _discountPercentController.text = doc.invoiceDiscountPercent
            .toStringAsFixed(2);
        _discountAmountController.text = doc.invoiceDiscountAmount
            .toStringAsFixed(2);
        _shippingController.text = doc.shippingCharge.toStringAsFixed(2);
        _tcsRateController.text = Formatters.rateInput(doc.tcsRate);
        _applyRoundOff =
            doc.roundOff.abs() > 0.000001 ||
            (doc.grandTotal - doc.grandTotal.round()).abs() < 0.001;
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
          _lines.add(
            _LineController.fromEntity(l, _items, onChanged: _onLineChanged),
          );
        }
        if (_lines.isEmpty) _addLine();
        _recalcPartyDerived();
      }
    } else {
      // No silent pre-selection.
      //
      // This used to call `_selectParty(_parties.first)` under the comment
      // "Pre-select the last-used customer" — but `_parties` is a name-ordered,
      // 2000-row snapshot, so `_parties.first` is the ALPHABETICALLY FIRST
      // customer. A new invoice therefore opened against a shop the user never
      // mentioned, and the `_dirty = false` below meant the unsaved-changes
      // guard never warned. It also overwrote the `?party=<id>` deep link set
      // above (D15), which is how the Parties pane's "New invoice" landed on
      // the wrong customer.
      //
      // Why stop rather than implement "last used": the id belongs in the
      // firm's settings, and this screen owns neither that table nor a place to
      // cache it — an in-memory "last used" would be wrong after a restart and
      // wrong on the next device. An empty field makes the user pick the
      // customer once (and Save refuses an invoice with none), which is a far
      // smaller cost than an invoice raised against the wrong party.
      //
      // A firm that collects TCS sets the rate once in its profile; retyping it
      // on every invoice is how a rate gets typed wrong. An edit keeps
      // whatever the document was issued with instead.
      _tcsRateController.text = _firmTcsRateText;
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

  /// Appends a line. [focus] moves the caret into the new line's item cell —
  /// the spreadsheet behaviour of Enter at the end of the sheet. Only user
  /// initiated adds ask for it, so opening an invoice does not pop a keyboard.
  void _addLine({bool focus = false}) {
    final line = _LineController(items: _items, onChanged: _onLineChanged);
    setState(() => _lines.add(line));
    _recalc();
    if (!focus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) line.nameFocus.requestFocus();
    });
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

  GstSplit get _split =>
      _isInterState ? GstSplit.interState : GstSplit.intraState;

  /// [GstSplit] with the Union-Territory case resolved, for LABELS only: the
  /// engine still computes with [_split] (an inter-state document charges IGST
  /// whatever the state codes say), and an unregistered or state-less party
  /// stays intra-state, exactly as [_isInterState] decided.
  GstSplit get _documentSplit => _isInterState
      ? GstSplit.interState
      : resolveGstSplit(
          supplierState: _party?.stateCode,
          buyerState: ref.read(activeFirmProvider).valueOrNull?.stateCode,
        );

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
    final lines = _lines.where((l) => l.isValid).map((l) => l.taxLine).toList();
    final discountPercent =
        Money.tryParse(_discountPercentController.text) ?? Decimal.zero;
    final discountAmount =
        Money.tryParse(_discountAmountController.text) ?? Decimal.zero;
    return GstEngine.computeDocument(
      lines: lines,
      split: _split,
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
        if (existing == null || existing.isDeleted) {
          // The document vanished (binned or purged elsewhere) between
          // opening this editor and saving. The repository treats a missing
          // live row as a NEW insert, so saving here would resurrect it —
          // and hard-deletion would insert it under a placeholder number.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'This document no longer exists — it may '
                  'have been deleted. Nothing was saved.',
                ),
              ),
            );
          }
          return false;
        }
        number = existing.number;
        sequence = existing.sequence;
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
      final tcsRate = Money.tryParse(_tcsRateController.text) ?? Decimal.zero;
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
            .map(
              (l) => SalesLineDraft(
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
              ),
            )
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
        tcsRate: tcsRate,
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
      final savedDoc = await sales.save(
        draft,
        affectStock: _affectsStockAndBalances,
      );

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

      // An edit that takes the invoice below what has already been received
      // leaves no honest balance to show: the repository clamps it to ₹0 and
      // the payments ledger stands as it is. The success message carries that
      // warning instead of hiding it behind "saved".
      final settlement = DocumentSettlement.of(
        grandTotal: savedDoc.grandTotal,
        paidAmount: savedDoc.paidAmount,
      );
      final overpayment = settlement.overpaid
          ? 'Saved, but ${Formatters.money(Decimal.parse(savedDoc.paidAmount.toStringAsFixed(2)))} '
                'was already received and this invoice is now worth only '
                '${Formatters.money(Decimal.parse(savedDoc.grandTotal.toStringAsFixed(2)))}. '
                'The balance shows as zero — check the payments recorded against it.'
          : null;

      // A converted quotation/order records which invoice it became, so the list
      // can badge it, open the invoice from it, and refuse a second
      // conversion. The link is the whole point — the old flag recorded only
      // that something had happened, never what.
      final sourceId = _convertSourceId;
      if (sourceId != null) {
        await sales.markConverted(sourceId, invoiceId: draft.id);
        _convertSourceId = null;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              overpayment ?? '${_title.replaceFirst('New ', '')} saved',
            ),
            duration: overpayment == null
                ? const Duration(seconds: 4)
                : const Duration(seconds: 8),
          ),
        );
        _dirty = false;
      }
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save: $e')));
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
      _tcsRateController.text = _firmTcsRateText;
      _applyRoundOff = true;
      for (final l in _lines) {
        l.dispose();
      }
      _lines.clear();
      _addLine();
      _dirty = false;
    });
    _recalcPartyDerived();
    // The saved document just increased the party's outstanding; without
    // this the credit-limit banner keeps quoting the pre-save figure.
    _loadPartyCreditInfo();
  }

  String _partyAddress(PartyEntity? party) {
    if (party == null) return '';
    return [
      party.addressLine1,
      party.addressLine2,
      [
        party.city,
        party.pincode,
      ].where((e) => e != null && e.isNotEmpty).join(' '),
    ].where((e) => e != null && e.trim().isNotEmpty).join(', ');
  }

  /// The line sheet's columns. Fixed here (not per document type) so an
  /// invoice, a quotation, a sales order and a credit note are all entered
  /// with the same eye movement.
  // The sheet is full-bleed, so the prose column carries the slack and the
  // figure columns stay tight enough to read a column of numbers down.
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
            onRemove: _lines.length == 1 ? null : () => _removeLine(i),
          ),
      ],
    );
  }

  List<Widget> _lineCells(int index) {
    final c = _lines[index];
    final isLastRow = index == _lines.length - 1;
    final scheme = Theme.of(context).colorScheme;

    // Enter at the end of the sheet starts the next line, exactly like a
    // spreadsheet; anywhere else it moves on and lets traversal take over.
    void advance() {
      if (isLastRow) {
        _addLine(focus: true);
      } else {
        FocusScope.of(context).nextFocus();
      }
    }

    // The row's own figure must describe what the save will write. An
    // incomplete line (no name, or no quantity) is excluded from the
    // document totals, so printing an amount next to it made the rows add up
    // to more than the invoice is worth.
    final lineTotals = c.isValid ? c.totalsFor(_split) : LineTotals.empty();

    return [
      ItemTypeAheadField(
        key: ValueKey('${c.id}-item'),
        controller: c.nameController,
        focusNode: c.nameFocus,
        label: 'Item',
        hintText: 'Item or service',
        validator: (value) =>
            (value == null || value.trim().isEmpty) ? 'Required' : null,
        decoration: (context) =>
            AtriaGridCell.decorationFor(context, hint: 'Item or service'),
        items: [for (final item in c.items) _CatalogueSuggestion(item)],
        onPickItem: (s) {
          // The suggestion carries the catalogue row it was built from, so
          // two items differing only by case ("Laptop"/"laptop") resolve to the
          // one the user actually clicked. Resolving by name equality made them
          // indistinguishable rows with the first always winning.
          final picked = s is _CatalogueSuggestion ? s.item : null;
          if (picked == null) return;
          c.applyItem(picked);
          _recalc();
        },
        onCreateItem: (name) => _createItemFromLine(c, name),
      ),
      AtriaGridInput(
        key: ValueKey('${c.id}-hsn'),
        controller: c.hsnController,
        hint: 'HSN',
        textCapitalization: TextCapitalization.characters,
        onSubmitted: advance,
      ),
      Row(
        key: ValueKey('${c.id}-qty'),
        children: [
          Expanded(
            child: AtriaGridInput(
              controller: c.qtyController,
              numeric: true,
              textAlign: TextAlign.right,
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
            // The unit setter already notifies the line (which recalculates
            // and rebuilds) — wrapping that in a setState here would nest.
            child: AtriaUnitPicker(
              value: c.unit,
              customUnits: _customUnits,
              onChanged: (unit) => c.unit = unit,
            ),
          ),
        ],
      ),
      AtriaGridInput(
        key: ValueKey('${c.id}-rate'),
        controller: c.rateController,
        numeric: true,
        textAlign: TextAlign.right,
        prefix: '₹ ',
        onSubmitted: advance,
      ),
      AtriaGridInput(
        key: ValueKey('${c.id}-disc'),
        controller: c.discountController,
        numeric: true,
        textAlign: TextAlign.right,
        onSubmitted: advance,
      ),
      Row(
        key: ValueKey('${c.id}-gst'),
        children: [
          Expanded(
            child: AtriaGstRatePicker(
              value: c.gstRate,
              onChanged: (rate) {
                setState(() => c.gstRate = rate);
                c.onChanged();
              },
            ),
          ),
          // Inclusive = the entered rate already contains GST. Off-standard
          // rates keep the pill too, since they are still a real tax rate.
          if (c.gstRate > 0)
            AtriaTaxModePill(
              value: c.taxMode,
              onChanged: (mode) => c.taxMode = mode,
            ),
        ],
      ),
      Padding(
        key: ValueKey('${c.id}-amount'),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        // In the sheet the figure stays bare under its column heading; in the
        // stacked card it gets the same hairline box as every other cell.
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

  /// The Tally half: the full tax breakdown, the grand total, and the
  /// settlement shortcuts — identical row set to every other document editor.
  Widget _totalsSection(GstResult totals) {
    final scheme = Theme.of(context).colorScheme;
    final shipping = Money.tryParse(_shippingController.text) ?? Decimal.zero;
    final tcsRate = Money.tryParse(_tcsRateController.text) ?? Decimal.zero;
    final tcs = GstEngine.settlementTax(
      taxableValue: totals.taxableValue,
      rate: tcsRate,
    );
    return AtriaTotalsBlock(
      totals: totals,
      // TCS and shipping are both added to the invoice value; the rows above
      // the total say where each one came from.
      extraCharges: shipping + tcs,
      extraRows: [
        if (shipping > Decimal.zero) EditorTotalsRow('Shipping', shipping),
        if (tcs > Decimal.zero)
          EditorTotalsRow('TCS ${Formatters.percent(tcsRate.toDouble())}', tcs),
      ],
      isInterState: _isInterState,
      // The same split, refined to name a Union Territory's second head: CGST +
      // UTGST, matching what the saved document (and its PDF) says.
      split: _documentSplit,
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_creditLimitMessage != null)
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
                  Icon(
                    Icons.credit_card_off_rounded,
                    size: 16,
                    color: scheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _creditLimitMessage!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Only a true invoice can be settled: the payment path keys off
          // balanceDue, which the repository zeroes for every other doc
          // type — the checkbox there would silently do nothing.
          if (widget.docType == 'invoice')
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Mark as fully paid',
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                _markPaid
                    ? 'A cash payment for the full balance is recorded on save'
                    : 'Settle this invoice in one tap on save',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              value: _markPaid,
              onChanged: (v) => setState(() {
                _markPaid = v ?? false;
                _dirty = true;
              }),
            ),
        ],
      ),
    );
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
          actions: EditorActions(
            onSave: _save,
            onSaveAndNew: _isEditing ? null : _saveAndNew,
            onExit: () => context.pop(),
            saving: _loading,
          ),
          hint:
              'Tab → next cell   ·   Enter → next line   ·   '
              'Ctrl+S → save & close',
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : EditorShellBody(
                  form: Form(
                    key: _formKey,
                    child: AtriaEditorForm(
                      header: _PartySection(
                        parties: _parties,
                        selected: _party,
                        onChanged: _selectParty,
                        onAddNew: () async {
                          // Lands on a customer form and selects the
                          // party that was just created.
                          final createdId = await context.push<String>(
                            '/parties/new?type=customer',
                          );
                          if (!mounted || createdId == null) return;
                          final partyRepo = ref.read(partyRepositoryProvider);
                          if (partyRepo == null) return;
                          final created = await partyRepo.getById(createdId);
                          if (created != null && mounted) {
                            setState(() => _parties = [..._parties, created]);
                            _selectParty(created);
                          }
                        },
                      ),
                      headerTrailing: _MetaSection(
                        invoiceDate: _invoiceDate,
                        dueDate: _dueDate,
                        onDateChanged: (d) => setState(() {
                          // Re-clamp the due date. The due-date picker's
                          // `firstDate: invoiceDate` only constrains NEW picks,
                          // so moving the invoice date forward used to leave
                          // the old due date behind and save an invoice that
                          // was overdue the moment it existed.
                          //
                          // The credit PERIOD is preserved rather than the
                          // absolute date (a 15-day term stays a 15-day term),
                          // and a due date that sat on the invoice date is
                          // pulled up to it so it is never in the past.
                          final creditPeriod = _dueDate?.difference(
                            _invoiceDate,
                          );
                          _invoiceDate = d ?? DateTime.now();
                          if (creditPeriod != null) {
                            final shifted = _invoiceDate.add(creditPeriod);
                            _dueDate = shifted.isBefore(_invoiceDate)
                                ? _invoiceDate
                                : shifted;
                          }
                          _dirty = true;
                        }),
                        onDueChanged: (d) => setState(() {
                          _dueDate = d;
                          _dirty = true;
                        }),
                        isQuotation: _isQuotation,
                      ),
                      lines: _lineGrid(),
                      // The totals sit under the last line, right-aligned,
                      // instead of in a side rail the eye has to travel back
                      // to on every edit.
                      totals: _totalsSection(totals),
                      sections: [
                        // QBO labels this block "Message on invoice", and it is
                        // visible on the page rather than hidden behind a link.
                        EditorLinkSection(
                          icon: Icons.note_add_rounded,
                          title: 'Message on invoice',
                          initiallyOpen: true,
                          builder: (_) =>
                              _NotesSection(controller: _notesController),
                        ),
                        EditorLinkSection(
                          icon: Icons.discount_outlined,
                          title: 'Discount, shipping and round off',
                          builder: (_) => _AdjustmentsSection(
                            discountPercentController:
                                _discountPercentController,
                            discountAmountController: _discountAmountController,
                            shippingController: _shippingController,
                            tcsRateController: _tcsRateController,
                            tcsHint: _firmTcsRate > 0
                                ? 'The firm profile collects '
                                      '${Formatters.percent(_firmTcsRate)} — it '
                                      'is already filled in.'
                                : 'Tax collected at source under '
                                      's.206C(1H), on the taxable value.',
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
                ),
        ),
      ),
    );
  }
}

/// A type-ahead row that remembers which catalogue row it came from.
///
/// [ItemSuggestion] carries only what the dropdown renders (name, price,
/// unit), so `onPickItem` had to find the item again by `name == s.name`:
/// two items differing only by case rendered as identical rows and the first
/// always won. Carrying the row itself makes the selection unambiguous
/// without a second lookup — and without a change to the shared type-ahead
/// widget.
class _CatalogueSuggestion extends ItemSuggestion {
  _CatalogueSuggestion(this.item)
    : super(name: item.name, salePrice: item.salePrice, unit: item.unit);

  final ItemEntity item;
}

/// Mutable state for one invoice line.
class _LineController {
  /// Unlistened constructor. [factory _LineController] and [_LineController.fromEntity]
  /// call [_listen] exactly once, AFTER any programmatic `text =` prefill —
  /// which fires listeners — so loading a document never marks the form
  /// dirty, and a user keystroke never notifies twice.
  _LineController._({required this.items, required this.onChanged});

  factory _LineController({
    required List<ItemEntity> items,
    required VoidCallback onChanged,
  }) {
    final c = _LineController._(items: items, onChanged: onChanged);
    c.id = IdUtils.newId();
    c._listen();
    return c;
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
    SalesInvoiceItemEntity e,
    List<ItemEntity> items, {
    required VoidCallback onChanged,
  }) {
    final c = _LineController._(items: items, onChanged: onChanged);
    c.id = e.id;
    c.itemId = e.itemId;
    c._nameController.text = e.name;
    c._hsnController.text = e.hsn ?? '';
    c._qtyController.text = Formatters.qty(
      Decimal.parse(e.quantity.toString()),
    );
    c._unit = e.unit;
    c._rateController.text = Formatters.indianGroup(e.rate.toStringAsFixed(2));
    c._discountController.text = e.discountPercent.toStringAsFixed(2);
    c.gstRate = e.gstRate;
    c.cessRate = e.cessRate;
    c.taxMode = e.taxMode == 'inclusive'
        ? TaxMode.inclusive
        : TaxMode.exclusive;
    c.items = items;
    // The one and only listener hook-up: every `text =` assignment above
    // fired no callbacks, so prefilled lines start clean.
    c._listen();
    return c;
  }

  List<ItemEntity> items;
  VoidCallback onChanged;

  /// Focus target for the line's item cell — Enter at the end of the sheet
  /// lands here.
  final nameFocus = FocusNode();

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

  Decimal get qtyDecimal => Money.tryParse(_qtyController.text) ?? Decimal.zero;
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

  /// The engine's view of this line — one definition, used by the row's own
  /// amount and by the document totals, so the two can never disagree.
  TaxLine get taxLine => TaxLine(
    id: id,
    itemId: itemId,
    name: name.isEmpty ? 'Item' : name,
    hsn: hsn,
    quantity: qtyDecimal,
    unit: unit,
    rate: rateDecimal,
    discountPercent: discountPercentDecimal,
    gstRate: gstRate,
    cessRate: cessRate,
    taxMode: taxMode,
  );

  LineTotals totalsFor(GstSplit split) => GstEngine.computeLine(taxLine, split);

  void applyItem(ItemEntity item) {
    itemId = item.id;
    _nameController.text = item.name;
    _hsnController.text = item.hsn ?? '';
    _unit = item.unit;
    _rateController.text = Formatters.indianGroup(
      item.salePrice.toStringAsFixed(2),
    );
    gstRate = item.gstRate;
    cessRate = item.cessRate;
    taxMode = item.taxMode == 'inclusive'
        ? TaxMode.inclusive
        : TaxMode.exclusive;
    onChanged();
  }

  void dispose() {
    nameFocus.dispose();
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
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              TextButton.icon(
                onPressed: onAddNew,
                icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                label: const Text('New'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<PartyEntity>(
            iconSize: AppIconSize.md,
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Select customer',
              prefixIcon: AtriaFieldIcon(PhosphorIconsRegular.user, size: 18),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.mapPinLine,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
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
                            [selected!.gstin?.toUpperCase(), selected!.phone]
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
                          ].where((e) => e != null && e.isNotEmpty).join(', '),
                          style: Theme.of(context).textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (selected!.stateCode != null)
                          Text(
                            'Place of supply: ${IndianStates.byCode(selected!.stateCode)?.name ?? selected!.stateCode}',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
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
              // A due date before the invoice date is not a credit period,
              // it is a bug: the invoice would land in the overdue reminders
              // the moment it is saved.
              firstDate: invoiceDate,
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
    this.firstDate,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool clearable;

  /// Earliest pickable date (e.g. the invoice date for a due-date field).
  final DateTime? firstDate;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        // Clamp instead of asserting: older documents can carry a due date
        // before their invoice date, and showDatePicker throws when the
        // initial date precedes firstDate.
        final first = firstDate ?? DateTime(2000);
        var initial = value ?? DateTime.now();
        if (initial.isBefore(first)) initial = first;
        final picked = await showDatePicker(
          context: context,
          initialDate: initial,
          firstDate: first,
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
                  icon: const Icon(Icons.close_rounded, size: AppIconSize.md),
                  onPressed: () => onChanged(null),
                )
              : const Icon(Icons.calendar_today_rounded, size: AppIconSize.md),
        ),
        child: Text(
          value == null ? 'Not set' : Formatters.date(value),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _AdjustmentsSection extends StatelessWidget {
  const _AdjustmentsSection({
    required this.discountPercentController,
    required this.discountAmountController,
    required this.shippingController,
    required this.tcsRateController,
    required this.tcsHint,
    required this.applyRoundOff,
    required this.onRoundOffChanged,
    required this.onChanged,
  });

  final TextEditingController discountPercentController;
  final TextEditingController discountAmountController;
  final TextEditingController shippingController;
  final TextEditingController tcsRateController;
  final String tcsHint;
  final bool applyRoundOff;
  final ValueChanged<bool> onRoundOffChanged;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    // No card of its own: the link section above it is already the surface.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AtriaFormFieldRow(
          first: TextFormField(
            controller: discountPercentController,
            decoration: const InputDecoration(labelText: 'Invoice discount %'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
          ),
          second: TextFormField(
            controller: shippingController,
            decoration: const InputDecoration(
              labelText: 'Shipping / freight',
              prefixText: '₹ ',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
          ),
        ),
        const SizedBox(height: 12),
        AtriaFormFieldRow(
          first: TextFormField(
            controller: tcsRateController,
            decoration: const InputDecoration(
              labelText: 'TCS %',
              helperText: '0 for none',
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => onChanged(),
          ),
          second: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              tcsHint,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Round off grand total'),
          subtitle: const Text(
            'Round to the nearest rupee, as per Section 170',
          ),
          value: applyRoundOff,
          onChanged: onRoundOffChanged,
        ),
      ],
    );
  }
}

class _NotesSection extends StatelessWidget {
  const _NotesSection({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: 3,
      decoration: const InputDecoration(
        labelText: 'Message',
        hintText: 'Thank you for your business…',
      ),
    );
  }
}
