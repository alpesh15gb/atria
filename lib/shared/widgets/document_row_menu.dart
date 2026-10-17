import 'dart:io';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';

import 'confirm_destructive.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/firm_repository.dart';
import '../../core/database/repositories/payment_repository.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/services/invoice_pdf.dart';
import '../../core/services/purchase_pdf.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/utils/file_names.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/money.dart';

/// The row kebab (⋮) for every document list — **content aware**, in the way
/// the desktop billing suites build theirs: the entries adapt to what the row
/// IS and what state it is in.
///
/// - *Receive Payment* only on an invoice that still has a balance.
/// - *Convert* only on an open quotation / sales order / purchase order.
/// - *Cancel* only on an invoice (and never on one already cancelled).
/// - *Open PDF / Print* on everything that can be printed — sales documents,
///   purchase documents and payment vouchers. *Preview* only on an invoice,
///   the one document with its own screen.
/// - *Duplicate* only where a seed flow exists (it re-opens the editor as a
///   new document copied from this one).
/// - *View History* on everything, from the audit trail.
///
/// The widget is self-sufficient: it resolves its own repositories and routes
/// from [docType], so a list screen swaps its `RowActionsButton` for this and
/// loses nothing.
class DocumentRowMenu extends ConsumerWidget {
  const DocumentRowMenu({
    super.key,
    required this.docType,
    required this.docId,
    required this.number,
    required this.status,
    this.paymentStatus,
    this.balanceDue = 0,
    this.convertedToInvoiceId,
    this.onEdit,
  });

  /// 'invoice' | 'quotation' | 'sales_order' | 'delivery_note' |
  /// 'credit_note' | 'bill' | 'purchase_order' | 'debit_note' |
  /// 'payment_in' | 'payment_out'
  final String docType;

  final String docId;
  final String number;
  final String status;

  /// Invoices/bills only — decides *Receive Payment*.
  final String? paymentStatus;

  /// Invoices only — the amount *Receive Payment* opens with.
  final double balanceDue;

  /// The invoice this document became, if it has been converted.
  ///
  /// Sales documents record conversion in this column rather than in `status`;
  /// purchase documents still set `status = 'converted'` (their
  /// `markConverted` was not part of this change). Both are honoured by
  /// [_isConverted], so the menu behaves identically on either side instead of
  /// offering *Convert* twice on a sales quotation that has already been
  /// invoiced.
  final String? convertedToInvoiceId;

  /// Overrides the View/Edit push. The payments screen passes its editor
  /// sheet here — payments have no edit route of their own.
  final void Function(BuildContext context, WidgetRef ref)? onEdit;

  bool get _isSalesDoc => const [
    'invoice',
    'quotation',
    'sales_order',
    'delivery_note',
    'credit_note',
  ].contains(docType);

  bool get _isPurchaseDoc =>
      const ['bill', 'purchase_order', 'debit_note'].contains(docType);

  bool get _isPayment => docType == 'payment_in' || docType == 'payment_out';

  bool get _isCancelled => status == 'cancelled';

  /// Already turned into an invoice — by the link, or by the legacy flag on
  /// rows converted before v9.
  bool get _isConverted =>
      convertedToInvoiceId != null || status == 'converted';

  /// Quotation / sales order / purchase order that can still be converted.
  bool get _convertible =>
      !_isCancelled &&
      !_isConverted &&
      (docType == 'quotation' ||
          docType == 'sales_order' ||
          docType == 'purchase_order');

  bool get _invoiceWithBalance =>
      docType == 'invoice' &&
      !_isCancelled &&
      !_isConverted &&
      paymentStatus != 'paid' &&
      balanceDue > 0.001;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _entries(context, ref);

    return PopupMenuButton<_MenuEntry>(
      tooltip: 'More actions',
      icon: Icon(
        Icons.more_vert_rounded,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      onSelected: (entry) => entry.run(),
      itemBuilder: (context) => [
        for (final entry in entries)
          PopupMenuItem<_MenuEntry>(
            value: entry,
            // 44dp: the Material minimum tap target. At 40 the row was four
            // pixels under it, which is the difference between a comfortable
            // press and a missed one on a touchscreen till.
            height: 44,
            child: Row(
              children: [
                Icon(
                  entry.icon,
                  size: 18,
                  color: entry.destructive
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Text(
                  entry.label,
                  style: TextStyle(
                    color: entry.destructive ? scheme.error : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---- The content-aware rules -------------------------------------------

  List<_MenuEntry> _entries(BuildContext context, WidgetRef ref) {
    final entries = <_MenuEntry>[];

    void add({
      required String label,
      required IconData icon,
      required VoidCallback onTap,
      bool destructive = false,
    }) {
      entries.add(_MenuEntry(label, icon, onTap, destructive));
    }

    // Edit / View ----------------------------------------------------------
    final editRoute = _editRoute();
    if (onEdit != null) {
      add(
        label: 'View / Edit',
        icon: Icons.edit_outlined,
        onTap: () => onEdit!(context, ref),
      );
    } else if (editRoute != null) {
      add(
        label: 'View / Edit',
        icon: Icons.edit_outlined,
        onTap: () => _push(context, editRoute),
      );
    }

    // Money in, on an invoice that still wants it.
    if (_invoiceWithBalance) {
      add(
        label: 'Receive Payment',
        icon: Icons.south_west_rounded,
        onTap: () => _receivePayment(context, ref),
      );
    }

    // Convert the promise into the document that does the accounting.
    if (_convertible) {
      add(
        label: switch (docType) {
          'quotation' || 'sales_order' => 'Convert to invoice',
          _ => 'Convert to bill',
        },
        icon: Icons.receipt_long_outlined,
        onTap: () => _push(context, _duplicateRoute(convert: true)),
      );
    }

    // Print / PDF — every document the app can build a PDF for.
    if (_isSalesDoc || _isPurchaseDoc || _isPayment) {
      add(
        label: 'Open PDF',
        icon: Icons.picture_as_pdf_outlined,
        onTap: () => _openPdf(context, ref),
      );
      add(
        label: 'Print',
        icon: Icons.print_outlined,
        onTap: () => _print(context, ref),
      );
    }
    if (_isSalesDoc && docType == 'invoice') {
      add(
        label: 'Preview',
        icon: Icons.visibility_outlined,
        onTap: () => _push(context, '/sales/detail/$docId'),
      );
    }

    // Cancel — an invoice stops chasing money. Never on one already
    // cancelled (the row would offer the same action twice).
    if (docType == 'invoice' && !_isCancelled && !_isConverted) {
      add(
        label: 'Cancel invoice',
        icon: Icons.block_outlined,
        onTap: () => _cancel(context, ref),
      );
    }

    // Delete ---------------------------------------------------------------
    add(
      label: 'Delete',
      icon: Icons.delete_outline_rounded,
      destructive: true,
      onTap: () => _delete(context, ref),
    );

    // Duplicate — re-open as a NEW document copied from this one. Payments
    // have no seed flow (a payment is an event, not a document to copy).
    if (_isSalesDoc || _isPurchaseDoc) {
      add(
        label: 'Duplicate',
        icon: Icons.copy_rounded,
        onTap: () => _push(context, _duplicateRoute()),
      );
    }

    // History --------------------------------------------------------------
    add(
      label: 'View History',
      icon: Icons.history_rounded,
      onTap: () => _viewHistory(context, ref),
    );

    return entries;
  }

  String? _editRoute() {
    if (_isPayment) return null; // opened through [onEdit]
    if (_isPurchaseDoc) return '/purchase/edit/$docId?type=$docType';
    return '/sales/edit/$docId?type=$docType';
  }

  /// The seed route: `?from=` copies party, lines and adjustments into a NEW
  /// document.
  ///
  /// **`convert` gets its own parameter**, `?convertFrom=`. Both used to share
  /// `?from=`, and the editor sets "mark this source converted after saving" for
  /// *any* document type it is handed — so duplicating an already-issued
  /// **invoice** stamped `convertedToInvoiceId` on the original, flipped its
  /// row status to Converted, and replaced its Paid/Partial/Unpaid in the status
  /// column with a link to the copy. Copying a document must not mutate it.
  String _duplicateRoute({bool convert = false}) {
    final param = convert ? 'convertFrom' : 'from';
    if (_isPurchaseDoc) {
      final type = convert ? 'bill' : docType;
      return '/purchase/new?type=$type&$param=$docId';
    }
    final type = convert ? 'invoice' : docType;
    return '/sales/new?type=$type&$param=$docId';
  }

  void _push(BuildContext context, String route) {
    // PopupMenuButton closures run while the menu's overlay is closing; a
    // post-frame push avoids "looking up a deactivated ancestor".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted) context.push(route);
    });
  }
  // ---- Actions -----------------------------------------------------------

  Future<void> _receivePayment(BuildContext context, WidgetRef ref) async {
    final payments = ref.read(paymentRepositoryProvider);
    final sales = ref.read(salesRepositoryProvider);
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (payments == null || sales == null || firm == null) return;

    // One read of the document serves both what the dialog shows (the party)
    // and what the receipt links to. They used to be two separate awaits
    // around the dialog, so the row could be read before and after it.
    final doc = await sales.getById(docId);
    if (doc == null || !context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _ReceivePaymentDialog(
        payments: payments,
        firmId: firm.id,
        onApplied: (id, amt) => sales.applyPayment(invoiceId: id, amount: amt),
        docId: docId,
        number: number,
        partyId: doc.partyId,
        partyName: doc.partyName,
        balance: Money.of(balanceDue),
      ),
    );
    if (ok == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Payment recorded against $number')),
      );
    }
  }

  /// Builds the document's PDF and hands it to the OS viewer.
  ///
  /// The row knows only a doc type, so the builder is chosen here: a sales
  /// document goes through [InvoicePdf], a purchase document and a payment
  /// voucher through [PurchasePdf]. They are separate services on purpose —
  /// the tax split, the totals and who-owes-what all differ — but they share
  /// the same furniture, so they print as one family.
  Future<void> _openPdf(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (firm == null) return;
    try {
      final bytes = await _buildPdf(ref, firm);
      if (bytes == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final outDir = Directory(
        p.join(dir.path, 'apexbooks', _isSalesDoc ? 'invoices' : 'purchases'),
      );
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final stem = await _pdfFileStem(ref);
      final file = File(p.join(outDir.path, '${sanitizeFileName(stem)}.pdf'));
      await file.writeAsBytes(bytes, flush: true);
      await OpenFilex.open(file.path);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not build the PDF: $error')),
      );
    }
  }

  Future<void> _print(BuildContext context, WidgetRef ref) async {
    final firm = ref.read(activeFirmProvider).valueOrNull;
    if (firm == null) return;
    try {
      final bytes = await _buildPdf(ref, firm);
      if (bytes == null) return;
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Could not print: $error')));
      }
    }
  }

  /// The rendered bytes for whichever document this row is, or null when the
  /// row has been deleted from under us.
  Future<Uint8List?> _buildPdf(WidgetRef ref, FirmEntity firm) async {
    if (_isSalesDoc) {
      final sales = ref.read(salesRepositoryProvider);
      if (sales == null) return null;
      final doc = await sales.getById(docId);
      if (doc == null) return null;
      return InvoicePdf.forFirm(firm)
          .build(invoice: doc, items: await sales.itemsFor(docId));
    }
    if (_isPurchaseDoc) {
      final purchases = ref.read(purchaseRepositoryProvider);
      if (purchases == null) return null;
      final bill = await purchases.getById(docId);
      if (bill == null) return null;
      return PurchasePdf.forFirm(firm)
          .build(bill: bill, items: await purchases.itemsFor(docId));
    }
    final payments = ref.read(paymentRepositoryProvider);
    final payment = await payments?.getById(docId);
    if (payment == null) return null;
    return PurchasePdf.forFirm(firm).buildVoucher(payment: payment);
  }

  /// The file name, which has to be the document's own number rather than the
  /// row's id — the id is a uuid and tells the reader nothing.
  Future<String> _pdfFileStem(WidgetRef ref) async {
    if (_isSalesDoc) {
      final doc = await ref.read(salesRepositoryProvider)?.getById(docId);
      if (doc != null) return doc.number;
    } else if (_isPurchaseDoc) {
      final bill = await ref.read(purchaseRepositoryProvider)?.getById(docId);
      if (bill != null) return bill.number;
    } else {
      final payment = await ref.read(paymentRepositoryProvider)?.getById(docId);
      if (payment != null) return payment.number;
    }
    return number;
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Cancel $number?',
      message:
          'A cancelled invoice stops chasing money and is excluded from '
          'the outstanding lists and GST returns. It stays in the books '
          'and can still be viewed.',
      confirmLabel: 'Cancel invoice',
      cancelLabel: 'Keep it',
    );
    if (confirmed != true) return;
    try {
      await ref.read(salesRepositoryProvider)?.markCancelled(docId);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$number cancelled')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Could not cancel: $error')));
      }
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $number?'),
        content: Text(
          _isPayment
              ? 'It moves to the recycle bin and can be restored from '
                    'Settings. The document it settled is updated.'
              : 'Stock and balances are reversed. It moves to the recycle '
                    'bin and can be restored from Settings.',
        ),
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
      if (_isPayment) {
        await ref.read(paymentRepositoryProvider)?.softDelete(docId);
      } else if (_isPurchaseDoc) {
        await ref.read(purchaseRepositoryProvider)?.softDelete(docId);
      } else {
        await ref.read(salesRepositoryProvider)?.softDelete(docId);
      }
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('$number moved to the recycle bin')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('Could not delete: $error')));
      }
    }
  }

  /// The audit trail for one row: every entry the repositories wrote about
  /// this entity id, newest first.
  Future<void> _viewHistory(BuildContext context, WidgetRef ref) async {
    final db = ref.read(appDatabaseProvider);
    final entity = _isPayment
        ? 'payments'
        : _isPurchaseDoc
        ? 'purchase_bills'
        : 'sales_invoices';
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final firmId = ref.read(activeFirmIdProvider);
      final all = await db.auditRepository.list(
        firmId: firmId,
        entity: entity,
        limit: 2000,
      );
      final rows = all.where((r) => r.entityId == docId).toList();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('History · $number'),
          content: SizedBox(
            width: 440,
            height: 320,
            child: rows.isEmpty
                ? const Center(
                    child: Text('No history recorded for this document.'),
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Colors.transparent),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          switch (row.action) {
                            'insert' => Icons.add_circle_outline_rounded,
                            'update' => Icons.edit_outlined,
                            'delete' => Icons.delete_outline_rounded,
                            'restore' => Icons.restore_rounded,
                            'purge' => Icons.delete_forever_rounded,
                            _ => Icons.circle_outlined,
                          },
                          size: 18,
                          color: row.action == 'delete' || row.action == 'purge'
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(
                          row.summary ?? row.action,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${Formatters.dateTime(row.createdAt)}'
                          '${row.actor == null ? '' : ' · ${row.actor}'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not load history: $error')),
      );
    }
  }
}

/// The row-kebab *Receive Payment* body.
///
/// A real [StatefulWidget] rather than a `StatefulBuilder` so the amount field
/// owns its `TextEditingController` and disposes it — the closure version
/// leaked one controller for every payment ever recorded from a list screen.
class _ReceivePaymentDialog extends ConsumerStatefulWidget {
  const _ReceivePaymentDialog({
    required this.payments,
    required this.firmId,
    required this.onApplied,
    required this.docId,
    required this.number,
    required this.partyId,
    required this.partyName,
    required this.balance,
  });

  final PaymentRepository payments;
  final String firmId;

  /// Applies the receipt to the document's balance, inside the payment's
  /// transaction. Passed in so this widget needs no sales repository.
  final Future<void> Function(String invoiceId, double amount) onApplied;

  final String docId;
  final String number;
  final String? partyId;
  final String? partyName;

  /// What the row was rendered with. This is the cap: an over-sized receipt is
  /// a silent money bug, because `applyPayment` clamps `balanceDue` at zero
  /// while the payment ROW keeps the full typed figure — the ledger would say
  /// ₹2,000 was received against a ₹1,000 invoice that reads fully paid, and
  /// the snackbar would report success. The detail screen caps and warns; this
  /// now does the same, and says so BEFORE the money is taken rather than
  /// quietly taking less than was typed.
  final Decimal balance;

  @override
  ConsumerState<_ReceivePaymentDialog> createState() =>
      _ReceivePaymentDialogState();
}

class _ReceivePaymentDialogState extends ConsumerState<_ReceivePaymentDialog> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.balance == widget.balance.round()
        ? widget.balance.toStringAsFixed(0)
        : widget.balance.toStringAsFixed(2),
  );
  String _mode = 'cash';
  DateTime _date = DateTime.now();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// What the field currently says.
  Decimal get _typed => Money.tryParse(_amount.text) ?? Money.zero;

  /// The warning shown while the typed figure is more than is due. Same
  /// sentence the invoice detail screen uses, so the two paths to recording a
  /// payment read identically.
  String? get _overBalance {
    if (_typed <= Money.zero) return null;
    if (widget.balance <= Money.zero) return null;
    if (_typed <= widget.balance) return null;
    return 'The balance due is only ${Formatters.money(widget.balance)}. '
        'Only that will be recorded.';
  }

  Future<void> _record() async {
    if (_submitting) return;
    final amount = _typed;
    if (amount <= Money.zero) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    try {
      final firm = await ref
          .read(firmRepositoryProvider)
          .getById(widget.firmId);
      if (firm == null) {
        setState(() {
          _error = 'Open a firm before recording a payment.';
          _submitting = false;
        });
        return;
      }
      final paymentNumber = await ref
          .read(firmRepositoryProvider)
          .nextNumber(firm, DocSequence.paymentIn, date: _date);
      // The cap: the receipt can never exceed what the document still owes.
      final recorded = amount > widget.balance ? widget.balance : amount;
      await widget.payments.create(
        type: 'payment_in',
        number: paymentNumber,
        partyId: widget.partyId,
        partyName: widget.partyName,
        amount: recorded.toDouble(),
        date: _date,
        mode: _mode,
        linkedInvoiceId: widget.docId,
        linkedInvoiceNumber: widget.number,
        onLinked: widget.onApplied,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not save: $e';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final overBalance = _overBalance;
    return AlertDialog(
      title: Text('Receive payment · ${widget.number}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.partyName ?? 'Walk-in customer',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Re-evaluated on every keystroke so the cap is visible before the
            // money is taken, not after.
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Amount',
              prefixText: '₹ ',
              errorText: _error ?? overBalance,
              helperText: widget.balance > Money.zero
                  ? 'Balance due ${Formatters.money(widget.balance)}'
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            iconSize: 20,
            initialValue: _mode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Mode'),
            items: const [
              DropdownMenuItem(value: 'cash', child: Text('Cash')),
              DropdownMenuItem(value: 'bank', child: Text('Bank')),
              DropdownMenuItem(value: 'upi', child: Text('UPI')),
              DropdownMenuItem(value: 'neft', child: Text('NEFT/RTGS')),
              DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
              DropdownMenuItem(value: 'card', child: Text('Card')),
            ],
            onChanged: (v) => setState(() => _mode = v ?? 'cash'),
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: AppRadius.mdAll,
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              // The picker is an await: the dialog can be gone by the time it
              // answers.
              if (picked != null && mounted) setState(() => _date = picked);
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Date'),
              child: Text(Formatters.date(_date)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _record,
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Record payment'),
        ),
      ],
    );
  }
}

/// One runnable menu entry. The callback is captured with its context and
/// ref already bound (the content rules and their handlers sit side by side),
/// so selecting it just runs.
class _MenuEntry {
  const _MenuEntry(this.label, this.icon, this.run, this.destructive);

  final String label;
  final IconData icon;
  final VoidCallback run;
  final bool destructive;
}
