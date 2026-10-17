import '../../core/domain/gst_registration.dart';
import 'package:decimal/decimal.dart';

import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/gst.dart';
import '../../core/constants/units.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/item_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/printer/printer_service.dart';
import '../../core/services/barcode_labels.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_form_section.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/tax_mode_toggle.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Creates or edits an item. Pass [editId] to edit; leave it null to create.
class ItemEditorScreen extends ConsumerStatefulWidget {
  const ItemEditorScreen({super.key, this.editId, this.duplicateOfId});

  final String? editId;

  /// When set (and [editId] is null), the form opens pre-filled from that
  /// item's details but saves as a NEW item — the "add another like this"
  /// flow. Stock is deliberately not copied: the new item starts at zero.
  final String? duplicateOfId;

  @override
  ConsumerState<ItemEditorScreen> createState() => _ItemEditorScreenState();
}

class _ItemEditorScreenState extends ConsumerState<ItemEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _skuController = TextEditingController();
  final _salePriceController = TextEditingController();
  final _purchasePriceController = TextEditingController();
  final _wholesalePriceController = TextEditingController();
  final _mrpController = TextEditingController();
  final _cessRateController = TextEditingController();
  final _openingStockController = TextEditingController();
  final _lowStockController = TextEditingController();
  final _barcodeController = TextEditingController();
  final _descriptionController = TextEditingController();

  /// Owned by the [Autocomplete]; captured during build so we can read and
  /// validate the typed HSN/SAC value.
  TextEditingController? _hsnFieldController;

  ItemEntity? _existing;
  List<CategoryEntity> _categories = const [];
  List<UnitEntity> _customUnits = const [];

  bool _isService = false;
  String _stockType = 'tracked';
  String _unit = 'pcs';
  double _gstRate = 0;
  TaxMode _taxMode = TaxMode.exclusive;
  String? _categoryId;
  String _hsnInitial = '';

  bool _loading = true;
  bool _saving = false;
  bool _notFound = false;

  bool _dirty = false;
  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  bool get _isEditing => widget.editId != null;

  @override
  void initState() {
    super.initState();
    // NOTE: these listeners fire on EVERY text change, programmatic prefill
    // included; _load clears the dirty flag once prefill completes (the form
    // is a spinner until then, so no user input can be lost).
    for (final controller in [
      _nameController,
      _skuController,
      _salePriceController,
      _purchasePriceController,
      _wholesalePriceController,
      _mrpController,
      _cessRateController,
      _openingStockController,
      _lowStockController,
      _barcodeController,
      _descriptionController,
    ]) {
      controller.addListener(_markDirty);
    }
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _skuController.dispose();
    _salePriceController.dispose();
    _purchasePriceController.dispose();
    _wholesalePriceController.dispose();
    _mrpController.dispose();
    _cessRateController.dispose();
    _openingStockController.dispose();
    _lowStockController.dispose();
    _barcodeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }

    var item = widget.editId == null
        ? null
        : await repo.getById(widget.editId!);
    // A binned item must not open for editing: saving it would flip it live
    // again while no list shows it.
    if (item != null && item.isDeleted) item = null;
    final source = widget.duplicateOfId == null
        ? null
        : await repo.getById(widget.duplicateOfId!);
    final categories = await repo.categories(kind: 'item');
    final units = await repo.units();

    if (!mounted) return;
    setState(() {
      _categories = categories;
      _customUnits = units;
      _existing = item;
      if (item != null) {
        _prefill(item);
      } else if (source != null) {
        _prefillDuplicate(source);
      } else if (widget.editId != null || widget.duplicateOfId != null) {
        _notFound = true;
      }
      _loading = false;
    });
    // The initState listeners fired on every prefill `text =` assignment
    // above. The form is only interactive from here on, so nothing the user
    // typed can be lost by clearing the flag — and opening an item for
    // editing no longer starts out "dirty" (back then asked to discard
    // changes nobody made).
    _dirty = false;
  }

  /// Prefills for a duplicate: same details as [item], new name, zero stock
  /// and no dirty flag (nothing the user would lose by leaving).
  void _prefillDuplicate(ItemEntity item) {
    _prefill(item);
    _existing = null;
    _nameController.text = '${item.name} (copy)';
    // The source's SKU and barcode are CLEARED, not suffixed.
    //
    // `_save` runs an app-side uniqueness check over every live item, and this
    // is a new row (so nothing is excluded), so the inherited codes always
    // matched the source and the duplicate could never be saved — the button
    // was decoration. Clearing is right over "ABC-001 (copy)" because these
    // two are read off a physical label: a fabricated SKU misleads the next
    // person who types it, and a fabricated barcode prints and scans to
    // nothing. The user types the new variant's real codes.
    _skuController.text = '';
    _barcodeController.text = '';
    _openingStockController.text = '';
    _lowStockController.text = item.lowStockAlert == 0
        ? ''
        : _formatQty(item.lowStockAlert);
    _dirty = false;
  }

  void _prefill(ItemEntity item) {
    _existing = item;
    _nameController.text = item.name;
    _skuController.text = item.sku ?? '';
    _hsnInitial = item.hsn ?? '';
    _salePriceController.text = _formatAmount(item.salePrice);
    _purchasePriceController.text = _formatAmount(item.purchasePrice);
    _wholesalePriceController.text = item.wholesalePrice == null
        ? ''
        : _formatAmount(item.wholesalePrice!);
    _mrpController.text = item.mrp == null ? '' : _formatAmount(item.mrp!);
    _cessRateController.text = item.cessRate == 0
        ? ''
        : _formatAmount(item.cessRate);
    _openingStockController.text = item.openingStock == 0
        ? ''
        : _formatQty(item.openingStock);
    _lowStockController.text = item.lowStockAlert == 0
        ? ''
        : _formatQty(item.lowStockAlert);
    _barcodeController.text = item.barcode ?? '';
    _descriptionController.text = item.description ?? '';
    _gstRate = item.gstRate;
    _taxMode = item.taxMode == 'inclusive'
        ? TaxMode.inclusive
        : TaxMode.exclusive;
    _unit = item.unit;
    _isService = item.isService;
    _stockType = item.stockType;
    _categoryId = item.categoryId;
  }

  /// Groups digits the Indian way and drops ".0" for whole numbers.
  String _formatAmount(double value) {
    if (value == value.roundToDouble()) {
      return Formatters.indianGroup(value.toInt().toString());
    }
    return Formatters.number(Money.of(value));
  }

  String _formatQty(double value) => Formatters.qty(Money.of(value));

  // ---- Validators ---------------------------------------------------------

  String? _optionalAmount(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = Money.tryParse(value);
    if (parsed == null) return 'Enter a valid amount';
    if (parsed < Decimal.zero) return 'Amount cannot be negative';
    return null;
  }

  String? _optionalQty(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final parsed = Money.tryParse(value);
    if (parsed == null) return 'Enter a valid quantity';
    if (parsed < Decimal.zero) return 'Quantity cannot be negative';
    return null;
  }

  String? _optionalRate(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return Validators.gstRate(value);
  }

  // ---- Save ---------------------------------------------------------------

  Future<void> _save() async {
    // The form isn't built while the screen is still loading, so
    // `currentState` is null and validating it crashes.
    if (_loading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null || !mounted) return;

    if (_saving) return; // double-submit guard.

    setState(() => _saving = true);
    try {
      final taxModeLabel = _taxMode == TaxMode.inclusive
          ? 'inclusive'
          : 'exclusive';
      final name = _nameController.text.trim();
      final sku = _skuController.text.trim();
      final hsn = _hsnFieldController?.text.trim() ?? '';
      final barcode = _barcodeController.text.trim();
      final description = _descriptionController.text.trim();
      // Money.parse THROWS on malformed prices — a typo must never silently
      // become a ₹0 sale price. Validate before writing anything.
      final parsedSale = Money.tryParse(_salePriceController.text);
      final parsedPurchase = Money.tryParse(_purchasePriceController.text);
      if (parsedSale == null || parsedPurchase == null) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(
              content: Text('Sale and purchase price must be valid amounts.'),
            ),
          );
        }
        setState(() => _saving = false);
        return;
      }
      final salePrice = parsedSale.toDouble();
      final purchasePrice = parsedPurchase.toDouble();

      // Uniqueness checks, app-side: there is no database constraint on the
      // barcode or the SKU, so the editor is the last line of defence. A
      // duplicate breaks every lookup keyed on the code — a scan, an item
      // search, a report grouped by code — and does it silently. Blank codes
      // are exempt in both cases.
      final db = ref.read(appDatabaseProvider);
      if (barcode.isNotEmpty) {
        final clash =
            await (db.select(db.items)..where(
                  (t) =>
                      t.firmId.equals(repo.firmId) &
                      t.barcode.equals(barcode) &
                      t.isDeleted.equals(false),
                ))
                .get();
        final other = clash
            .where((r) => r.id != (_existing?.id ?? ''))
            .toList();
        if (other.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(
                  'Barcode $barcode is already used by "${other.first.name}".',
                ),
              ),
            );
          }
          setState(() => _saving = false);
          return;
        }
      }
      // SKU uniqueness, app-side: the same code on two items makes every
      // SKU-based lookup — the item search, a barcode-style pick, reports
      // grouped by code — ambiguous, and there is no database constraint to
      // catch it. Blank codes are exempt, and the comparison is case-insensitive
      // because SKUs are read off a label, not memorised.
      if (sku.isNotEmpty) {
        final clashSku =
            await (db.select(db.items)..where(
                  (t) =>
                      t.firmId.equals(repo.firmId) &
                      t.sku.lower().equals(sku.toLowerCase()) &
                      t.isDeleted.equals(false),
                ))
                .get();
        final otherSku = clashSku
            .where((r) => r.id != (_existing?.id ?? ''))
            .toList();
        if (otherSku.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(
                  'SKU $sku is already used by "${otherSku.first.name}".',
                ),
              ),
            );
          }
          setState(() => _saving = false);
          return;
        }
      }
      final cess = (Money.tryParse(_cessRateController.text) ?? Decimal.zero)
          .toDouble();
      final tracked = _stockType == 'tracked';
      final opening = tracked
          ? (Money.tryParse(_openingStockController.text) ?? Decimal.zero)
                .toDouble()
          : 0.0;
      final lowAlert = tracked
          ? (Money.tryParse(_lowStockController.text) ?? Decimal.zero)
                .toDouble()
          : 0.0;
      final wholesale = Money.tryParse(_wholesalePriceController.text)
          ?.toDouble();
      final mrp = Money.tryParse(_mrpController.text)?.toDouble();

      if (_existing == null) {
        await repo.create(
          name: name,
          sku: sku.isEmpty ? null : sku,
          hsn: hsn.isEmpty ? null : hsn,
          categoryId: _categoryId,
          unit: _unit,
          salePrice: salePrice,
          purchasePrice: purchasePrice,
          wholesalePrice: wholesale,
          mrp: mrp,
          gstRate: _gstRate,
          cessRate: cess,
          taxMode: taxModeLabel,
          isService: _isService,
          // Belt and braces for rows that were already tracked before the
          // toggle above started forcing services off.
          stockType: _isService ? 'untracked' : _stockType,
          openingStock: opening,
          lowStockAlert: lowAlert,
          barcode: barcode.isEmpty ? null : barcode,
          description: description.isEmpty ? null : description,
        );
      } else {
        await repo.update(
          _existing!.copyWith(
            name: name,
            sku: Value(sku.isEmpty ? null : sku),
            hsn: Value(hsn.isEmpty ? null : hsn),
            categoryId: Value(_categoryId),
            unit: _unit,
            salePrice: salePrice,
            purchasePrice: purchasePrice,
            wholesalePrice: Value(wholesale),
            mrp: Value(mrp),
            gstRate: _gstRate,
            cessRate: cess,
            taxMode: taxModeLabel,
            isService: _isService,
            stockType: _isService ? 'untracked' : _stockType,
            lowStockAlert: lowAlert,
            barcode: Value(barcode.isEmpty ? null : barcode),
            description: Value(description.isEmpty ? null : description),
          ),
        );
      }
      if (!mounted) return;
      // Clear before the pop: the guard would otherwise treat the just-saved
      // item as unsaved input and ask whether to discard it.
      _dirty = false;
      context.pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the item: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(itemRepositoryProvider);
    return SaveShortcut(
      enabled: !_loading && !_saving,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_saving,
        child: Scaffold(
          appBar: EditorAppBar(
            title: _isEditing ? 'Edit Item' : 'Add Item',
            // _loading is not saving — the spinner in the app bar used to
            // claim a save was in progress while the form was merely loading.
            saving: _saving,
            enabled: repo != null,
            onSave: _save,
            onExit: () => context.pop(),
            actions: [if (_isEditing) _printMenu()],
          ),
          // On a phone the app bar hands Save down here, where a thumb is.
          bottomNavigationBar: EditorBottomBar(onSave: _save, saving: _saving),
          body: _body(repo),
        ),
      ),
    );
  }

  /// The label menu: a thermal sticker, or the A4 sheet.
  ///
  /// Both outcomes are kept because they are different jobs — a shop with a
  /// TSC at the counter wants one instant sticker, and a shop with only an
  /// office printer wants a page of them to cut up. The thermal entry only
  /// appears once a printer exists, so the menu never offers something that
  /// cannot work.
  Widget _printMenu() {
    final printer = ref.watch(defaultPrinterProvider).valueOrNull;
    return PopupMenuButton<String>(
      tooltip: 'Print barcode labels',
      icon: const Icon(Icons.qr_code_2_rounded),
      enabled: _existing != null,
      onSelected: (value) => switch (value) {
        'thermal' => _printThermalLabels(),
        'sheet' => _printBarcodeLabels(),
        _ => null,
      },
      itemBuilder: (context) => [
        if (printer != null)
          PopupMenuItem(
            value: 'thermal',
            child: Text('Print to ${printer.name}'),
          ),
        const PopupMenuItem(
          value: 'sheet',
          child: Text('Print an A4 sheet of labels'),
        ),
      ],
    );
  }

  /// Sends one sticker straight to the configured thermal printer.
  ///
  /// Unlike the A4 path this does not go near a file: the printer's own language
  /// is sent as bytes, so the label is out before a PDF could have finished
  /// rendering.
  Future<void> _printThermalLabels() async {
    final existing = _existing;
    if (existing == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final printer = await ref.read(defaultPrinterProvider.future);
      if (printer == null) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text(
              'No label printer is set up. Add one under Settings → Label '
              'printers, then try again.',
            ),
          ),
        );
        return;
      }
      await ThermalPrinterService.print(printer, [
        ThermalPrinterService.labelForItem(existing, copies: printer.copies),
      ]);
      messenger?.showSnackBar(
        SnackBar(content: Text('Label sent to ${printer.name}.')),
      );
    } on LabelException catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Renders this item's barcode label sheet and opens it — Vyapar's barcode
  /// generator for a single product.
  Future<void> _printBarcodeLabels() async {
    final existing = _existing;
    if (existing == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final doc = await BarcodeLabels.build(items: [existing]);
      final bytes = await doc.save();
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory(p.join(dir.path, 'apexbooks', 'labels'));
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final file = File(
        p.join(
          outDir.path,
          'label_${sanitizeFileName(existing.sku ?? existing.id)}.pdf',
        ),
      );
      await file.writeAsBytes(bytes, flush: true);
      await OpenFilex.open(file.path);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not build labels: $error')),
      );
    }
  }

  Widget _body(ItemRepository? repo) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (repo == null) {
      return const EmptyState(
        icon: Icons.business_center_outlined,
        title: 'No firm selected',
        message: 'Choose or create a firm to start managing items.',
      );
    }
    if (_notFound) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        title: 'Item not found',
        message: 'This item may have been deleted from another device.',
      );
    }
    return _form();
  }

  /// Delete affordance for the item being edited. Hidden on create.
  ///
  /// [ItemRepository.delete] is a SOFT delete — it flips `isDeleted` and leaves
  /// the row (and every stock movement pointing at it) in place, so it cannot
  /// fail with the foreign-key error this copy used to warn about, and the
  /// `catch` in [_confirmDelete] below it could never fire. The copy now says
  /// what actually happens: the item leaves the catalogue and can be restored
  /// from the recycle bin.
  Widget _dangerZone() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Danger zone',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Moves this item out of your catalogue and into the '
                    'recycle bin, where you can restore it. Bills already '
                    'recorded keep their lines.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
              ),
              onPressed: _saving ? null : _confirmDelete,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Delete item'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete() async {
    final repo = ref.read(itemRepositoryProvider);
    final existing = _existing;
    if (repo == null || existing == null) return;
    // Resolved before the dialog: the `await` is an async gap, and a context
    // looked up afterwards can belong to a dead element.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete ${existing.name}?',
      message:
          'This moves the item out of your catalogue and into the '
          'recycle bin. Documents that already use it are not changed, and '
          'you can restore the item from the recycle bin at any time.',
    );
    if (confirmed != true) return;
    // No try/catch: `delete` is a two-column UPDATE inside a transaction, so
    // the only thing it can throw is a database-level failure that would have
    // already broken the editor. The old `catch` here claimed to handle a
    // foreign-key error this soft delete cannot raise.
    await repo.delete(existing.id);
    _dirty = false;
    navigator.pop();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Item deleted — restore it from the recycle bin'),
      ),
    );
  }

  Widget _form() {
    // The preview card is the page's header band (the same slot the invoice
    // gives its customer block); the three field groups sit two-up once the
    // window is wide enough, so a maximised window is not one long ribbon of
    // half-empty fields.
    return EditorShellBody(
      form: Form(
        key: _formKey,
        child: AtriaEditorForm(
          maxContentWidth: 1000,
          header: _previewCard(),
          sections: [
            AtriaFormSection(
              icon: Icons.label_outline_rounded,
              title: 'Item details',
              children: [
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Item name *',
                    hintText: 'e.g. Basmati Rice 1 kg',
                  ),
                  validator: (value) => Validators.name(value),
                ),
                const SizedBox(height: 12),
                AtriaFormFieldRow(
                  first: TextFormField(
                    controller: _skuController,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'SKU / code',
                      hintText: 'ABC-001',
                    ),
                  ),
                  second: _hsnField(),
                ),
                const SizedBox(height: 12),
                _typeToggle(),
                const SizedBox(height: 12),
                AtriaFormFieldRow(
                  first: _categoryField(),
                  second: TextFormField(
                    controller: _barcodeController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Barcode',
                      hintText: '8901234567890',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 3,
                  minLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Optional notes printed on the invoice',
                  ),
                ),
              ],
            ),
            AtriaFormSection(
              icon: Icons.point_of_sale_rounded,
              title: 'Pricing & tax',
              children: [
                AtriaFormFieldRow(
                  first: _salePriceCell(),
                  second: _moneyField(
                    _purchasePriceController,
                    'Purchase price',
                    Icons.shopping_cart_checkout_rounded,
                    validator: _optionalAmount,
                  ),
                ),
                const SizedBox(height: 12),
                AtriaFormFieldRow(
                  first: _moneyField(
                    _wholesalePriceController,
                    'Wholesale price',
                    Icons.storefront_outlined,
                    validator: _optionalAmount,
                  ),
                  second: _moneyField(
                    _mrpController,
                    'MRP',
                    Icons.local_offer_outlined,
                    validator: _optionalAmount,
                  ),
                ),
                const SizedBox(height: 12),
                if (ref.watch(activeFirmProvider).valueOrNull?.isGstRegistered == true) AtriaFormFieldRow(first: _gstField(), second: _cessField()),
                const SizedBox(height: 12),
                if (ref.watch(activeFirmProvider).valueOrNull?.isGstRegistered == true) _taxModeField(),
              ],
            ),
            AtriaFormSection(
              icon: Icons.inventory_2_outlined,
              title: 'Inventory',
              children: [
                _stockToggle(),
                const SizedBox(height: 12),
                _unitField(),
                const SizedBox(height: 12),
                _stockPair(),
              ],
            ),
          ],
          footer: _isEditing ? _dangerZone() : null,
        ),
      ),
    );
  }

  // ---- Fields -------------------------------------------------------------

  /// The sale-price field plus its below-cost advisory.
  ///
  /// The advisory was returned from the field's `validator`, which meant
  /// `Form.validate()` failed and `_save` returned — so a shop running a
  /// clearance or pricing a loss leader could not save the item at all, which
  /// is the opposite of what the comment beside it claimed. Selling below cost
  /// is a decision, not a mistake: it is now shown, not enforced.
  ///
  /// Rebuilt through [ListenableBuilder] on BOTH price controllers rather than
  /// `setState`, so typing a cost (or a price) updates the line without a full
  /// form rebuild — the same technique the preview card below already uses.
  Widget _salePriceCell() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _salePriceController,
        _purchasePriceController,
      ]),
      builder: (context, _) {
        final warning = _belowCostWarning(
          _salePriceController.text,
          _purchasePriceController.text,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _moneyField(
              _salePriceController,
              'Sale price *',
              Icons.point_of_sale_rounded,
              // A zero sale price IS a mistake — it becomes a free invoice, and
              // this list is where that would be repeated on every document.
              validator: (value) => Validators.amount(value, allowZero: false),
            ),
            if (warning != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: atriaColors(context).warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warning,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: atriaColors(context).warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  /// The advisory text when [sale] is under [cost], else null.
  ///
  /// A blank or zero cost is not a margin — an item whose cost was never
  /// entered must not be nagged about — so it produces no warning.
  String? _belowCostWarning(String sale, String cost) {
    final saleValue = Money.tryParse(sale);
    final costValue = Money.tryParse(cost);
    if (saleValue == null || costValue == null) return null;
    if (costValue <= Decimal.zero || saleValue >= costValue) return null;
    return 'Selling below cost (${Formatters.money(costValue)}). '
        'Allowed — the item will still be saved.';
  }

  Widget _moneyField(
    TextEditingController controller,
    String label,
    IconData icon, {
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: AtriaFieldIcon(icon),
        prefixText: '${AppConstants.currencySymbol} ',
      ),
      validator: validator ?? (value) => Validators.amount(value),
    );
  }

  Widget _hsnField() {
    return Autocomplete<HsnCode>(
      initialValue: TextEditingValue(text: _hsnInitial),
      optionsBuilder: (textEditingValue) =>
          HsnCodes.search(textEditingValue.text),
      displayStringForOption: (code) => code.code,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        // The Autocomplete owns this controller and disposes it with the
        // widget — we only borrow a reference for save; never dispose it
        // here (double-dispose crash) and don't hold a stale one.
        _hsnFieldController = controller;
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'HSN / SAC',
            hintText: 'Search code or description',
            prefixIcon: AtriaFieldIcon(Icons.search_rounded),
          ),
          validator: (value) => Validators.hsn(value),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        return Material(
          // The app's floating-panel surface, not a bare raised sheet: the
          // code list drops onto a white editor page, so it needs its own
          // hairline or its edge disappears (see [AppTheme.menuShape]).
          color: scheme.surface,
          elevation: AppTheme.menuElevation,
          surfaceTintColor: Colors.transparent,
          shape: AppTheme.menuShape(scheme),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final code in options)
                ListTile(
                  dense: true,
                  title: Text(
                    code.code,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  subtitle: Text(
                    code.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    Formatters.percent(code.gstRate),
                    style: text.labelSmall,
                  ),
                  onTap: () => onSelected(code),
                ),
            ],
          ),
        );
      },
      onSelected: (code) {
        _hsnFieldController?.text = code.code;
        setState(() => _gstRate = code.gstRate);
      },
    );
  }

  Widget _categoryField() {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem<String?>(value: null, child: Text('None')),
      for (final category in _categories)
        DropdownMenuItem<String?>(
          value: category.id,
          child: Text(category.name),
        ),
    ];
    if (_categoryId != null &&
        !_categories.any((category) => category.id == _categoryId)) {
      items.add(
        DropdownMenuItem<String?>(
          value: _categoryId,
          child: Text(_categoryId!),
        ),
      );
    }
    return DropdownButtonFormField<String?>(
      iconSize: AppIconSize.md,
      initialValue: _categoryId,
      decoration: const InputDecoration(
        labelText: 'Category',
        prefixIcon: AtriaFieldIcon(Icons.category_outlined),
      ),
      items: items,
      onChanged: (value) => setState(() {
        _categoryId = value;
        _dirty = true;
      }),
    );
  }

  Widget _gstField() {
    final rates = GstRate.standard.map((rate) => rate.rate).toList()..sort();
    if (!rates.contains(_gstRate)) rates.add(_gstRate);
    return DropdownButtonFormField<double>(
      iconSize: AppIconSize.md,
      // Re-created when the rate changes so the selection follows a rate
      // picked from the HSN/SAC autocomplete.
      key: ValueKey<double>(_gstRate),
      initialValue: _gstRate,
      decoration: const InputDecoration(
        labelText: 'GST rate',
        prefixIcon: AtriaFieldIcon(Icons.percent_rounded),
      ),
      items: [
        for (final rate in rates)
          DropdownMenuItem<double>(
            value: rate,
            child: Text(Formatters.percent(rate)),
          ),
      ],
      onChanged: (value) => setState(() {
        _gstRate = value ?? 0;
        _dirty = true;
      }),
    );
  }

  /// GST included / excluded for this item's price — was hard-wired to
  /// 'exclusive' on save with no UI to change it.
  Widget _taxModeField() {
    return TaxModeToggle(
      compact: false,
      value: _taxMode,
      onChanged: (mode) => setState(() {
        _taxMode = mode;
        _dirty = true;
      }),
    );
  }

  Widget _cessField() {
    return TextFormField(
      controller: _cessRateController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [IndianAmountInputFormatter(decimals: 2)],
      decoration: const InputDecoration(
        labelText: 'Cess rate',
        suffixText: '%',
        prefixIcon: AtriaFieldIcon(Icons.add_circle_outline_rounded),
      ),
      validator: _optionalRate,
    );
  }

  Widget _unitField() {
    final options = <_UnitOption>[
      for (final standard in Unit.standard)
        _UnitOption(standard.id, '${standard.symbol} · ${standard.label}'),
      for (final custom in _customUnits)
        _UnitOption(custom.id, '${custom.symbol} · ${custom.name}'),
    ];
    if (!options.any((option) => option.value == _unit)) {
      options.add(_UnitOption(_unit, Unit.symbolOf(_unit)));
    }
    return DropdownButtonFormField<String>(
      iconSize: AppIconSize.md,
      initialValue: _unit,
      // isExpanded: a DropdownButton sizes to its WIDEST item, so an
      // unexpanded one overflows the field on a phone.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Unit',
        prefixIcon: AtriaFieldIcon(Icons.straighten_rounded),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem<String>(
            value: option.value,
            child: Text(
              option.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (value) => setState(() {
        _unit = value ?? 'pcs';
        _dirty = true;
      }),
    );
  }

  /// A [SegmentedButton] does not shrink, so its icon is dropped on a phone
  /// where the two labelled segments would not fit across the section.
  Widget _typeToggle() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final icons = constraints.maxWidth >= 420;
        return _ToggleField(
          label: 'Item type',
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment<bool>(
                value: false,
                label: const Text('Goods'),
                icon: icons ? const Icon(Icons.inventory_2_outlined) : null,
              ),
              ButtonSegment<bool>(
                value: true,
                label: const Text('Service'),
                icon: icons ? const Icon(Icons.handshake_outlined) : null,
              ),
            ],
            selected: {_isService},
            onSelectionChanged: (selection) => setState(() {
              _isService = selection.first;
              // A service has no physical units to count, so tracking stock for
              // one leaves a frozen opening balance sitting in every stock total
              // forever — the movement writer already refuses to touch a
              // service, which is what makes the number misleading rather than
              // merely pointless.
              if (_isService) _stockType = 'untracked';
              _dirty = true;
            }),
          ),
        );
      },
    );
  }

  Widget _stockToggle() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final icons = constraints.maxWidth >= 420;
        // Read-only on a service: the value above already forced it off, so
        // leaving the control interactive would only let the user set a state
        // the save would have to discard again.
        return _ToggleField(
          label: 'Stock tracking',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment<String>(
                    value: 'tracked',
                    label: const Text('Tracked'),
                    icon: icons
                        ? const Icon(Icons.check_circle_outline_rounded)
                        : null,
                    enabled: !_isService,
                  ),
                  ButtonSegment<String>(
                    value: 'untracked',
                    label: const Text('Untracked'),
                    icon: icons
                        ? const Icon(Icons.do_not_disturb_alt_outlined)
                        : null,
                    enabled: !_isService,
                  ),
                ],
                selected: {_stockType},
                onSelectionChanged: (selection) => setState(() {
                  _stockType = selection.first;
                  _dirty = true;
                }),
              ),
              if (_isService)
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6),
                  child: Text(
                    'A service isn\'t counted in stock.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _stockPair() {
    final tracked = _stockType == 'tracked';
    return AtriaFormFieldRow(
      first: TextFormField(
        controller: _openingStockController,
        enabled: tracked && !_isEditing,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [IndianAmountInputFormatter(decimals: 3)],
        decoration: InputDecoration(
          labelText: 'Opening stock',
          prefixIcon: const AtriaFieldIcon(Icons.inventory_outlined),
          helperText: _isEditing ? 'Adjust via stock movements' : null,
        ),
        validator: _optionalQty,
      ),
      second: TextFormField(
        controller: _lowStockController,
        enabled: tracked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [IndianAmountInputFormatter(decimals: 3)],
        decoration: InputDecoration(
          labelText: 'Low stock alert',
          prefixIcon: const AtriaFieldIcon(Icons.notifications_active_outlined),
          helperText: tracked ? null : 'Requires stock tracking',
        ),
        validator: _optionalQty,
      ),
    );
  }

  /// The headline "what the customer pays for one" figure.
  ///
  /// It used to be `sale + sale * gstRate/100`, labelled "Selling price + 18%
  /// GST", unconditionally: on a tax-INCLUSIVE item the stored price already
  /// contains the GST, so the card overstated the price by the tax again (and
  /// the [TaxModeToggle] beside it changed nothing, because the number never
  /// read it). Cess was never applied at all, though it is an editable field.
  ///
  /// Computed by the same engine a document line goes through, so the card
  /// cannot drift from what the invoice will charge: in inclusive mode the
  /// engine back-calculates the taxable value out of the price and then adds
  /// the tax back, and it charges cess on the TAXABLE value in both modes.
  /// `intraState` because the split only moves tax between CGST/SGST/IGST — the
  /// grand total is identical either way.
  ({Decimal total, String label}) _previewHeadline() {
    final rate = Money.tryParse(_salePriceController.text) ?? Decimal.zero;
    final cess = (Money.tryParse(_cessRateController.text) ?? Decimal.zero)
        .toDouble();
    final registered = ref.read(activeFirmProvider).valueOrNull?.isGstRegistered == true;
    final inclusive = registered && _taxMode == TaxMode.inclusive;
    final totals = GstEngine.computeLine(
      TaxLine(
        id: 'preview',
        name: '',
        quantity: Decimal.one,
        unit: _unit,
        rate: rate,
        gstRate: registered ? _gstRate : 0,
        cessRate: registered ? cess : 0,
        taxMode: _taxMode,
      ),
      GstSplit.intraState,
    );
    final cessPart = cess > 0 ? ' + ${Formatters.percent(cess)} cess' : '';
    return (
      total: totals.total,
      label: !registered ? 'Selling price (no GST)' : inclusive
          ? 'Price incl. ${Formatters.percent(_gstRate)} GST$cessPart'
          : 'Selling price + ${Formatters.percent(_gstRate)} GST$cessPart',
    );
  }

  Widget _previewCard() {
    return ListenableBuilder(
      listenable: Listenable.merge([_salePriceController, _cessRateController]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final preview = _previewHeadline();

        return AtriaCard(
          background: scheme.primaryContainer,
          showBorder: false,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(AppRadius.sm),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.receipt_long_rounded,
                  color: scheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      preview.label,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withValues(
                          alpha: 0.85,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Formatters.money(preview.total),
                      style: text.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                'per ${Unit.symbolOf(_unit)}',
                style: text.bodySmall?.copyWith(
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A [SegmentedButton] with the same label treatment as a form field.
class _ToggleField extends StatelessWidget {
  const _ToggleField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _UnitOption {
  const _UnitOption(this.value, this.label);

  final String value;
  final String label;
}
