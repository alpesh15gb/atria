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
import '../../core/engine/gst_engine.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/item_repository.dart';
import '../../core/services/barcode_labels.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/tax_mode_toggle.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/save_shortcut.dart';
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
  void _markDirty() => _dirty = true;

  bool get _isEditing => widget.editId != null;

  @override
  void initState() {
    super.initState();
    // Listener fires on user keystrokes only, so prefilling an item being
    // edited does not trip the unsaved-changes guard.
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

    final item = widget.editId == null ? null : await repo.getById(widget.editId!);
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
  }

  /// Prefills for a duplicate: same details as [item], new name, zero stock
  /// and no dirty flag (nothing the user would lose by leaving).
  void _prefillDuplicate(ItemEntity item) {
    _prefill(item);
    _existing = null;
    _nameController.text = '${item.name} (copy)';
    _openingStockController.text = '';
    _lowStockController.text =
        item.lowStockAlert == 0 ? '' : _formatQty(item.lowStockAlert);
    _dirty = false;
  }

  void _prefill(ItemEntity item) {
    _existing = item;
    _nameController.text = item.name;
    _skuController.text = item.sku ?? '';
    _hsnInitial = item.hsn ?? '';
    _salePriceController.text = _formatAmount(item.salePrice);
    _purchasePriceController.text = _formatAmount(item.purchasePrice);
    _wholesalePriceController.text =
        item.wholesalePrice == null ? '' : _formatAmount(item.wholesalePrice!);
    _mrpController.text = item.mrp == null ? '' : _formatAmount(item.mrp!);
    _cessRateController.text =
        item.cessRate == 0 ? '' : _formatAmount(item.cessRate);
    _openingStockController.text =
        item.openingStock == 0 ? '' : _formatQty(item.openingStock);
    _lowStockController.text =
        item.lowStockAlert == 0 ? '' : _formatQty(item.lowStockAlert);
    _barcodeController.text = item.barcode ?? '';
    _descriptionController.text = item.description ?? '';
    _gstRate = item.gstRate;
    _taxMode =
        item.taxMode == 'inclusive' ? TaxMode.inclusive : TaxMode.exclusive;
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
      final taxModeLabel = _taxMode == TaxMode.inclusive ? 'inclusive' : 'exclusive';
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
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content: Text('Sale and purchase price must be valid amounts.'),
          ));
        }
        setState(() => _saving = false);
        return;
      }
      final salePrice = parsedSale.toDouble();
      final purchasePrice = parsedPurchase.toDouble();

      // Barcode uniqueness, app-side: the same code on two items breaks
      // every scan-based lookup silently. Blank/absent codes are exempt.
      if (barcode.isNotEmpty) {
        final db = ref.read(appDatabaseProvider);
        final clash = await (db.select(db.items)
              ..where((t) =>
                  t.firmId.equals(repo.firmId) &
                  t.barcode.equals(barcode) &
                  t.isDeleted.equals(false)))
            .get();
        final other = clash.where((r) => r.id != (_existing?.id ?? '')).toList();
        if (other.isNotEmpty) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text(
                  'Barcode $barcode is already used by "${other.first.name}".'),
            ));
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
          ? (Money.tryParse(_lowStockController.text) ?? Decimal.zero).toDouble()
          : 0.0;
      final wholesale = Money.tryParse(_wholesalePriceController.text)?.toDouble();
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
          stockType: _stockType,
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
            stockType: _stockType,
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
            actions: [
              if (_isEditing)
                IconButton(
                  tooltip: 'Print barcode labels',
                  icon: const Icon(Icons.qr_code_2_rounded),
                  onPressed: _existing == null ? null : _printBarcodeLabels,
                ),
            ],
          ),
          body: _body(repo),
        ),
      ),
    );
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
      final outDir = Directory(p.join(dir.path, 'atria', 'labels'));
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final file = File(p.join(outDir.path,
          'label_${existing.sku ?? existing.id}.pdf'));
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

  /// Delete affordance for the item being edited. Hidden on create; deleting
  /// fails with a FK error if the item is already used on a document, and
  /// that error is surfaced instead of crashing.
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
                  Text('Danger zone',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    'Deleting removes this item from your catalogue. Bills '
                    'already recorded keep their lines.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
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
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${existing.name}?'),
        content: const Text(
            'This removes the item from your catalogue. Documents that '
            'already use it are not changed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await repo.delete(existing.id);
      _dirty = false;
      navigator.pop();
      messenger?.showSnackBar(
        const SnackBar(content: Text('Item deleted')),
      );
    } catch (error) {
      messenger?.showSnackBar(SnackBar(
        content: Text('Could not delete the item: $error'),
      ));
    }
  }

  Widget _form() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _previewCard(),
                const SizedBox(height: 20),
                const SectionHeader(title: 'Item details'),
                TextFormField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Item name *',
                    hintText: 'e.g. Basmati Rice 1 kg',
                    prefixIcon: Icon(Icons.label_outline_rounded),
                  ),
                  validator: (value) => Validators.name(value),
                ),
                const SizedBox(height: 12),
                _FieldRow(
                  first: TextFormField(
                    controller: _skuController,
                    textCapitalization: TextCapitalization.characters,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'SKU / code',
                      hintText: 'ABC-001',
                      prefixIcon: Icon(Icons.qr_code_2_outlined),
                    ),
                  ),
                  second: _hsnField(),
                ),
                const SizedBox(height: 12),
                _typeToggle(),
                const SizedBox(height: 12),
                _FieldRow(
                  first: _categoryField(),
                  second: TextFormField(
                    controller: _barcodeController,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Barcode',
                      hintText: '8901234567890',
                      prefixIcon: Icon(Icons.barcode_reader),
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
                const SizedBox(height: 24),
                const SectionHeader(title: 'Pricing & tax'),
                _FieldRow(
                  first: _moneyField(
                    _salePriceController,
                    'Sale price *',
                    Icons.point_of_sale_rounded,
                  ),
                  second: _moneyField(
                    _purchasePriceController,
                    'Purchase price',
                    Icons.shopping_cart_checkout_rounded,
                    validator: _optionalAmount,
                  ),
                ),
                const SizedBox(height: 12),
                _FieldRow(
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
                _FieldRow(first: _gstField(), second: _cessField()),
                const SizedBox(height: 12),
                _taxModeField(),
                const SizedBox(height: 24),
                const SectionHeader(title: 'Inventory'),
                _stockToggle(),
                const SizedBox(height: 12),
                _unitField(),
                const SizedBox(height: 12),
                _stockPair(),
                if (_isEditing) ...[
                  const SizedBox(height: 32),
                  _dangerZone(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Fields -------------------------------------------------------------

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
        prefixIcon: Icon(icon),
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
            prefixIcon: Icon(Icons.search_rounded),
          ),
          validator: (value) => Validators.hsn(value),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final text = Theme.of(context).textTheme;
        return Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 4,
          borderRadius:
              const BorderRadius.all(Radius.circular(AppRadius.md)),
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
        DropdownMenuItem<String?>(value: category.id, child: Text(category.name)),
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
      initialValue: _categoryId,
      decoration: const InputDecoration(
        labelText: 'Category',
        prefixIcon: Icon(Icons.category_outlined),
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
      // Re-created when the rate changes so the selection follows a rate
      // picked from the HSN/SAC autocomplete.
      key: ValueKey<double>(_gstRate),
      initialValue: _gstRate,
      decoration: const InputDecoration(
        labelText: 'GST rate',
        prefixIcon: Icon(Icons.percent_rounded),
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
        prefixIcon: Icon(Icons.add_circle_outline_rounded),
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
      initialValue: _unit,
      decoration: const InputDecoration(
        labelText: 'Unit',
        prefixIcon: Icon(Icons.straighten_rounded),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem<String>(
            value: option.value,
            child: Text(option.label),
          ),
      ],
      onChanged: (value) => setState(() {
        _unit = value ?? 'pcs';
        _dirty = true;
      }),
    );
  }

  Widget _typeToggle() {
    return _ToggleField(
      label: 'Item type',
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment<bool>(
            value: false,
            label: Text('Goods'),
            icon: Icon(Icons.inventory_2_outlined),
          ),
          ButtonSegment<bool>(
            value: true,
            label: Text('Service'),
            icon: Icon(Icons.handshake_outlined),
          ),
        ],
        selected: {_isService},
        onSelectionChanged: (selection) => setState(() {
          _isService = selection.first;
          _dirty = true;
        }),
      ),
    );
  }

  Widget _stockToggle() {
    return _ToggleField(
      label: 'Stock tracking',
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment<String>(
            value: 'tracked',
            label: Text('Tracked'),
            icon: Icon(Icons.check_circle_outline_rounded),
          ),
          ButtonSegment<String>(
            value: 'untracked',
            label: Text('Untracked'),
            icon: Icon(Icons.do_not_disturb_alt_outlined),
          ),
        ],
        selected: {_stockType},
        onSelectionChanged: (selection) => setState(() {
          _stockType = selection.first;
          _dirty = true;
        }),
      ),
    );
  }

  Widget _stockPair() {
    final tracked = _stockType == 'tracked';
    return _FieldRow(
      first: TextFormField(
        controller: _openingStockController,
        enabled: tracked && !_isEditing,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [IndianAmountInputFormatter(decimals: 3)],
        decoration: InputDecoration(
          labelText: 'Opening stock',
          prefixIcon: const Icon(Icons.inventory_outlined),
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
          prefixIcon: const Icon(Icons.notifications_active_outlined),
          helperText: tracked ? null : 'Requires stock tracking',
        ),
        validator: _optionalQty,
      ),
    );
  }

  Widget _previewCard() {
    return ListenableBuilder(
      listenable: _salePriceController,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final text = Theme.of(context).textTheme;
        final sale = Money.tryParse(_salePriceController.text) ?? Decimal.zero;
        final total = sale + Money.mulN(sale, _gstRate / 100);

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
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.sm)),
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
                      'Selling price + ${Formatters.percent(_gstRate)} GST',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Formatters.money(total),
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
