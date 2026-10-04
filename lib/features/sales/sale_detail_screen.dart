import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/engine/gst_engine.dart';
import '../../core/printer/printer_service.dart';
import '../../core/services/invoice_pdf.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/number_words.dart';
import '../../core/utils/whatsapp_links.dart';
import '../../shared/widgets/atria_line_grid.dart';
import '../../shared/widgets/atria_pdf_preview.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/money_text.dart';
import '../../shared/widgets/status_chip.dart';
import '../../core/theme/app_sizes.dart';

class SaleDetailScreen extends ConsumerStatefulWidget {
  const SaleDetailScreen({super.key, required this.id});

  final String id;

  @override
  ConsumerState<SaleDetailScreen> createState() => _SaleDetailScreenState();
}

class _SaleDetailScreenState extends ConsumerState<SaleDetailScreen> {
  SalesInvoiceEntity? _invoice;
  List<SalesInvoiceItemEntity> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Called again after a cancel/refresh; the screen may have been popped
    // while the write was in flight, and `ref` throws on a disposed state.
    if (!mounted) return;
    final sales = ref.read(salesRepositoryProvider);
    if (sales == null) return;
    final invoice = await sales.getById(widget.id);
    final items = await sales.itemsFor(widget.id);
    if (mounted) {
      setState(() {
        _invoice = invoice;
        _items = items;
        _loading = false;
      });
    }
  }

  FirmEntity? _firm() => ref.read(activeFirmProvider).valueOrNull;

  /// `INV/2026-27/001` → `INV_2026-27_001.pdf`. The invoice number is a
  /// series label, not a file name — writing it raw makes the OS treat the
  /// slashes as folders and the write fails.
  String get _pdfFileName => '${sanitizeFileName(_invoice?.number ?? '')}.pdf';

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_invoice == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Not found')),
        body: EmptyState(
          icon: PhosphorIconsRegular.question,
          title: 'Invoice not found',
          message: 'It may have been deleted.',
          actionLabel: 'Back',
          onAction: () => context.pop(),
        ),
      );
    }
    final invoice = _invoice!;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            expandedHeight: 132,
            title: Text(invoice.number),
            actions: [
              IconButton(
                onPressed: () => _share(context),
                icon: const Icon(PhosphorIconsRegular.paperPlaneTilt, size: 20),
                tooltip: 'Share',
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      context.push(
                        '/sales/edit/${invoice.id}?type=${invoice.docType}',
                      );
                      break;
                    case 'convert':
                      context.push(
                        '/sales/new?type=invoice&from=${invoice.id}',
                      );
                      break;
                    case 'pdf':
                      _openPdf();
                      break;
                    case 'print':
                      _print();
                      break;
                    case 'receipt':
                      _printReceipt();
                      break;
                    case 'cancel':
                      _confirmCancel();
                      break;
                    case 'delete':
                      _confirmDelete();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  // Quotes, orders and delivery notes graduate into invoices
                  // (DN → invoice is the standard dispatch-to-bill flow);
                  // converted sources lose the action so a second invoice
                  // can't be spawned from the same document.
                  if ((invoice.docType == 'quotation' ||
                          invoice.docType == 'sales_order' ||
                          invoice.docType == 'delivery_note') &&
                      invoice.status != 'converted' &&
                      invoice.status != 'cancelled')
                    const PopupMenuItem(
                      value: 'convert',
                      child: Text('Convert to invoice'),
                    ),
                  const PopupMenuItem(value: 'pdf', child: Text('Open as PDF')),
                  const PopupMenuItem(value: 'print', child: Text('Print')),
                  // A till-roll receipt, not the A4 document: different paper,
                  // different printer and different command language, so it is
                  // a separate action rather than a setting on Print.
                  const PopupMenuItem(
                    value: 'receipt',
                    child: Text('Print receipt'),
                  ),
                  const PopupMenuItem(
                    value: 'cancel',
                    child: Row(
                      children: [
                        Icon(Icons.cancel_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('Cancel invoice'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('Delete'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Column(
                    children: [
                      _StatusHero(invoice: invoice),
                      const SizedBox(height: 16),
                      _PartyAndMeta(
                        invoice: invoice,
                        items: _items,
                        firmStateCode: _firm()?.stateCode,
                      ),
                      const SizedBox(height: 16),
                      _ItemsTable(
                        invoice: invoice,
                        items: _items,
                        firmStateCode: _firm()?.stateCode,
                      ),
                      const SizedBox(height: 16),
                      _AmountBreakdown(
                        invoice: invoice,
                        firmStateCode: _firm()?.stateCode,
                      ),
                      const SizedBox(height: 16),
                      if (invoice.docType == 'invoice' &&
                          invoice.status != 'cancelled')
                        _PaymentSection(invoice: invoice, onChanged: _load),
                      const SizedBox(height: 8),
                      _PdfPreviewCard(
                        invoice: invoice,
                        items: _items,
                        onPrint: () => _print(),
                        onShare: () => _share(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _share(BuildContext context) async {
    final firm = _firm();
    if (firm == null || _invoice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await InvoicePdf.forFirm(firm).build(
        invoice: _invoice!,
        items: _items,
      );
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, _pdfFileName));
      await file.writeAsBytes(bytes, flush: true);

      final phone = _invoice!.partyPhone ?? '';
      final text =
          'Hi ${_invoice!.partyName ?? ''}, '
          'here is your ${_invoice!.docType == 'invoice' ? 'invoice' : 'quotation'} '
          '${_invoice!.number} for ${Formatters.money(Decimal.parse(_invoice!.grandTotal.toStringAsFixed(2)))}.'
          '${(firm.upiId ?? '').isNotEmpty ? ' Pay via UPI: ${firm.upiId}' : ''}';

      if (phone.isNotEmpty) {
        // Direct WhatsApp chat with the party, message and UPI link
        // pre-filled. The PDF rides along through the system share sheet,
        // which is what the user picks the chat target in.
        final digits = phone.replaceAll(RegExp(r'[^\d]'), '');
        final waUri = Uri.parse(
          WhatsAppLinks.chat(digits, message: text).toString(),
        );
        try {
          await launchUrl(waUri, mode: LaunchMode.externalApplication);
        } catch (_) {
          // No WhatsApp on this device — the share sheet below still works.
        }
        await Share.shareXFiles(
          [XFile(file.path)],
          text: text,
          subject: '${_invoice!.number} from ${firm.name}',
          sharePositionOrigin: const Rect.fromLTWH(0, 0, 100, 100),
        );
      } else {
        await Share.shareXFiles(
          [XFile(file.path)],
          text: text,
          subject: '${_invoice!.number} from ${firm.name}',
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not share: $e')));
    }
  }

  Future<void> _openPdf() async {
    final firm = _firm();
    if (firm == null || _invoice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await InvoicePdf.forFirm(firm).build(
        invoice: _invoice!,
        items: _items,
      );
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory(p.join(dir.path, 'atria', 'invoices'));
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final file = File(p.join(outDir.path, _pdfFileName));
      await file.writeAsBytes(bytes, flush: true);
      await OpenFilex.open(file.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open PDF: $e')));
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _print() async {
    final firm = _firm();
    if (firm == null || _invoice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Printing.layoutPdf(
        onLayout: (format) =>
            InvoicePdf.forFirm(firm).build(invoice: _invoice!, items: _items),
        name: _invoice!.number,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not print: $e')));
    }
  }

  /// Prints the customer's till-roll receipt.
  ///
  /// A receipt printer is a *different device* from the one the A4 invoice goes
  /// to, so this asks for the printer configured for receipts rather than the
  /// default printer — and says which setting to open when there is none,
  /// instead of failing inside the socket layer.
  Future<void> _printReceipt() async {
    final firm = _firm();
    final invoice = _invoice;
    if (firm == null || invoice == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final profile = await ref
          .read(printerRegistryProvider)
          .forKind(PrinterKind.receipt);
      if (profile == null) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'No receipt printer is set up yet. Add one in Settings → Label '
              'printers and set its job to "Customer receipts".',
            ),
          ),
        );
        return;
      }

      final paid = invoice.paidAmount;
      await ThermalPrinterService.printReceipt(
        profile,
        ThermalPrinterService.receiptForInvoice(
          firm: firm,
          invoice: invoice,
          items: _items,
          paidLine: paid > 0.001
              ? 'Received ${Formatters.money(Decimal.tryParse(paid.toStringAsFixed(2)) ?? Decimal.zero)}'
              : null,
        ),
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Receipt sent to ${profile.name}.')),
      );
    } on LabelException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not print the receipt: $error')),
      );
    }
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel invoice?'),
        content: Text(
          '${_invoice!.number} will be marked cancelled. Stock effects '
          'already applied remain as-is. This cannot be undone from the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Cancel invoice'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final sales = ref.read(salesRepositoryProvider);
    await sales?.markCancelled(_invoice!.id);
    if (!mounted) return;
    _load();
  }

  /// Soft-delete: stock/balances reversed, document moves to the recycle
  /// bin (restorable from Settings), audit logged.
  Future<void> _confirmDelete() async {
    final invoice = _invoice;
    if (invoice == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${invoice.number}?'),
        content: const Text(
          'Stock and balances are reversed. The document moves to the '
          'recycle bin and can be restored from Settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
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
    if (confirmed != true || !mounted) return;
    await ref.read(salesRepositoryProvider)?.softDelete(invoice.id);
    if (!mounted) return;
    context.pop();
  }
}

class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.invoice});

  final SalesInvoiceEntity invoice;

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final cancelled = invoice.status == 'cancelled';
    final due = invoice.dueDate;
    final isOverdue =
        !cancelled &&
        invoice.balanceDue > 0.001 &&
        due != null &&
        due.isBefore(DateTime.now());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.xl)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: cancelled
              ? [Colors.grey.shade600, Colors.grey.shade800]
              : isOverdue
              // dangerSurface is a pale tint meant for chip backgrounds;
              // ending the gradient there would put white text on near-white
              // in light mode. Fade toward a deep red instead.
              ? [colors.negative, colors.danger]
              : [colors.brandGradientStart, colors.brandGradientEnd],
        ),
        boxShadow: AppShadows.cardHigh,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  'Total ${invoice.docType == 'quotation' ? 'quotation' : 'invoice'} value',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // On the type scale, not a 12.5px one-off: the hero's label is
                  // the same rank as every other secondary label in the app.
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (cancelled)
                const StatusChip(label: 'Cancelled', kind: ChipKind.danger)
              else if (isOverdue)
                const StatusChip(label: 'Overdue', kind: ChipKind.danger)
              else
                StatusChip.payment(invoice.paymentStatus),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            Formatters.money(
              Decimal.parse(invoice.grandTotal.toStringAsFixed(2)),
            ),
            style: Theme.of(context).textTheme.displayLarge?.copyWith(
              color: Colors.white,
              height: 1.05,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            NumberToWords.indianCurrency(invoice.grandTotal),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12,
            ),
          ),
          if (!cancelled && invoice.balanceDue > 0.001) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      'Balance due',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        Formatters.money(
                          Decimal.parse(invoice.balanceDue.toStringAsFixed(2)),
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
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

class _PartyAndMeta extends StatelessWidget {
  const _PartyAndMeta({
    required this.invoice,
    required this.items,
    this.firmStateCode,
  });

  final SalesInvoiceEntity invoice;
  final List<SalesInvoiceItemEntity> items;
  final String? firmStateCode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final due = invoice.dueDate;
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Bill to',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      invoice.partyName ?? 'Walk-in customer',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if ((invoice.partyGstin ?? '').isNotEmpty)
                      Text(
                        'GSTIN: ${invoice.partyGstin!.toUpperCase()}',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    if (invoice.billingAddress != null &&
                        invoice.billingAddress!.isNotEmpty)
                      Text(
                        invoice.billingAddress!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    invoice.docType == 'quotation'
                        ? 'Quotation date'
                        : 'Invoice date',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    Formatters.date(invoice.invoiceDate),
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (due != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Due date',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Formatters.date(due),
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: [
              _metaChip(
                context,
                invoice.isInterState ? 'Inter-state' : 'Intra-state',
                invoice.isInterState
                    ? 'IGST'
                    : 'CGST + ${intraStateSecondHead(resolveGstSplit(supplierState: firmStateCode, buyerState: invoice.placeOfSupply))}',
              ),
              const SizedBox(width: 10),
              _metaChip(
                context,
                'Place of supply',
                IndianStates.byCode(invoice.placeOfSupply)?.name ??
                    invoice.placeOfSupply ??
                    '-',
              ),
              const SizedBox(width: 10),
              _metaChip(context, 'Items', '${items.length}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metaChip(BuildContext context, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
              // "Place of supply" is ~106dp against ~72dp of text room at
              // 360dp, so the label has to give way exactly like the value
              // below it does.
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              value,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemsTable extends StatelessWidget {
  const _ItemsTable({
    required this.invoice,
    required this.items,
    this.firmStateCode,
  });

  final SalesInvoiceEntity invoice;
  final List<SalesInvoiceItemEntity> items;
  final String? firmStateCode;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasGstin = (invoice.partyGstin ?? '').isNotEmpty;
    final interState = invoice.isInterState && hasGstin;

    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SectionHeader(title: 'Items', padding: EdgeInsets.zero),
          ),
          // Read-only lines go through the same responsive grid the editors
          // use, not a DataTable. The DataTable this replaced needed ~800dp for
          // its nine columns, so on a 360dp phone the reader saw the Item
          // column and had to scroll sideways for every rupee figure — the
          // rate, the tax and the amount were all off-screen, which is the
          // whole point of the card. The grid re-flows to a labelled card per
          // line below `Breakpoints.medium` and keeps the spreadsheet sheet
          // above it, so Windows is unchanged and Android becomes readable.
          AtriaLineGrid(
            showAddRow: false,
            onAddRow: () {},
            emptyHint: 'This invoice has no items.',
            columns: [
              const AtriaLineColumn('Item', flex: 3),
              const AtriaLineColumn('HSN', flex: 2),
              const AtriaLineColumn('Qty', flex: 1, numeric: true),
              const AtriaLineColumn('Rate', flex: 2, numeric: true),
              const AtriaLineColumn('Taxable', flex: 2, numeric: true),
              if (interState)
                const AtriaLineColumn('IGST', flex: 2, numeric: true)
              else ...[
                const AtriaLineColumn('CGST', flex: 2, numeric: true),
                AtriaLineColumn(
                  intraStateSecondHead(
                    resolveGstSplit(
                      supplierState: firmStateCode,
                      buyerState: invoice.placeOfSupply,
                    ),
                  ),
                  flex: 2,
                  numeric: true,
                ),
              ],
              const AtriaLineColumn('Amount', flex: 2, numeric: true),
            ],
            rows: [
              for (final l in items)
                AtriaLineGridRow(
                  cells: [
                    Text(
                      l.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      l.hsn ?? '-',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    Text(Formatters.qty(Decimal.parse(l.quantity.toString()))),
                    Text(
                      Formatters.money(
                        Decimal.parse(l.rate.toStringAsFixed(2)),
                      ),
                    ),
                    Text(
                      Formatters.money(
                        Decimal.parse(l.taxableValue.toStringAsFixed(2)),
                      ),
                    ),
                    if (interState)
                      Text(
                        l.igst > 0.001
                            ? Formatters.money(
                                Decimal.parse(l.igst.toStringAsFixed(2)),
                              )
                            : '-',
                      )
                    else ...[
                      Text(
                        l.cgst > 0.001
                            ? Formatters.money(
                                Decimal.parse(l.cgst.toStringAsFixed(2)),
                              )
                            : '-',
                      ),
                      Text(
                        l.sgst > 0.001
                            ? Formatters.money(
                                Decimal.parse(l.sgst.toStringAsFixed(2)),
                              )
                            : '-',
                      ),
                    ],
                    Text(
                      Formatters.money(
                        Decimal.parse(l.total.toStringAsFixed(2)),
                      ),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AmountBreakdown extends StatelessWidget {
  const _AmountBreakdown({required this.invoice, this.firmStateCode});

  final SalesInvoiceEntity invoice;

  /// The seller's state, so the intra-state total can be named CGST + UTGST
  /// where that is what was actually charged.
  final String? firmStateCode;

  @override
  Widget build(BuildContext context) {
    final invoiceDiscount = GstEngine.resolvedInvoiceDiscount(
      subTotal: invoice.subTotal,
      itemDiscount: invoice.itemDiscount,
      invoiceDiscountPercent: invoice.invoiceDiscountPercent,
      invoiceDiscountAmount: invoice.invoiceDiscountAmount,
    );
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _line(
            context,
            'Subtotal',
            Decimal.parse(invoice.subTotal.toStringAsFixed(2)),
          ),
          if (invoice.itemDiscount.abs() > 0.001 ||
              invoiceDiscount.abs() > 0.001)
            _line(
              context,
              'Discount',
              Decimal.parse(
                (invoice.itemDiscount + invoiceDiscount).toStringAsFixed(2),
              ),
              negate: true,
            ),
          if (invoice.shippingCharge.abs() > 0.001)
            _line(
              context,
              'Shipping / freight',
              Decimal.parse(invoice.shippingCharge.toStringAsFixed(2)),
            ),
          _line(
            context,
            'Taxable value',
            Decimal.parse(invoice.taxableValue.toStringAsFixed(2)),
          ),
          if (invoice.cgst.abs() > 0.001)
            _line(
              context,
              'CGST',
              Decimal.parse(invoice.cgst.toStringAsFixed(2)),
            ),
          if (invoice.sgst.abs() > 0.001)
            _line(
              context,
              intraStateSecondHead(
                resolveGstSplit(
                  supplierState: firmStateCode,
                  buyerState: invoice.placeOfSupply,
                ),
              ),
              Decimal.parse(invoice.sgst.toStringAsFixed(2)),
            ),
          if (invoice.igst.abs() > 0.001)
            _line(
              context,
              'IGST',
              Decimal.parse(invoice.igst.toStringAsFixed(2)),
            ),
          if (invoice.cess.abs() > 0.001)
            _line(
              context,
              'Cess',
              Decimal.parse(invoice.cess.toStringAsFixed(2)),
            ),
          if (invoice.tcs.abs() > 0.001)
            _line(
              context,
              invoice.tcsRate > 0
                  ? 'TCS @ ${Formatters.percent(invoice.tcsRate)}'
                  : 'TCS',
              Decimal.parse(invoice.tcs.toStringAsFixed(2)),
            ),
          if (invoice.roundOff.abs() > 0.001)
            _line(
              context,
              'Round off',
              Decimal.parse(invoice.roundOff.toStringAsFixed(2)),
            ),
          const Divider(height: 22),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    'Grand total',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: MoneyText(
                    Decimal.parse(invoice.grandTotal.toStringAsFixed(2)),
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    colorize: false,
                    textAlign: TextAlign.right,
                    shrinkToFit: true,
                  ),
                ),
              ],
            ),
          ),
          if (invoice.paidAmount.abs() > 0.001) ...[
            const SizedBox(height: 6),
            _line(
              context,
              'Received',
              Decimal.parse(invoice.paidAmount.toStringAsFixed(2)),
            ),
            _line(
              context,
              'Balance',
              Decimal.parse(invoice.balanceDue.toStringAsFixed(2)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(
    BuildContext context,
    String label,
    Decimal value, {
    bool negate = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: MoneyText(
              // `negate` used to be a '- ' prefix painted onto a positive
              // figure; handing the sign to MoneyText is the same output, and
              // it keeps the minus attached to the number when the figure
              // scales down to fit.
              negate ? -value : value,
              signMode: MoneySignMode.auto,
              colorize: false,
              textAlign: TextAlign.right,
              shrinkToFit: true,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PaymentSection extends ConsumerStatefulWidget {
  const _PaymentSection({required this.invoice, required this.onChanged});

  final SalesInvoiceEntity invoice;
  final VoidCallback onChanged;

  @override
  ConsumerState<_PaymentSection> createState() => _PaymentSectionState();
}

class _PaymentSectionState extends ConsumerState<_PaymentSection> {
  final _amountController = TextEditingController();
  String _mode = 'upi';
  final _referenceController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _recording = false;

  /// Whether the amount in the field is the USER's figure rather than the
  /// invoice's balance. Once they have typed, a re-sync would overwrite a
  /// half-typed amount mid-keystroke; the field only goes back to tracking the
  /// balance after a payment is actually recorded (see [_record]).
  bool _amountIsTyped = false;

  /// The balance, formatted the way the field shows it.
  String _amountTextFor(double balance) => balance > 0
      ? Formatters.indianGroup(balance.toStringAsFixed(2))
      : '0.00';

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _amountController.text = _amountTextFor(widget.invoice.balanceDue);
  }

  @override
  void didUpdateWidget(covariant _PaymentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The parent reloads the invoice after every payment, so this section is
    // rebuilt with a smaller balance. There was no re-sync here at all: record
    // 400 of 1,000, the field still read 1,000.00, and tapping Record again
    // took the whole remaining balance in one go.
    if (oldWidget.invoice.balanceDue == widget.invoice.balanceDue) return;
    // A figure the user is still typing wins over the new balance.
    if (_amountIsTyped) return;
    _amountController.text = _amountTextFor(widget.invoice.balanceDue);
  }

  @override
  Widget build(BuildContext context) {
    final balance = Decimal.parse(widget.invoice.balanceDue.toStringAsFixed(2));
    if (balance <= Decimal.zero) return const SizedBox.shrink();
    final colors = atriaColors(context);

    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                PhosphorIconsRegular.moneyWavy,
                size: 18,
                color: colors.positive,
              ),
              const SizedBox(width: 8),
              Text(
                'Record payment',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _amountController,
                  onChanged: (_) => _amountIsTyped = true,
                  decoration: const InputDecoration(
                    labelText: 'Amount received',
                    prefixText: '₹ ',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  iconSize: AppIconSize.md,
                  // Without this the button lays its label out at its natural
                  // width and overflows the field: at 360dp this half of the
                  // row is 119px, and "Cheque" plus the arrow does not fit.
                  isExpanded: true,
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  items: const [
                    DropdownMenuItem(value: 'cash', child: Text('Cash')),
                    DropdownMenuItem(value: 'upi', child: Text('UPI')),
                    DropdownMenuItem(
                      value: 'bank_transfer',
                      child: Text('Bank transfer'),
                    ),
                    DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
                    DropdownMenuItem(value: 'card', child: Text('Card')),
                  ],
                  onChanged: (v) => setState(() => _mode = v ?? 'cash'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _referenceController,
                  decoration: const InputDecoration(
                    labelText: 'UTR / reference (optional)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Date'),
                    child: Text(Formatters.date(_date)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _record,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Record payment'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _record() async {
    if (_recording) return;
    var amount = double.tryParse(
      _amountController.text.replaceAll(RegExp(r'[^\d.]'), ''),
    );
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid amount.')));
      return;
    }
    // An over-payment used to sail through: applyPayment clamps balanceDue at
    // zero and keeps the excess in paidAmount, so the customer's ₹2,000 change
    // would just vanish from the invoice. Cap it at what is actually owed and
    // say so.
    final balance = widget.invoice.balanceDue;
    if (balance > 0 && amount > balance + 0.001) {
      amount = balance;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'The balance due is only '
            '${Formatters.money(Decimal.parse(balance.toStringAsFixed(2)))}. '
            'Recording that amount.',
          ),
        ),
      );
    }
    final payments = ref.read(paymentRepositoryProvider);
    final sales = ref.read(salesRepositoryProvider);
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (payments == null || sales == null || firm == null) {
      // A button that does nothing at all reads as a crash to the user.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open a firm before recording a payment.'),
        ),
      );
      return;
    }

    _recording = true;
    try {
      final number = await ref
          .read(firmRepositoryProvider)
          .nextNumber(firm, DocSequence.paymentIn, date: _date);

      await payments.create(
        type: 'payment_in',
        number: number,
        partyId: widget.invoice.partyId,
        partyName: widget.invoice.partyName,
        amount: amount,
        date: _date,
        mode: _mode,
        reference: _referenceController.text.trim().isEmpty
            ? null
            : _referenceController.text.trim(),
        linkedInvoiceId: widget.invoice.id,
        linkedInvoiceNumber: widget.invoice.number,
        onLinked: (id, amt) => sales.applyPayment(invoiceId: id, amount: amt),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Recorded ${Formatters.money(Decimal.parse(amount.toStringAsFixed(2)))} '
            'against ${widget.invoice.number}',
          ),
        ),
      );
      // Hand the field back to the balance it is tracking: the recorded
      // payment is settled, so the next amount to enter is what is left, not
      // what the user typed before the tap.
      _amountIsTyped = false;
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not record payment: $e')));
    } finally {
      _recording = false;
    }
  }
}

class _PdfPreviewCard extends StatefulWidget {
  const _PdfPreviewCard({
    required this.invoice,
    required this.items,
    this.onPrint,
    this.onShare,
  });

  final SalesInvoiceEntity invoice;
  final List<SalesInvoiceItemEntity> items;

  /// The screen's own print and share flows — the same ones the app-bar menu
  /// runs, so the card does not grow a second, differently-behaving pair.
  final VoidCallback? onPrint;
  final VoidCallback? onShare;

  @override
  State<_PdfPreviewCard> createState() => _PdfPreviewCardState();
}

class _PdfPreviewCardState extends State<_PdfPreviewCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Row(
              children: [
                Icon(
                  PhosphorIconsRegular.filePdf,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Preview invoice PDF',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 12),
            Consumer(
              builder: (context, ref, _) {
                final firm = ref.watch(activeFirmProvider).valueOrNull;
                if (firm == null) {
                  return const Text('Firm not available');
                }
                return AtriaPdfPreview(
                  height: 380,
                  builder: (format) => InvoicePdf.forFirm(firm).build(
                    invoice: widget.invoice,
                    items: widget.items,
                  ),
                  onPrint: widget.onPrint,
                  onShare: widget.onShare,
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}
