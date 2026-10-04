import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart' show DocSequence;
import '../../core/database/repositories/party_repository.dart';
import '../../core/database/repositories/sales_repository.dart'
    show SalesDraft, SalesLineDraft;
import '../../core/engine/gst_engine.dart';
import '../../core/printer/printer_service.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_utils.dart';
import '../../core/utils/money.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';

/// The counter screen: scan, take the money, print the labels.
///
/// This is deliberately **not** a second way to write an invoice. It builds the
/// same `SalesDraft` the sale editor builds and hands it to the same
/// `SalesRepository.save`, so the GST split, the round-off, the document
/// numbering, the stock deduction and the party balance all come out identical
/// to a bill raised at a desk. Everything here is about speed at the counter —
/// one search field that takes a scan, a keyboard-driven cart, and the totals
/// recomputed on every keystroke.
class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  /// Declared here rather than spelled out in the router, so the "set up a
  /// printer" link inside this screen and the route itself cannot drift apart.
  static const String routePath = '/pos';

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

/// One line in the cart. Holds the item rather than a copy of its fields, so a
/// price edited at the counter is a property of this sale and not of the
/// catalogue.
class _CartLine {
  _CartLine({required this.item, Decimal? quantity, Decimal? rate})
    : quantity = quantity ?? Decimal.one,
      rate = rate ?? _rateOf(item);

  final ItemEntity item;
  Decimal quantity;
  Decimal rate;

  static Decimal _rateOf(ItemEntity item) =>
      Decimal.parse(item.salePrice.toStringAsFixed(2));

  Decimal get amount => quantity * rate;

  _CartLine copyWith({Decimal? quantity, Decimal? rate}) => _CartLine(
    item: item,
    quantity: quantity ?? this.quantity,
    rate: rate ?? this.rate,
  );
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  final List<_CartLine> _lines = [];
  List<ItemEntity> _matches = const [];
  bool _searching = false;

  /// Monotonic token for [_submitSearch], so a slow lookup cannot land after a
  /// newer one.
  ///
  /// A hardware wedge is a keyboard that types a code and presses Enter, and a
  /// busy till scans faster than SQLite answers: two scans inside one round-trip
  /// used to resolve in whatever order the database returned them, and the
  /// *first* issued scan could add its SKU last — into a cart the operator had
  /// already moved on from, with the search box cleared by the newer result so
  /// there was nothing on screen to notice. Every in-flight search stamps
  /// itself with this counter before its `await` and drops its result — and
  /// the spinner — if a newer search has been issued since.
  int _searchGeneration = 0;

  PartyEntity? _party;
  bool _fullyPaid = true;
  String _mode = 'cash';
  bool _printLabels = true;
  bool _busy = false;

  /// The last completed sale, so the operator can reprint its labels without
  /// retyping the cart — the common case when a scanner was the thing that
  /// failed.
  ({String number, String id, List<_CartLine> lines})? _lastSale;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ---- Pricing -----------------------------------------------------------

  /// The GST split, resolved exactly as the sale editor resolves it.
  ///
  /// A walk-in counter customer has no address, and an unregistered buyer has
  /// no GSTIN to place: both are local, because taxing them as inter-state
  /// would put IGST on a bill the firm cannot justify.
  GstSplit get _split {
    final firm = ref.read(activeFirmProvider).valueOrNull;
    final party = _party;
    if (firm == null || party == null || party.stateCode == null) {
      return GstSplit.intraState;
    }
    if ((firm.gstin ?? '').isEmpty || (party.gstin ?? '').isEmpty) {
      return GstSplit.intraState;
    }
    return party.stateCode != firm.stateCode
        ? GstSplit.interState
        : GstSplit.intraState;
  }

  /// Live totals, from the same engine the save uses — so what the customer is
  /// told and what is written cannot disagree.
  GstResult get _totals => GstEngine.computeDocument(
    lines: [for (final line in _lines) _draftFor(line).toTaxLine()],
    split: _split,
    applyRoundOff: true,
  );

  SalesLineDraft _draftFor(_CartLine line) => SalesLineDraft(
    id: IdUtils.newId(),
    itemId: line.item.id,
    name: line.item.name,
    hsn: line.item.hsn,
    quantity: line.quantity,
    unit: line.item.unit,
    rate: line.rate,
    gstRate: line.item.gstRate,
    cessRate: line.item.cessRate,
    taxMode: _taxModeOf(line.item),
  );

  static TaxMode _taxModeOf(ItemEntity item) => TaxMode.values.firstWhere(
    (mode) => mode.name == item.taxMode,
    orElse: () => TaxMode.exclusive,
  );

  // ---- Cart --------------------------------------------------------------

  /// Adds an item, or bumps the quantity when it is already in the cart.
  ///
  /// Accumulating rather than appending a second row is what a counter
  /// expects: scanning the same tin three times should read "3 pcs", not three
  /// identical lines.
  void _add(ItemEntity item, {Decimal? quantity}) {
    final existing = _lines.indexWhere((line) => line.item.id == item.id);
    setState(() {
      _matches = const [];
      if (existing == -1) {
        _lines.add(_CartLine(item: item, quantity: quantity ?? Decimal.one));
      } else {
        _lines[existing] = _lines[existing].copyWith(
          quantity: _lines[existing].quantity + (quantity ?? Decimal.one),
        );
      }
      _search.clear();
    });
    _searchFocus.requestFocus();
  }

  /// Removes one line, and can be taken back.
  ///
  /// WHY a snackbar and not a confirmation: see [_undoableRemoval].
  void _remove(int index) {
    if (index < 0 || index >= _lines.length) return;
    final line = _lines[index];
    setState(() => _lines.removeAt(index));
    _undoableRemoval('${line.item.name} removed from the cart.', line, index);
  }

  /// Speed versus safety at the till.
  ///
  /// A counter sale is a queue of customers, so a *line* action has to be
  /// immediate: an operator correcting a mis-scan must not have to answer a
  /// dialog, or they stop correcting and bill the wrong thing. The safety net
  /// is therefore undo — one snackbar action, no extra tap, and the line goes
  /// back where it was.
  ///
  /// [_clearCart] is the exception and the only dialog on this screen: it
  /// throws away the party, the paid/unpaid switch and every line at once, and
  /// there is nothing to scroll back to once it is gone. One deliberate
  /// question is the right price there; one per line would not be.
  void _undoableRemoval(String message, _CartLine line, int index) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              // The snackbar outlives a route pop — the counter screen can be
              // gone by the time four seconds have passed.
              if (!mounted) return;
              setState(() {
                // The cart may have grown or shrunk since; put the line back
                // as close to where it was as the current contents allow.
                _lines.insert(index.clamp(0, _lines.length), line);
              });
            },
          ),
        ),
      );
  }

  /// Wipes the whole cart — the one genuinely destructive action here, and the
  /// one that asks first. Nothing is billed yet, so no document is affected;
  /// what is lost is the keyed-in cart.
  Future<void> _clearCart() async {
    if (_lines.isEmpty) return;
    final lineCount = _lines.length;
    final partyName = _party?.name;
    final confirmed = await confirmDestructive(
      context,
      title: 'Clear the cart?',
      message:
          'This removes $lineCount line${lineCount == 1 ? '' : 's'}'
          '${partyName == null ? '' : ' and the customer “$partyName”'}. '
          'Nothing has been billed, so no document changes — but the whole cart '
          'has to be keyed in again.',
      confirmLabel: 'Clear it',
      cancelLabel: 'Keep the cart',
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _lines.clear();
      _party = null;
      _fullyPaid = true;
    });
  }

  /// Sets a line's quantity directly — the stepper buttons' path, kept
  /// separate from the edit dialog so neither has to know about the other.
  void _setQuantity(int index, Decimal quantity) {
    if (index < 0 || index >= _lines.length) return;
    if (quantity <= Decimal.zero) {
      // Stepping the last unit down to zero IS a removal — same fate, same
      // recovery. It used to delete the row outright with no way back, from
      // the one control a thumb lands on by accident.
      _remove(index);
      return;
    }
    setState(() {
      final current = _lines[index];
      _lines[index] = _CartLine(
        item: current.item,
        quantity: quantity,
        rate: current.rate,
      );
    });
  }

  Future<void> _editLine(int index) async {
    final line = _lines[index];
    final quantity = TextEditingController(text: _trimDecimal(line.quantity));
    final rate = TextEditingController(text: line.rate.toStringAsFixed(2));
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(line.item.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: quantity,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Quantity',
                suffixText: 'or 1.5 kg',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: rate,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Rate',
                helperText: 'Overrides the catalogue price for this sale only',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    final newQuantity = Money.tryParse(quantity.text);
    final newRate = Money.tryParse(rate.text);
    quantity.dispose();
    rate.dispose();
    if (saved != true) return;
    setState(() {
      final current = _lines[index];
      _lines[index] = _CartLine(
        item: current.item,
        quantity: newQuantity == null || newQuantity <= Decimal.zero
            ? current.quantity
            : newQuantity,
        rate: newRate == null || newRate < Decimal.zero
            ? current.rate
            : newRate,
      );
    });
  }

  // ---- Search and scan ---------------------------------------------------

  /// Handles `Enter` in the search box — the path a barcode scanner uses.
  ///
  /// A scanner is a keyboard that types the code and presses Enter, so an
  /// exact match on the barcode (then the SKU, then the name) has to win
  /// outright. Getting this order wrong is what makes a scan land on the wrong
  /// product whenever two items share a word.
  Future<void> _submitSearch(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    final items = ref.read(itemRepositoryProvider);
    if (items == null) return;

    // Stamped BEFORE the await, so a result that arrives late can tell it has
    // been superseded.
    final generation = ++_searchGeneration;
    setState(() => _searching = true);
    try {
      final candidates = await items.all(search: query);
      // Superseded (or gone): a newer scan owns the cart and the spinner now.
      if (!mounted || generation != _searchGeneration) return;
      if (candidates.isEmpty) {
        setState(() {
          _matches = const [];
          _searching = false;
        });
        _snack('No item matches "$query".');
        return;
      }
      final lowered = query.toLowerCase();
      final exact = candidates.where(
        (item) =>
            (item.barcode ?? '').toLowerCase() == lowered ||
            (item.sku ?? '').toLowerCase() == lowered,
      );
      final chosen = exact.isNotEmpty ? exact.first : candidates.first;
      if (exact.isNotEmpty || candidates.length == 1) {
        _add(chosen);
      } else {
        setState(() {
          _matches = candidates.take(8).toList();
          _searching = false;
        });
      }
    } finally {
      // Only the newest search may clear the spinner: a discarded result
      // stopping it would leave the search that IS running with no indicator.
      if (mounted && generation == _searchGeneration) {
        setState(() => _searching = false);
      }
    }
  }

  // ---- Party -------------------------------------------------------------

  Future<void> _pickParty() async {
    final parties = ref.read(partyRepositoryProvider);
    if (parties == null) return;
    final chosen = await showModalBottomSheet<PartyEntity>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _PartyPicker(repository: parties),
    );
    if (chosen == null) return;
    setState(() => _party = chosen.id.isEmpty ? null : chosen);
  }

  // ---- Completing the sale ----------------------------------------------

  Future<void> _complete() async {
    if (_lines.isEmpty || _busy) return;
    final firm = ref.read(activeFirmProvider).valueOrNull;
    final sales = ref.read(salesRepositoryProvider);
    if (firm == null || sales == null) {
      _snack('No firm is open — open your books first.');
      return;
    }
    final party = _party;
    if (party != null &&
        (party.gstin ?? '').isNotEmpty &&
        party.gstType == 'unregistered') {
      _snack('${party.name} has a GSTIN but is marked unregistered.');
    }

    setState(() => _busy = true);
    final lines = List<_CartLine>.of(_lines);
    try {
      final date = DateTime.now();
      final number = await ref
          .read(firmRepositoryProvider)
          .nextNumber(firm, DocSequence.invoice, date: date);
      final invoiceId = IdUtils.newId();

      final draft = SalesDraft(
        id: invoiceId,
        number: number,
        docType: 'invoice',
        partyId: party == null || party.id.isEmpty ? null : party.id,
        invoiceDate: date,
        dueDate: date,
        status: 'confirmed',
        lines: [for (final line in lines) _draftFor(line)],
        partyName: party?.name,
        partyGstin: party?.gstin,
        partyGstType: party?.gstType,
        partyPhone: party?.phone,
        placeOfSupply: party?.stateCode,
        isInterState: _split == GstSplit.interState,
        applyRoundOff: true,
        terms: firm.invoiceTerms,
        sequence: 0,
      );

      try {
        await sales.save(draft);
      } on Object catch (error) {
        // Nothing was written: the sale itself failed, so the cart stays
        // exactly as it was for a retry.
        if (mounted) _snack('Could not complete the sale: $error');
        return;
      }

      // The invoice is committed now; nothing below can un-save it. Settling
      // and printing are after the fact, so a failure there must not be
      // reported as "could not complete the sale" with the cart still full —
      // the operator would press Complete and bill the same goods twice.
      String? settleError;
      try {
        // Settling in the same motion is what makes this a counter sale: the
        // money is in the drawer before the customer walks off. The amount is
        // read back from the saved row so round-off is included rather than the
        // pre-rounding figure the cart was showing.
        if (_fullyPaid) {
          final payments = ref.read(paymentRepositoryProvider);
          final saved = await sales.getById(invoiceId);
          final due = saved?.balanceDue ?? 0.0;
          if (payments != null && due > 0.001) {
            final paymentNumber = await ref
                .read(firmRepositoryProvider)
                .nextNumber(firm, DocSequence.paymentIn, date: date);
            await payments.create(
              type: 'payment_in',
              number: paymentNumber,
              partyId: party == null || party.id.isEmpty ? null : party.id,
              partyName: party?.name,
              amount: due,
              date: date,
              mode: _mode,
              linkedInvoiceId: invoiceId,
              linkedInvoiceNumber: number,
              onLinked: (id, amount) =>
                  sales.applyPayment(invoiceId: id, amount: amount),
            );
          }
        }
      } on Object catch (error) {
        settleError = 'the payment was not recorded: $error';
      }

      // The cart is cleared the moment the bill is written, whatever happened
      // to the label or the settlement: the sale exists, so the goods are no
      // longer the operator's to sell again from this cart.
      if (!mounted) return;
      setState(() {
        _lastSale = (number: number, id: invoiceId, lines: lines);
        _lines.clear();
        _party = null;
        _fullyPaid = true;
      });
      _searchFocus.requestFocus();

      String? printed;
      // A printer fault that is not a [LabelException] used to escape to the
      // outer catch and leave the cart full for the same reason.
      String? printError = settleError;
      try {
        printed = await _printFor(lines);
      } on LabelException catch (error) {
        printError = printError == null
            ? 'the label did not print: ${error.message}'
            : '$printError; the label did not print: ${error.message}';
      } on Object catch (error) {
        printError = printError == null
            ? 'the label did not print: $error'
            : '$printError; the label did not print: $error';
      }
      _snack(
        printError != null
            ? 'Saved $number, but $printError.'
            : printed == null
            ? 'Saved $number.'
            : 'Saved $number · $printed',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprintLast() async {
    final last = _lastSale;
    if (last == null) return;
    setState(() => _busy = true);
    try {
      final printed = await _printFor(last.lines);
      if (mounted && printed != null) {
        _snack('Reprinted labels for ${last.number}.');
      }
    } on LabelException catch (error) {
      _snack(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Prints one label per unit sold, and returns what was sent.
  ///
  /// Only *stock-tracked* lines get a label: a service has nothing to stick a
  /// barcode on, and a shop's "Installation Service" line producing a sticker
  /// is noise, not a feature.
  Future<String?> _printFor(List<_CartLine> lines) async {
    if (!_printLabels) return null;

    final labels = <LabelDocument>[];
    for (final line in lines) {
      if (line.item.stockType != 'tracked') continue;
      labels.add(
        ThermalPrinterService.labelForSaleLine(
          line.item,
          quantity: _decimalToNum(line.quantity),
        ),
      );
    }
    if (labels.isEmpty) return null;

    // Only resolved once there is something to print, so a sale with no
    // tracked lines is not mistaken for a printer problem. `defaultPrinter`
    // skips any profile this device cannot actually use — a USB queue carried
    // over from a desktop install, say — so on Android a missing profile is a
    // real outcome, and swallowing it here quietly discarded the operator's
    // "print labels" tick while the sale reported success.
    final profile = await ref.read(defaultPrinterProvider.future);
    if (profile == null) {
      throw const LabelException(
        'labels were requested but no printer is set up for this device. '
        'Add one in Settings, then print again.',
      );
    }

    final total = labels.fold<int>(0, (sum, label) => sum + label.copies);
    if (total > 200) {
      throw LabelException(
        'That would print $total labels, which is almost certainly not what '
        'you meant. Turn label printing off for this sale, or split it.',
      );
    }
    await ThermalPrinterService.print(profile, labels);
    return '$total label${total == 1 ? '' : 's'} sent to ${profile.name}';
  }

  static num _decimalToNum(Decimal value) => value.toDouble();

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final printer = ref.watch(defaultPrinterProvider).valueOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Counter sale'),
        // The rail does not reach this screen and `go` left nothing to pop, so
        // the AppBar owns the way out. See [AtriaExitButton].
        leading: const AtriaExitButton(tooltip: 'Leave the counter'),
        actions: [
          if (_lastSale != null && printer != null)
            TextButton.icon(
              onPressed: _busy ? null : _reprintLast,
              icon: const Icon(PhosphorIconsRegular.printer, size: 18),
              label: Text('Reprint ${_lastSale!.number}'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: CallbackShortcuts(
        // F2 to scan the next item, F4 to complete — the two keys a counter
        // operator's hands already know from the desktop suites.
        bindings: {
          const SingleActivator(LogicalKeyboardKey.f2): () =>
              _searchFocus.requestFocus(),
          const SingleActivator(LogicalKeyboardKey.f4): _complete,
        },
        child: Focus(
          autofocus: true,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final cart = _CartPane(
                  search: _search,
                  searchFocus: _searchFocus,
                  searching: _searching,
                  matches: _matches,
                  lines: _lines,
                  onSubmitted: _submitSearch,
                  onAdd: _add,
                  onEdit: _editLine,
                  onRemove: _remove,
                  onSetQuantity: _setQuantity,
                  onClear: _clearCart,
                  busy: _busy,
                );
                final side = _TotalsPane(
                  totals: _totals,
                  lineCount: _lines.length,
                  party: _party,
                  onPickParty: _pickParty,
                  onClearParty: () => setState(() => _party = null),
                  fullyPaid: _fullyPaid,
                  onFullyPaidChanged: (value) =>
                      setState(() => _fullyPaid = value),
                  mode: _mode,
                  onModeChanged: (value) => setState(() => _mode = value),
                  printLabels: _printLabels,
                  onPrintLabelsChanged: (value) =>
                      setState(() => _printLabels = value),
                  printerName: printer?.name,
                  busy: _busy,
                  onComplete: _complete,
                );
                if (!wide) {
                  // The pane is taller than a short phone's body — party, tax
                  // breakdown, two switches, the payment mode and the Complete
                  // button do not all fit below the cart. Left at its natural
                  // height it takes ~570px of a 640px screen and squeezes the
                  // cart to a sliver, so it is bounded to a little over half
                  // the body and scrolls to reach the rest.
                  final paneHeight = constraints.maxHeight * 0.55;
                  return Column(
                    children: [
                      Expanded(child: cart),
                      const Divider(height: 1),
                      SizedBox(height: paneHeight, child: side),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: cart),
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 380,
                      child: SingleChildScrollView(child: side),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _CartPane extends StatelessWidget {
  const _CartPane({
    required this.search,
    required this.searchFocus,
    required this.searching,
    required this.matches,
    required this.lines,
    required this.onSubmitted,
    required this.onAdd,
    required this.onEdit,
    required this.onRemove,
    required this.onSetQuantity,
    required this.onClear,
    required this.busy,
  });

  final TextEditingController search;
  final FocusNode searchFocus;
  final bool searching;
  final List<ItemEntity> matches;
  final List<_CartLine> lines;
  final ValueChanged<String> onSubmitted;
  final ValueChanged<ItemEntity> onAdd;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onRemove;

  /// Sets a line's quantity outright, for the stepper buttons.
  final void Function(int index, Decimal quantity) onSetQuantity;
  final VoidCallback onClear;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: search,
            focusNode: searchFocus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: onSubmitted,
            decoration: InputDecoration(
              hintText: 'Scan a barcode, or type an item name or code',
              prefixIcon: const Icon(PhosphorIconsRegular.barcode),
              suffixIcon: searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (matches.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: AppRadius.mdAll,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in matches)
                  ListTile(
                    dense: true,
                    title: Text(item.name),
                    subtitle: Text(_itemSubtitle(item)),
                    trailing: Text(Formatters.money(_priceOf(item))),
                    onTap: () => onAdd(item),
                  ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text('Cart', style: text.titleSmall),
              const SizedBox(width: 8),
              Text(
                '${lines.length} line${lines.length == 1 ? '' : 's'}',
                style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
              const Spacer(),
              if (lines.isNotEmpty)
                TextButton.icon(
                  onPressed: busy ? null : onClear,
                  icon: const Icon(PhosphorIconsRegular.trash, size: 16),
                  label: const Text('Clear'),
                ),
            ],
          ),
        ),
        Expanded(
          child: lines.isEmpty
              ? const EmptyState(
                  icon: PhosphorIconsRegular.barcode,
                  title: 'Nothing in the cart yet',
                  message:
                      'Scan an item, or search for it above and press '
                      'Enter. The bill is written when you complete the sale.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: lines.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    return _CartRow(
                      line: line,
                      onEdit: () => onEdit(index),
                      onRemove: () => onRemove(index),
                      onStep: busy
                          ? null
                          : (delta) =>
                                onSetQuantity(index, line.quantity + delta),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static Decimal _priceOf(ItemEntity item) =>
      Decimal.parse(item.salePrice.toStringAsFixed(2));

  static String _itemSubtitle(ItemEntity item) {
    final parts = <String>[];
    final sku = item.sku?.trim() ?? '';
    if (sku.isNotEmpty) parts.add(sku);
    final barcode = item.barcode?.trim() ?? '';
    if (barcode.isNotEmpty) parts.add(barcode);
    parts.add(
      '${_trimDecimal(Decimal.parse(item.currentStock.toStringAsFixed(2)))} in stock',
    );
    return parts.join(' · ');
  }
}

class _CartRow extends StatelessWidget {
  const _CartRow({
    required this.line,
    required this.onEdit,
    required this.onRemove,
    required this.onStep,
  });

  final _CartLine line;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final ValueChanged<Decimal>? onStep;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: onEdit,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(line.item.name, style: text.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    '${Formatters.money(line.rate)} × ${_trimDecimal(line.quantity)} '
                    '${line.item.unit}'
                    '${line.item.gstRate > 0 ? ' · GST ${line.item.gstRate}%' : ''}',
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onStep == null ? null : () => onStep!(-Decimal.one),
            icon: const Icon(PhosphorIconsRegular.minus, size: 18),
            tooltip: 'One less',
          ),
          IconButton(
            onPressed: onStep == null ? null : () => onStep!(Decimal.one),
            icon: const Icon(PhosphorIconsRegular.plus, size: 18),
            tooltip: 'One more',
          ),
          SizedBox(
            width: 96,
            child: Text(
              Formatters.money(line.amount),
              textAlign: TextAlign.right,
              style: text.bodyMedium,
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(PhosphorIconsRegular.x, size: 18),
            tooltip: 'Remove',
          ),
        ],
      ),
    );
  }
}

class _TotalsPane extends StatelessWidget {
  const _TotalsPane({
    required this.totals,
    required this.lineCount,
    required this.party,
    required this.onPickParty,
    required this.onClearParty,
    required this.fullyPaid,
    required this.onFullyPaidChanged,
    required this.mode,
    required this.onModeChanged,
    required this.printLabels,
    required this.onPrintLabelsChanged,
    required this.printerName,
    required this.busy,
    required this.onComplete,
  });

  final GstResult totals;
  final int lineCount;
  final PartyEntity? party;
  final VoidCallback onPickParty;
  final VoidCallback onClearParty;
  final bool fullyPaid;
  final ValueChanged<bool> onFullyPaidChanged;
  final String mode;
  final ValueChanged<String> onModeChanged;
  final bool printLabels;
  final ValueChanged<bool> onPrintLabelsChanged;
  final String? printerName;
  final bool busy;
  final VoidCallback onComplete;

  static const List<(String, String)> _modes = [
    ('cash', 'Cash'),
    ('upi', 'UPI'),
    ('card', 'Card'),
    ('bank_transfer', 'Bank transfer'),
    ('cheque', 'Cheque'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        // The pane is taller than the screen on a short phone — party, the
        // tax breakdown, two switches, the payment mode and the button do not
        // all fit below the cart. Scrolling keeps every control reachable
        // instead of pushing the Complete button off the bottom and out of
        // reach, which is the one control the whole screen exists for.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Customer',
              style: text.labelMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            if (party == null)
              OutlinedButton.icon(
                onPressed: onPickParty,
                icon: const Icon(PhosphorIconsRegular.userPlus, size: 18),
                label: const Text('Walk-in customer'),
              )
            else
              OutlinedButton.icon(
                onPressed: onPickParty,
                icon: const Icon(PhosphorIconsRegular.user, size: 18),
                label: Text(party!.name),
              ),
            if (party != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onClearParty,
                  child: const Text('Back to walk-in'),
                ),
              ),
            const SizedBox(height: 12),

            AtriaCard(
              showBorder: true,
              child: Column(
                children: [
                  _row(context, 'Taxable value', totals.taxableValue),
                  if (totals.cgstTotal > Decimal.zero)
                    _row(context, 'CGST', totals.cgstTotal),
                  if (totals.sgstTotal > Decimal.zero)
                    _row(context, 'SGST', totals.sgstTotal),
                  if (totals.igstTotal > Decimal.zero)
                    _row(context, 'IGST', totals.igstTotal),
                  if (totals.cessTotal > Decimal.zero)
                    _row(context, 'Cess', totals.cessTotal),
                  if (totals.roundOff != Decimal.zero)
                    _row(context, 'Round off', totals.roundOff),
                  const Divider(height: 20),
                  Row(
                    children: [
                      Expanded(child: Text('Total', style: text.titleMedium)),
                      Text(
                        Formatters.money(totals.grandTotal),
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: fullyPaid,
              onChanged: onFullyPaidChanged,
              title: const Text('Taken in full'),
              subtitle: Text(
                fullyPaid
                    ? 'A receipt is recorded against the bill straight away.'
                    : 'Leaves the bill outstanding on the customer\'s account.',
                style: text.bodySmall,
              ),
            ),
            if (fullyPaid) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Received by'),
                items: [
                  for (final (value, label) in _modes)
                    DropdownMenuItem(value: value, child: Text(label)),
                ],
                onChanged: (value) => onModeChanged(value ?? 'cash'),
              ),
            ],
            const SizedBox(height: 8),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: printLabels,
              onChanged: printerName == null ? null : onPrintLabelsChanged,
              title: const Text('Print barcode labels'),
              subtitle: Text(
                printerName == null
                    ? 'No label printer is set up yet.'
                    : 'One sticker per unit, from ${printerName!}.',
                style: text.bodySmall,
              ),
            ),
            if (printerName == null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => context.push('/settings/printers'),
                  icon: const Icon(PhosphorIconsRegular.printer, size: 16),
                  label: const Text('Set up a printer'),
                ),
              ),
            const SizedBox(height: 12),

            FilledButton.icon(
              onPressed: lineCount == 0 || busy ? null : onComplete,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(PhosphorIconsRegular.checkCircle),
              label: const Text('Complete sale'),
            ),
            const SizedBox(height: 6),
            Text(
              'F4 on a keyboard. The bill is numbered, stock moves and the '
              'receipt is recorded exactly as it would be from the sales screen.',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, String label, Decimal amount) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
          Text(Formatters.money(amount), style: text.bodyMedium),
        ],
      ),
    );
  }
}

/// The customer picker, as a sheet over the counter screen.
class _PartyPicker extends StatefulWidget {
  const _PartyPicker({required this.repository});

  final PartyRepository repository;

  @override
  State<_PartyPicker> createState() => _PartyPickerState();
}

class _PartyPickerState extends State<_PartyPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final parties = widget.repository.watchCustomers();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search customers',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<PartyEntity>>(
              stream: parties,
              builder: (context, snapshot) {
                final all = snapshot.data ?? const <PartyEntity>[];
                final lowered = _query.toLowerCase();
                final shown = lowered.isEmpty
                    ? all
                    : all
                          .where(
                            (party) =>
                                party.name.toLowerCase().contains(lowered),
                          )
                          .toList();
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (shown.isEmpty) {
                  return const Center(child: Text('No customer matches that.'));
                }
                return ListView.builder(
                  controller: controller,
                  itemCount: shown.length,
                  itemBuilder: (context, index) {
                    final party = shown[index];
                    return ListTile(
                      title: Text(party.name),
                      subtitle: Text(
                        [
                          if ((party.gstin ?? '').isNotEmpty) party.gstin!,
                          if ((party.phone ?? '').isNotEmpty) party.phone!,
                        ].join(' · '),
                      ),
                      onTap: () => Navigator.of(context).pop(party),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders a decimal without a pointless trailing `.0`, because "3 pcs" reads
/// better at a counter than "3.0 pcs".
String _trimDecimal(Decimal value) {
  final text = value.toString();
  if (text.contains('.')) {
    return text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return text;
}
