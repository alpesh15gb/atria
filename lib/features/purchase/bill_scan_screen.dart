import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/server_client.dart' show ServerRequestException;
import '../../core/sync/scan_seed.dart';
import '../../core/state/providers.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/common_widgets.dart';

/// Scan a supplier bill and review what the server's vision model read.
///
/// The flow is deliberately two screens: this one answers "did the model read
/// the bill right?" and the normal purchase editor answers "is this the bill
/// I want to save?". Merging them would put a wall of editable fields behind
/// an upload spinner, and nobody reviews a form they are also filling in.
///
/// Nothing is saved by this screen. The only write happens later, through the
/// editor's normal save path, after the person has seen every field.
class BillScanScreen extends ConsumerStatefulWidget {
  const BillScanScreen({super.key});

  @override
  ConsumerState<BillScanScreen> createState() => _BillScanScreenState();
}

class _BillScanScreenState extends ConsumerState<BillScanScreen> {
  bool _uploading = false;
  String? _error;

  ScannedReviewState _review = ScannedReviewState.empty;

  /// Bytes + type of the image being scanned, kept so a retry does not force
  /// another pick.
  List<int>? _pendingImage;
  String _pendingMime = 'image/jpeg';

  Future<void> _pickImage({required bool fromCamera}) async {
    setState(() {
      _error = null;
    });

    List<int>? bytes;
    String mime = 'image/jpeg';

    if (fromCamera) {
      // Image capture goes through file_picker's camera option, which is
      // backed by the system camera app on both platforms. Android needs no
      // extra permission for ACTION_IMAGE_CAPTURE; desktop uses a webcam
      // dialog. When no camera exists the picker reports failure and we say
      // so rather than silently doing nothing.
      try {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          withData: true,
        );
        final file = result?.files.single;
        final path = file?.path;
        if (path != null) {
          bytes = await File(path).readAsBytes();
          mime = _mimeFor(path, file?.extension);
        } else if (file?.bytes != null) {
          bytes = file!.bytes!;
        }
      } on Object catch (error) {
        if (!mounted) return;
        setState(() => _error = 'Could not open the camera: $error');
        return;
      }
    } else {
      try {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'heic'],
          withData: true,
        );
        final file = result?.files.single;
        final path = file?.path;
        if (path != null) {
          bytes = await File(path).readAsBytes();
          mime = _mimeFor(path, file?.extension);
        } else if (file?.bytes != null) {
          bytes = file!.bytes!;
          mime = _mimeFor(file.name, file.extension);
        }
      } on Object catch (error) {
        setState(() => _error = 'Could not open the file picker: $error');
        return;
      }
    }

    if (bytes == null || bytes.isEmpty) return;
    _pendingImage = bytes;
    _pendingMime = mime;
    await _scan();
  }

  String _mimeFor(String path, String? extension) {
    final ext = (extension ?? path.split('.').last).toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'heic':
      case 'heif':
        return 'image/heic';
      default:
        return 'image/jpeg';
    }
  }

  Future<void> _scan() async {
    final image = _pendingImage;
    if (image == null) return;

    final firmId = ref.read(activeFirmIdProvider);
    if (firmId == null) {
      setState(() => _error = 'No business is open.');
      return;
    }
    final token = await ref.read(authControllerProvider.notifier).accessToken();
    if (token == null) {
      setState(() {
        _error = 'Sign in to Atria to scan bills - the reading happens on the '
            'Atria server, not on this device.';
      });
      return;
    }

    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final bill = await ref.read(scanClientProvider).scanBill(
            firmId: firmId,
            imageBytes: image,
            mimeType: _pendingMime,
            accessToken: token,
          );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _review = ScannedReviewState.fromBill(bill);
      });
    } on ServerRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = 'Scan failed: $error';
      });
    }
  }

  Future<void> _continueToEditor() async {
    final seed = _review.toSeed();
    if (seed == null) return;
    // Replace this screen with the editor: back from the editor is the
    // purchase list, not the scan preview the user is done with.
    if (!mounted) return;
    context.pushReplacement(
      '/purchase/new?fromScan=1',
      extra: seed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reviewed = _review.hasAnything;

    return Scaffold(
      appBar: AppBar(title: const Text('Scan a purchase bill')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AtriaCard(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PhosphorIcon(
                            PhosphorIconsRegular.scan,
                            size: 22,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Photograph the supplier bill',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'The photo goes to your Atria server, an AI vision '
                        'model reads it there, and every field comes back '
                        'for you to check before anything is saved. The '
                        'picture itself is not stored.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed:
                                  _uploading ? null : () => _pickImage(fromCamera: true),
                              icon: const PhosphorIcon(
                                PhosphorIconsRegular.camera,
                                size: 18,
                              ),
                              label: const Text('Take photo'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              onPressed:
                                  _uploading ? null : () => _pickImage(fromCamera: false),
                              icon: const PhosphorIcon(
                                PhosphorIconsRegular.image,
                                size: 18,
                              ),
                              label: const Text('From gallery'),
                            ),
                          ),
                        ],
                      ),
                      if (_pendingImage != null && !_uploading && _review.hasAnything) ...[
                        const SizedBox(height: 8),
                        Center(
                          child: TextButton.icon(
                            onPressed: _scan,
                            icon: const PhosphorIcon(
                              PhosphorIconsRegular.arrowsClockwise,
                              size: 16,
                            ),
                            label: const Text('Scan this photo again'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_uploading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text(
                          'Reading the bill on your server...',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  AtriaCard(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PhosphorIcon(
                          PhosphorIconsRegular.warningCircle,
                          size: 20,
                          color: scheme.error,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _error!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.error, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (reviewed && !_uploading) ...[
                  const SizedBox(height: 16),
                  _confidenceBanner(),
                  if (_review.warnings.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final warning in _review.warnings)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            PhosphorIcon(
                              PhosphorIconsRegular.info,
                              size: 15,
                              color: scheme.tertiary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                warning,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  _reviewFields(),
                  const SizedBox(height: 10),
                  _reviewLines(),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _review.lines.isEmpty ? null : _continueToEditor,
                    icon: const PhosphorIcon(
                      PhosphorIconsRegular.pencilSimpleLine,
                      size: 18,
                    ),
                    label: const Text('Review and save in the bill editor'),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      'Nothing is saved yet. The next screen shows the full '
                      'bill form with these values filled in.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _confidenceBanner() {
    final scheme = Theme.of(context).colorScheme;
    final confident = _review.confidence == 'high';
    return Row(
      children: [
        PhosphorIcon(
          confident
              ? PhosphorIconsRegular.checkCircle
              : PhosphorIconsRegular.warningCircle,
          size: 18,
          color: confident ? scheme.primary : scheme.tertiary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            confident
                ? 'Read confidently. Check the numbers anyway.'
                : 'Read with some uncertainty. Check every field.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  /// Header fields, each editable in place: what you see is what the editor
  /// will receive, not a rendering of a hidden payload.
  Widget _reviewFields() {
    final r = _review;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Supplier & bill details',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          _reviewField(
            label: 'Supplier',
            value: r.supplierName,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(supplierName: () => v)),
          ),
          _reviewField(
            label: 'GSTIN',
            value: r.supplierGstin,
            onChanged: (v) => setState(() =>
                _review = _review.copyWith(supplierGstin: () => v.toUpperCase())),
            trailingError: Validators.isValidGstin(r.supplierGstin)
                ? null
                : 'Not a valid GSTIN format',
          ),
          _reviewField(
            label: 'Bill number',
            value: r.invoiceNumber,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(invoiceNumber: () => v)),
          ),
          _reviewField(
            label: 'Bill date (YYYY-MM-DD)',
            value: r.billDateRaw,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(billDateRaw: () => v)),
          ),
          _reviewField(
            label: 'Place of supply (state code)',
            value: r.placeOfSupply,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(placeOfSupply: () => v)),
          ),
        ],
      ),
    );
  }

  Widget _reviewField({
    required String label,
    required String? value,
    required ValueChanged<String> onChanged,
    String? trailingError,
  }) {
    final controller = TextEditingController(text: value ?? '');
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          errorText: trailingError,
        ),
      ),
    );
  }

  Widget _reviewLines() {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lines read from the bill', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_review.lines.isEmpty)
            Text(
              'No lines were readable. Add them in the editor instead.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            )
          else
            for (var i = 0; i < _review.lines.length; i++)
              _lineReview(i),
        ],
      ),
    );
  }

  Widget _lineReview(int index) {
    final line = _review.lines[index];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    line.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove line',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _review = _review.withoutLine(index)),
                  icon: const PhosphorIcon(PhosphorIconsRegular.trash, size: 17),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _lineNumField(
                    label: 'Qty',
                    initial: line.quantity,
                    onChanged: (v) =>
                        setState(() => _review = _review.withLineQuantity(index, v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _lineNumField(
                    label: 'Rate',
                    initial: line.rate,
                    onChanged: (v) =>
                        setState(() => _review = _review.withLineRate(index, v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _lineNumField(
                    label: 'GST %',
                    initial: line.gstRate,
                    onChanged: (v) =>
                        setState(() => _review = _review.withLineGst(index, v)),
                  ),
                ),
              ],
            ),
            if (line.hsn != null && line.hsn!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'HSN ${line.hsn}  ·  unit ${line.unit}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lineNumField({
    required String label,
    required double initial,
    required ValueChanged<double> onChanged,
  }) {
    return TextFormField(
      initialValue:
          initial == initial.roundToDouble() ? initial.toStringAsFixed(0) : '$initial',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: label, isDense: true),
      onChanged: (value) {
        final parsed = double.tryParse(value.replaceAll(',', ''));
        if (parsed != null) onChanged(parsed);
      },
    );
  }
}

/// The editable review state: the model's reading, after the person's
/// corrections. A plain immutable class with copy helpers, so every edit is a
/// setState with a new value rather than controllers scattered per field.
class ScannedReviewState {
  const ScannedReviewState({
    required this.supplierName,
    required this.supplierGstin,
    required this.supplierPhone,
    required this.supplierAddress,
    required this.invoiceNumber,
    required this.billDateRaw,
    required this.dueDateRaw,
    required this.placeOfSupply,
    required this.lines,
    required this.shippingCharge,
    required this.otherCharges,
    required this.confidence,
    required this.warnings,
    required this.model,
  });

  final String? supplierName;
  final String? supplierGstin;
  final String? supplierPhone;
  final String? supplierAddress;
  final String? invoiceNumber;
  final String? billDateRaw;
  final String? dueDateRaw;
  final String? placeOfSupply;
  final List<ScannedLineSeed> lines;
  final double shippingCharge;
  final double otherCharges;
  final String confidence;
  final List<String> warnings;
  final String model;

  static final ScannedReviewState empty = ScannedReviewState(
    supplierName: null,
    supplierGstin: null,
    supplierPhone: null,
    supplierAddress: null,
    invoiceNumber: null,
    billDateRaw: null,
    dueDateRaw: null,
    placeOfSupply: null,
    lines: const [],
    shippingCharge: 0,
    otherCharges: 0,
    confidence: 'medium',
    warnings: const [],
    model: '',
  );

  bool get hasAnything =>
      lines.isNotEmpty ||
      (invoiceNumber ?? '').isNotEmpty ||
      (supplierName ?? '').isNotEmpty;

  DateTime? get billDate {
    final raw = billDateRaw?.trim() ?? '';
    if (raw.isEmpty) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  DateTime? get dueDate {
    final raw = dueDateRaw?.trim() ?? '';
    if (raw.isEmpty) return null;
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static ScannedReviewState fromBill(dynamic bill) {
    return ScannedReviewState(
      supplierName: bill.supplierName,
      supplierGstin: bill.supplierGstin,
      supplierPhone: bill.supplierPhone,
      supplierAddress: bill.supplierAddress,
      invoiceNumber: bill.supplierInvoiceNumber,
      billDateRaw: bill.billDate?.toIso8601String().split('T').first,
      dueDateRaw: bill.dueDate?.toIso8601String().split('T').first,
      placeOfSupply: bill.placeOfSupply,
      lines: [
        for (final line in bill.lines)
          ScannedLineSeed(
            name: line.name,
            hsn: line.hsn,
            quantity: line.quantity,
            rate: line.rate,
            unit: line.unit,
            discountPercent: line.discountPercent,
            gstRate: line.gstRate,
            cessRate: line.cessRate,
          ),
      ],
      shippingCharge: bill.shippingCharge,
      otherCharges: bill.otherCharges,
      confidence: bill.confidence,
      warnings: bill.warnings,
      model: bill.model,
    );
  }

  ScannedReviewState copyWith({
    String? Function()? supplierName,
    String? Function()? supplierGstin,
    String? Function()? invoiceNumber,
    String? Function()? billDateRaw,
    String? Function()? placeOfSupply,
  }) =>
      ScannedReviewState(
        supplierName: supplierName == null ? this.supplierName : supplierName(),
        supplierGstin:
            supplierGstin == null ? this.supplierGstin : supplierGstin(),
        supplierPhone: supplierPhone,
        supplierAddress: supplierAddress,
        invoiceNumber:
            invoiceNumber == null ? this.invoiceNumber : invoiceNumber(),
        billDateRaw: billDateRaw == null ? this.billDateRaw : billDateRaw(),
        dueDateRaw: dueDateRaw,
        placeOfSupply:
            placeOfSupply == null ? this.placeOfSupply : placeOfSupply(),
        lines: lines,
        shippingCharge: shippingCharge,
        otherCharges: otherCharges,
        confidence: confidence,
        warnings: warnings,
        model: model,
      );

  ScannedReviewState withoutLine(int index) {
    if (index < 0 || index >= lines.length) return this;
    return ScannedReviewState(
      supplierName: supplierName,
      supplierGstin: supplierGstin,
      supplierPhone: supplierPhone,
      supplierAddress: supplierAddress,
      invoiceNumber: invoiceNumber,
      billDateRaw: billDateRaw,
      dueDateRaw: dueDateRaw,
      placeOfSupply: placeOfSupply,
      lines: [...lines]..removeAt(index),
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
      confidence: confidence,
      warnings: warnings,
      model: model,
    );
  }

  ScannedReviewState withLineQuantity(int index, double value) =>
      _mapLine(index, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: value, rate: l.rate,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: l.gstRate, cessRate: l.cessRate,
          ));

  ScannedReviewState withLineRate(int index, double value) =>
      _mapLine(index, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: l.quantity, rate: value,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: l.gstRate, cessRate: l.cessRate,
          ));

  ScannedReviewState withLineGst(int index, double value) =>
      _mapLine(index, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: l.quantity, rate: l.rate,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: value, cessRate: l.cessRate,
          ));

  ScannedReviewState _mapLine(
    int index,
    ScannedLineSeed Function(ScannedLineSeed) mapper,
  ) {
    if (index < 0 || index >= lines.length) return this;
    return ScannedReviewState(
      supplierName: supplierName,
      supplierGstin: supplierGstin,
      supplierPhone: supplierPhone,
      supplierAddress: supplierAddress,
      invoiceNumber: invoiceNumber,
      billDateRaw: billDateRaw,
      dueDateRaw: dueDateRaw,
      placeOfSupply: placeOfSupply,
      lines: [
        for (var i = 0; i < lines.length; i++)
          i == index ? mapper(lines[i]) : lines[i],
      ],
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
      confidence: confidence,
      warnings: warnings,
      model: model,
    );
  }

  /// What the editor receives. Null when nothing survived - the editor is
  /// not opened at all in that case.
  ScannedBillSeed? toSeed() {
    final name = supplierName?.trim();
    final lines = this.lines;
    if ((name == null || name.isEmpty) && lines.isEmpty) return null;
    return ScannedBillSeed(
      supplierName: (name == null || name.isEmpty) ? null : name,
      supplierGstin: supplierGstin?.trim().toUpperCase(),
      supplierPhone: supplierPhone,
      supplierAddress: supplierAddress,
      invoiceNumber: invoiceNumber?.trim().isEmpty == true
          ? null
          : invoiceNumber?.trim(),
      billDate: billDate,
      dueDate: dueDate,
      placeOfSupply: placeOfSupply,
      lines: lines,
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
    );
  }
}
