import '../domain/gst_registration.dart';
import 'package:decimal/decimal.dart';

import '../database/app_database.dart';
import '../database/repositories/repository_extensions.dart';
import '../utils/formatters.dart';
import '../utils/id_utils.dart';
import 'esc_pos_encoder.dart';
import 'label_encoder.dart';
import 'printer_profile.dart';
import 'printer_transport.dart';

export 'esc_pos_encoder.dart'
    show EscPosEncoder, ReceiptDocument, ReceiptItemLine, ReceiptTotalLine;
export 'label_encoder.dart'
    show
        BarcodeSymbology,
        LabelDocument,
        LabelEncoder,
        LabelException,
        TsplEncoder,
        ZplEncoder;
export 'printer_profile.dart'
    show PrinterBrand, PrinterKind, PrinterProfile, PrinterTransport;
export 'printer_transport.dart' show PrinterConnection;

/// The printers the operator has set up, kept in app settings.
///
/// Settings rather than a table of their own: a printer is a preference of this
/// installation — an IP on the shop's LAN, or a queue name on this PC — and not
/// part of the books, so it must not travel in a backup or be attributed to a
/// firm's data.
class PrinterRegistry {
  PrinterRegistry(this.db);

  final AppDatabase db;

  static const String listKey = 'thermal_printers';
  static const String defaultKey = 'thermal_default_printer';

  Future<List<PrinterProfile>> all() async =>
      PrinterProfile.parseList(await db.settingsGet(listKey));

  /// Every printer this device can actually print to.
  ///
  /// The stored list is shared by whatever device last wrote it, so a printer
  /// configured on the office desktop comes back on a phone pointing at a
  /// Windows print queue that does not exist here. Filtering once, here, is
  /// what keeps every print button from choosing one of those: the callers
  /// (`defaultPrinterProvider`) only see printers they can reach, and an empty
  /// result is the honest "there is no printer on *this* device" answer that
  /// turns into an invitation to add one.
  Future<List<PrinterProfile>> usableHere() async =>
      [for (final profile in await all()) if (profile.isUsableHere) profile];

  /// The printer a print button should use when the caller has no opinion.
  ///
  /// The operator's chosen default wins. Otherwise the first printer that can
  /// actually be reached here is used — in the stored order, which is the order
  /// the settings list shows, so the choice is reproducible rather than an
  /// accident of map iteration.
  Future<PrinterProfile?> defaultPrinter() async => _default(await usableHere());

  /// The printer that should do a job of [kind].
  ///
  /// Prefers the operator's default *of that kind*: a shop with a label printer
  /// at the counter and a receipt printer on the till has set one default, and
  /// asking a TSPL label printer to print a till roll would print the commands
  /// themselves. Returns null when nothing of that kind is set up **and
  /// reachable from this device**, which the caller turns into "add one in
  /// Settings" rather than a printer error.
  ///
  /// A single global default is a known limit of this model: with two receipt
  /// printers the operator picks one via "Make default", and every other
  /// printer of that kind is reached only by printing from its own screen.
  /// What is *not* acceptable is silently picking whichever happens to be
  /// first, so both this and [defaultPrinter] go through [_default].
  Future<PrinterProfile?> forKind(PrinterKind kind) async => _default([
        for (final profile in await usableHere())
          if (profile.kind == kind) profile,
      ]);

  /// The chosen default among [profiles], else the first one.
  ///
  /// Single source of truth for both public lookups so "which printer does the
  /// Print button use" has exactly one answer in this file.
  Future<PrinterProfile?> _default(List<PrinterProfile> profiles) async {
    if (profiles.isEmpty) return null;
    final id = await db.settingsGet(defaultKey);
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    // A default that was deleted, of the wrong kind, or unreachable from this
    // device. Falling back to the first *reachable* printer rather than to
    // nothing keeps Print working after the operator removes the printer that
    // used to be the default.
    return profiles.first;
  }

  /// Adds [profile] or replaces the one with the same id, and returns the new
  /// list. A profile with no id is inserted (the caller builds settings forms
  /// before there is anything to key on).
  Future<List<PrinterProfile>> upsert(PrinterProfile profile) async {
    final profiles = await all();
    final id = profile.id.isEmpty ? IdUtils.newId() : profile.id;
    final stored = profile.copyWith(id: id);
    final index = profiles.indexWhere((p) => p.id == id);
    if (index == -1) {
      profiles.add(stored);
    } else {
      profiles[index] = stored;
    }
    await _save(profiles);
    if (await db.settingsGet(defaultKey) == null || profiles.length == 1) {
      await db.settingsSet(defaultKey, id);
    }
    return profiles;
  }

  /// Removes [id], promoting another printer when the default was the one
  /// removed so a print button never ends up pointing at nothing.
  Future<List<PrinterProfile>> remove(String id) async {
    final profiles = await all()..removeWhere((p) => p.id == id);
    await _save(profiles);
    if (await db.settingsGet(defaultKey) == id) {
      await db.settingsSet(
        defaultKey,
        profiles.isEmpty ? '' : profiles.first.id,
      );
    }
    return profiles;
  }

  Future<void> setDefault(String id) => db.settingsSet(defaultKey, id);

  Future<void> _save(List<PrinterProfile> profiles) =>
      db.settingsSet(listKey, PrinterProfile.encodeList(profiles));
}

/// Builds labels and receipts, and puts them on the wire.
class ThermalPrinterService {
  ThermalPrinterService._();

  /// Sends one print job to [profile].
  ///
  /// The encoder is chosen from the profile's brand here and nowhere else, so
  /// a TSC is never handed ZPL.
  static Future<void> print(
    PrinterProfile profile,
    List<LabelDocument> labels,
  ) async {
    _checkReachable(profile);
    final bytes = LabelEncoder.forProfile(profile).encodeAll(labels);
    await PrinterConnection.forProfile(profile).send(bytes);
  }

  /// Prints one label that carries every element, to prove a fresh setup.
  static Future<void> printTest(PrinterProfile profile) async {
    _checkReachable(profile);
    final bytes = LabelEncoder.forProfile(profile).encodeTestLabel();
    await PrinterConnection.forProfile(profile).send(bytes);
  }

  /// Prints a customer receipt.
  ///
  /// Refuses a label printer rather than sending ESC/POS to it: the two command
  /// languages share nothing, and a TSPL printer handed a receipt prints the
  /// commands as text (or nothing at all), which reads as a broken printer
  /// instead of a printer set up for the wrong job.
  static Future<void> printReceipt(
    PrinterProfile profile,
    ReceiptDocument document,
  ) async {
    _checkReachable(profile);
    if (profile.kind != PrinterKind.receipt) {
      throw const LabelException(
        'This printer is set up for barcode labels. Add the receipt printer in '
        'Settings, or change this one\'s job to "Customer receipts".',
      );
    }
    final bytes = EscPosEncoder.forProfile(profile).encode(document);
    await PrinterConnection.forProfile(profile).send(bytes);
  }

  /// Prints a test receipt: paper width, alignment, bold, double height, and —
  /// if they are switched on — the cut and the cash drawer. The same code path
  /// a real receipt takes.
  static Future<void> printReceiptTest(PrinterProfile profile) async {
    _checkReachable(profile);
    if (profile.kind != PrinterKind.receipt) {
      throw const LabelException(
        'This printer is set up for barcode labels, not receipts.',
      );
    }
    final bytes =
        EscPosEncoder.forProfile(profile).encodeTest(printerName: profile.name);
    await PrinterConnection.forProfile(profile).send(bytes);
  }

  /// Checks the printer answers, without printing.
  static Future<String> probe(PrinterProfile profile) {
    _checkReachable(profile);
    return PrinterConnection.forProfile(profile).probe();
  }

  /// Refuses a printer this device cannot reach, in words, before any bytes are
  /// built.
  ///
  /// `defaultPrinter()` and `forKind()` already filter those out, but a caller
  /// holding a profile straight from the settings screen can still hand one
  /// over — and the alternative is a `DynamicLibrary.open` failure on a phone,
  /// which is a crash rather than an answer. All four print entries go through
  /// this so they cannot drift apart.
  static void _checkReachable(PrinterProfile profile) {
    final problem = profile.problem;
    if (problem != null) throw LabelException(problem);
  }

  // ---- Receipts from documents -------------------------------------------

  /// The customer's receipt for a sales document.
  ///
  /// Money is formatted by `Formatters` — the same call the invoice PDF and the
  /// screen use — so the slip in the customer's hand and the A4 copy in the
  /// files can never disagree. The encoder only translates the result into
  /// glyphs a printer has.
  static ReceiptDocument receiptForInvoice({
    required FirmEntity firm,
    required SalesInvoiceEntity invoice,
    required List<SalesInvoiceItemEntity> items,
    String? paidLine,
    bool isReprint = false,
  }) {
    Decimal money(double value) =>
        Decimal.tryParse(value.toStringAsFixed(2)) ?? Decimal.zero;

    final totals = <ReceiptTotalLine>[
      ReceiptTotalLine('Taxable', Formatters.money(money(invoice.taxableValue))),
      if (invoice.cgst.abs() > 0.001)
        ReceiptTotalLine('CGST', Formatters.money(money(invoice.cgst))),
      if (invoice.sgst.abs() > 0.001)
        ReceiptTotalLine('SGST', Formatters.money(money(invoice.sgst))),
      if (invoice.igst.abs() > 0.001)
        ReceiptTotalLine('IGST', Formatters.money(money(invoice.igst))),
      if (invoice.cess.abs() > 0.001)
        ReceiptTotalLine('Cess', Formatters.money(money(invoice.cess))),
      if (invoice.tcs.abs() > 0.001)
        ReceiptTotalLine(
          'TCS${invoice.tcsRate > 0 ? ' ${Formatters.percent(invoice.tcsRate)}' : ''}',
          Formatters.money(money(invoice.tcs)),
        ),
      if (invoice.shippingCharge.abs() > 0.001)
        ReceiptTotalLine(
            'Shipping', Formatters.money(money(invoice.shippingCharge))),
      if (invoice.roundOff.abs() > 0.001)
        ReceiptTotalLine(
            'Round off', Formatters.money(money(invoice.roundOff))),
      ReceiptTotalLine(
        'TOTAL',
        Formatters.money(money(invoice.grandTotal)),
        emphasise: true,
      ),
    ];

    return ReceiptDocument(
      firmName: firm.name,
      title: invoice.docType == 'invoice' && !firm.isGstRegistered &&
          invoice.cgst + invoice.sgst + invoice.igst + invoice.cess == 0
          ? 'Invoice' : _receiptTitle(invoice.docType),
      number: invoice.number,
      dateLine: Formatters.date(invoice.invoiceDate),
      firmGstin: firm.gstin,
      firmAddress: _firmAddress(firm),
      firmPhone: firm.phone,
      partyName: invoice.partyName,
      partyGstin: invoice.partyGstin,
      items: [
        for (final item in items)
          ReceiptItemLine(
            name: item.name,
            hsn: item.hsn,
            quantityText: '${Formatters.qty(Decimal.tryParse(item.quantity.toStringAsFixed(3)) ?? Decimal.zero)} ${item.unit}',
            rateText: Formatters.money(money(item.rate)),
            amountText: Formatters.money(money(item.total)),
          ),
      ],
      totals: totals,
      paidLine: paidLine,
      balanceLine: invoice.balanceDue.abs() > 0.001
          ? Formatters.money(money(invoice.balanceDue))
          : null,
      terms: invoice.terms ?? firm.invoiceTerms,
      // The two things a customer actually needs to pay by themselves: where
      // the money goes and how to reach the shop.
      paymentLine: (firm.upiId ?? '').trim().isEmpty
          ? null
          : 'Pay by UPI: ${firm.upiId!.trim()}',
      footerLine: 'Thank you for your business'
          '${(firm.phone ?? '').trim().isEmpty ? '' : ' · ${firm.phone!.trim()}'}',
      isReprint: isReprint,
    );
  }

  /// A shop's own words for the document, so a quotation taken to a customer
  /// does not arrive titled TAX INVOICE.
  static String _receiptTitle(String docType) => switch (docType) {
        'quotation' => 'Estimate',
        'sales_order' => 'Sales order',
        'delivery_note' => 'Delivery note',
        'credit_note' => 'Credit note',
        _ => 'Tax invoice',
      };

  static String? _firmAddress(FirmEntity firm) {
    final parts = [
      firm.addressLine1,
      firm.addressLine2,
      firm.city,
      firm.pincode,
    ].where((p) => (p ?? '').trim().isNotEmpty).cast<String>().toList();
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// The label for one catalog item.
  ///
  /// [footer] is the shop name or a branch, printed only if it fits.
  static LabelDocument labelForItem(
    ItemEntity item, {
    int copies = 1,
    String? footer,
  }) {
    final code = barcodeForItem(item);
    final mrp = item.mrp;
    return LabelDocument(
      title: item.name,
      subtitle: _subtitle(item),
      barcode: code,
      symbology: symbologyFor(code),
      priceLine: Formatters.money(
        Decimal.parse(item.salePrice.toStringAsFixed(2)),
      ),
      // The MRP is only worth the ink when it differs from what is charged;
      // printing the same number twice looks like a mistake.
      strikethroughLine: mrp == null || mrp <= 0 || mrp == item.salePrice
          ? null
          : 'MRP ${Formatters.money(Decimal.parse(mrp.toStringAsFixed(2)))}',
      footer: footer,
      copies: copies,
    );
  }

  /// The label for a counter sale line — the same sticker, repeated once per
  /// unit sold, which is what a shop needs for loose stock.
  static LabelDocument labelForSaleLine(
    ItemEntity item, {
    required num quantity,
    String? footer,
  }) =>
      labelForItem(
        item,
        copies: _copiesFor(quantity),
        footer: footer,
      );

  /// A whole-number quantity becomes that many labels; a fractional one becomes
  /// a single label, because half a sticker cannot be printed and guessing a
  /// rounding would silently over- or under-label the stock.
  static int _copiesFor(num quantity) {
    if (quantity <= 0) return 1;
    final rounded = quantity.round();
    if ((quantity - rounded).abs() > 0.0001) return 1;
    return rounded.clamp(1, 50);
  }

  /// The value encoded in the bars: the item's own barcode when it has one,
  /// otherwise its code.
  ///
  /// Falling back to the item id keeps this in step with the A4 sheet in
  /// `BarcodeLabels`, so a shop that prints both gets the same number in both
  /// places. The id is a UUIDv7, so it is unique by construction — the previous
  /// first-12-characters fallback truncated two items created in the same
  /// millisecond to identical barcodes.
  static String barcodeForItem(ItemEntity item) {
    final saved = item.barcode?.trim() ?? '';
    if (saved.isNotEmpty) return saved;
    final sku = item.sku?.trim() ?? '';
    if (sku.isNotEmpty) return sku;
    return item.id.toUpperCase();
  }

  /// The symbology the *value* supports rather than the one the operator
  /// prefers: a well-formed EAN-13 prints as EAN-13, so a supplier's barcode
  /// keeps scanning as itself. Everything else is Code 128, which encodes any
  /// printable ASCII.
  static BarcodeSymbology symbologyFor(String code) =>
      LabelEncoder.isValidEan13(code)
          ? BarcodeSymbology.ean13
          : BarcodeSymbology.code128;

  /// The second line: whichever identifier the shop actually uses.
  static String? _subtitle(ItemEntity item) {
    final sku = item.sku?.trim() ?? '';
    if (sku.isNotEmpty) return sku;
    final hsn = item.hsn?.trim() ?? '';
    if (hsn.isNotEmpty) return 'HSN $hsn';
    return null;
  }
}
