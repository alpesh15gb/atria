import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/server_client.dart' show ServerRequestException;
import '../../core/database/app_database.dart';
import '../../core/sync/scan_seed.dart';
import '../../core/state/providers.dart';
import '../../core/utils/id_utils.dart';
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

  /// The item catalogue the per-line matcher offers. A scanned description is
  /// fuzzy text from a vision model, so the reviewer picks which catalogue row
  /// a line IS — without that the line saves with no `itemId` and moves no
  /// stock at all (see [CataloguedBillSeed]).
  List<ItemEntity> _catalogue = const [];

  /// One controller per editable field, owned here. They used to be built
  /// inside `build`, which allocated a fresh set on every keystroke (and
  /// forced the caret to the end, so editing mid-string jumped); they are also
  /// never reset by a rebuild, so what the reviewer types sticks.
  final Map<String, TextEditingController> _headerControllers = {};
  final Map<String, TextEditingController> _lineControllers = {};

  Future<void> _loadCatalogue() async {
    final repo = ref.read(itemRepositoryProvider);
    if (repo == null) return;
    final items = await repo.all(limit: 1000);
    if (mounted) setState(() => _catalogue = items);
  }

  /// A header field's controller, created once with [value] and then left
  /// alone: the review state is the record of what survived, and a rebuild
  /// must never rewrite what is being typed (the GSTIN field is upper-cased as
  /// it is stored, so echoing the state back into the field would fight the
  /// keyboard).
  TextEditingController _headerController(String key, String? value) {
    final existing = _headerControllers[key];
    if (existing != null) return existing;
    final created = TextEditingController(text: value ?? '');
    _headerControllers[key] = created;
    return created;
  }

  /// A line field's controller, keyed by the LINE's stable id rather than its
  /// position — after a deletion the surviving card must keep the numbers the
  /// reviewer typed into it.
  TextEditingController _lineNumController(String key, double value) {
    final existing = _lineControllers[key];
    if (existing != null) return existing;
    final created = TextEditingController(
      text: value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : '$value',
    );
    _lineControllers[key] = created;
    return created;
  }

  /// Drops every field controller — used when a re-scan replaces the reading,
  /// so the new values land in fresh fields instead of behind the old text.
  void _resetFieldControllers() {
    for (final controller in [
      ..._headerControllers.values,
      ..._lineControllers.values,
    ]) {
      controller.dispose();
    }
    _headerControllers.clear();
    _lineControllers.clear();
  }

  @override
  void initState() {
    super.initState();
    // The matcher's catalogue is loaded up front, so a line the reviewer has
    // not scrolled to yet already offers its candidates.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalogue());
  }

  @override
  void dispose() {
    _resetFieldControllers();
    super.dispose();
  }

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
    // Not `accessToken()`: a null token means two different things, and this
    // screen used to report the wrong one. Being offline reads as "Sign in to
    // Atria", which is both untrue and unactionable — the fix is to try again
    // on a better connection, not to sign in again.
    final session = await ref
        .read(authControllerProvider.notifier)
        .resolveAccessToken();
    final token = session.accessToken;
    if (token == null) {
      if (!mounted) return;
      setState(() {
        _error = session.temporarilyUnavailable
            ? 'Could not reach Atria to scan this bill. The reading happens on '
                'the Atria server, not on this device - check your connection '
                'and try again.'
            : 'Sign in to Atria to scan bills - the reading happens on the '
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
      _resetFieldControllers();
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
  ///
  /// Every value the seed carries gets a field here. `dueDate`,
  /// `shippingCharge` and `otherCharges` used to be seeded with no review field
  /// at all — they were written straight into the editor's controllers, so
  /// three of the numbers the bill is worth were unexamined (D23).
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
            field: 'supplier',
            label: 'Supplier',
            value: r.supplierName,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(supplierName: () => v)),
          ),
          _reviewField(
            field: 'gstin',
            label: 'GSTIN',
            value: r.supplierGstin,
            onChanged: (v) => setState(() =>
                _review = _review.copyWith(supplierGstin: () => v.toUpperCase())),
            // Only a value that IS present can be malformed. `isValidGstin(null)`
            // is false, so passing a null straight to errorText painted a red
            // "Not a valid GSTIN format" under a field nobody had touched —
            // while most suppliers are unregistered and have no GSTIN at all.
            trailingError:
                (r.supplierGstin ?? '').trim().isEmpty ||
                        Validators.isValidGstin(r.supplierGstin)
                    ? null
                    : 'Not a valid GSTIN format',
          ),
          _reviewField(
            field: 'invoiceNumber',
            label: 'Bill number',
            value: r.invoiceNumber,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(invoiceNumber: () => v)),
          ),
          _reviewField(
            field: 'billDate',
            label: 'Bill date (YYYY-MM-DD)',
            value: r.billDateRaw,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(billDateRaw: () => v)),
          ),
          _reviewField(
            field: 'dueDate',
            label: 'Due date (YYYY-MM-DD)',
            value: r.dueDateRaw,
            hintText: 'Leave empty if it is payable on delivery',
            onChanged: (v) => setState(
                () => _review = _review.copyWith(dueDateRaw: () => v)),
          ),
          _reviewField(
            field: 'placeOfSupply',
            label: 'Place of supply (state code)',
            value: r.placeOfSupply,
            onChanged: (v) => setState(
                () => _review = _review.copyWith(placeOfSupply: () => v)),
          ),
          _reviewField(
            field: 'shippingCharge',
            label: 'Shipping / freight',
            value: r.shippingCharge == 0 ? null : '${r.shippingCharge}',
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() => _review = _review.copyWith(
                shippingCharge: () => double.tryParse(v.trim()) ?? 0)),
          ),
          _reviewField(
            field: 'otherCharges',
            label: 'Other charges',
            value: r.otherCharges == 0 ? null : '${r.otherCharges}',
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            onChanged: (v) => setState(() => _review = _review.copyWith(
                otherCharges: () => double.tryParse(v.trim()) ?? 0)),
          ),
        ],
      ),
    );
  }

  Widget _reviewField({
    required String field,
    required String label,
    required String? value,
    required ValueChanged<String> onChanged,
    String? hintText,
    TextInputType? keyboardType,
    String? trailingError,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        // State-owned: created once with the model's reading and never rebuilt
        // from the review state, so the caret stays where the reviewer put it.
        controller: _headerController(field, value),
        onChanged: onChanged,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hintText,
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
              // Keyed by the line's stable id, so removing line 0 does not make
              // the survivors show one line's numbers against another's state.
              _lineReview(i),
          if (_review.lines.isNotEmpty && _review.linkedCount < _review.lines.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${_review.lines.length - _review.linkedCount} line(s) are '
                'not linked to an item. They still save — a shop buys things it '
                'does not stock — but they will not change stock levels.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.4,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  void _removeLine(String lineId) {
    final index = _review.lineIds.indexOf(lineId);
    if (index < 0 || index >= _review.lines.length) return;
    // The removed line's fields go with it, controllers included.
    for (final key in _lineControllers.keys.toList()) {
      if (key.startsWith('$lineId|')) {
        _lineControllers.remove(key)!.dispose();
      }
    }
    setState(() => _review = _review.withoutLine(index));
  }

  Widget _lineReview(int index) {
    final line = _review.lines[index];
    final lineId = _review.lineIds[index];
    final scheme = Theme.of(context).colorScheme;
    return Card(
      // Stable per line, not positional: see _removeLine.
      key: ValueKey('scan-line-$lineId'),
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
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
                  onPressed: () => _removeLine(lineId),
                  icon: const PhosphorIcon(PhosphorIconsRegular.trash, size: 17),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _lineNumField(
                    field: '$lineId|qty',
                    label: 'Qty',
                    initial: line.quantity,
                    onChanged: (v) => setState(() =>
                        _review = _review.withLineQuantity(lineId, v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _lineNumField(
                    field: '$lineId|rate',
                    label: 'Rate',
                    initial: line.rate,
                    onChanged: (v) => setState(
                        () => _review = _review.withLineRate(lineId, v)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _lineNumField(
                    field: '$lineId|gst',
                    label: 'GST %',
                    initial: line.gstRate,
                    onChanged: (v) =>
                        setState(() => _review = _review.withLineGst(lineId, v)),
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
            const SizedBox(height: 8),
            _itemMatcher(lineId, line, index),
          ],
        ),
      ),
    );
  }

  /// The catalogue link for one line: what it resolved to, or the candidates a
  /// reviewer can pick from. A line with no link saves fine but moves no stock,
  /// so the state of this control is part of reviewing the bill — not a detail.
  Widget _itemMatcher(String lineId, ScannedLineSeed line, int index) {
    final scheme = Theme.of(context).colorScheme;
    final linkedId = _review.lineItemIds[index];
    final linked = linkedId == null
        ? null
        : _catalogue.where((i) => i.id == linkedId).firstOrNull;
    final candidates = _itemCandidates(line);
    const noLink = '__no_item__';
    // The current link is always one of the options, even when the catalogue
    // has moved on and it is no longer a candidate: the reviewer must be able to
    // see what the line is linked to (and unlink it), and a value that is not
    // among the items asserts.
    final value = linked == null ? noLink : linked.id;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          isExpanded: true,
          isDense: true,
          // Keyed by the line so the dropdown's own state follows the line it
          // belongs to when an earlier line is removed.
          key: ValueKey('scan-line-item-$lineId'),
          initialValue: value,
          decoration: const InputDecoration(
            labelText: 'Match to item (moves stock)',
            isDense: true,
          ),
          items: [
            const DropdownMenuItem<String>(
              value: noLink,
              child: Text('Not linked to an item'),
            ),
            if (linked != null)
              DropdownMenuItem<String>(
                value: linked.id,
                child: Text(
                  linked.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            for (final item in candidates)
              if (item.id != linkedId)
                DropdownMenuItem<String>(
                  value: item.id,
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
          onChanged: (next) => setState(() => _review = _review.withLineItem(
              lineId,
              next == null || next == noLink ? null : next,
            )),
        ),
        const SizedBox(height: 4),
        Text(
          linked == null
              ? (candidates.isEmpty
                    ? 'No catalogue item looks like this line. It will save '
                        'without touching stock.'
                    : 'No item picked. It will save without touching stock.')
              // Services and untracked goods carry no stock at all, so saying
              // "moves stock" here would be a promise the save cannot keep.
              : linked.isService || linked.stockType != 'tracked'
                  ? 'Linked to ${linked.name} — ${linked.isService ? 'a service' : 'untracked stock'} '
                      'carries no quantity, so this line does not change stock.'
                  : 'Linked to ${linked.name} — its stock is updated on save.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: linked != null ? scheme.primary : scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  /// The catalogue rows worth offering for a scanned line, best first.
  ///
  /// Loose (substring) matching on purpose — the description came off a photo
  /// through a vision model, so "SURF EXCEL 1KG" has to find "Surf Excel 1 kg".
  /// An exact identity match always wins; after that, name prefixes, then any
  /// name/SKU/HSN/barcode containing the query.
  List<ItemEntity> _itemCandidates(ScannedLineSeed line) {
    final query = line.name.trim().toLowerCase();
    if (query.isEmpty || _catalogue.isEmpty) return const [];
    final scored = <(int, ItemEntity)>[];
    for (final item in _catalogue) {
      final name = item.name.trim().toLowerCase();
      final sku = (item.sku ?? '').trim().toLowerCase();
      final hsn = (item.hsn ?? '').trim().toLowerCase();
      final barcode = (item.barcode ?? '').trim().toLowerCase();
      int rank;
      if (name == query || sku == query || hsn == query || barcode == query) {
        rank = 0;
      } else if (name.startsWith(query)) {
        rank = 1;
      } else if (name.contains(query)) {
        rank = 2;
      } else if (query.contains(name) && name.isNotEmpty) {
        rank = 3;
      } else if (sku.contains(query) ||
          hsn.contains(query) ||
          barcode.contains(query)) {
        rank = 4;
      } else {
        continue;
      }
      scored.add((rank, item));
    }
    scored.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      return byRank != 0 ? byRank : a.$2.name.compareTo(b.$2.name);
    });
    return [
      for (final (_, item) in scored.take(8)) item,
    ];
  }

  Widget _lineNumField({
    required String field,
    required String label,
    required double initial,
    required ValueChanged<double> onChanged,
  }) {
    return TextFormField(
      controller: _lineNumController(field, initial),
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
///
/// [lineIds] and [lineItemIds] are index-aligned with [lines]. The id is what
/// makes an edit address a LINE rather than a position: deleting line 0 used to
/// leave every surviving field showing the previous line's numbers while its
/// `onChanged` wrote into whatever line had slid into that slot.
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
    required this.lineIds,
    required this.lineItemIds,
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

  /// Stable per line, assigned once when the reading arrives. Never reused, and
  /// never re-ordered.
  final List<String> lineIds;

  /// The catalogue item the reviewer linked each line to (null = unlinked).
  /// Index-aligned with [lines]; this is what lets the saved bill move stock.
  final List<String?> lineItemIds;

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
    lineIds: const [],
    lineItemIds: const [],
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

  /// How many lines the reviewer linked to a catalogue item. The rest save as
  /// free-text lines and move no stock.
  int get linkedCount => lineItemIds.where((id) => id != null).length;

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
      // One id per line, minted here and never re-minted: everything below
      // addresses lines by id.
      lineIds: [for (final _ in bill.lines) IdUtils.newId()],
      lineItemIds: [for (final _ in bill.lines) null],
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
    String? Function()? dueDateRaw,
    String? Function()? placeOfSupply,
    double Function()? shippingCharge,
    double Function()? otherCharges,
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
        // dueDate / shipping / other charges had no field on the review screen
        // and so could never be corrected, although they were written straight
        // into the editor.
        dueDateRaw: dueDateRaw == null ? this.dueDateRaw : dueDateRaw(),
        placeOfSupply:
            placeOfSupply == null ? this.placeOfSupply : placeOfSupply(),
        lines: lines,
        lineIds: lineIds,
        lineItemIds: lineItemIds,
        shippingCharge:
            shippingCharge == null ? this.shippingCharge : shippingCharge(),
        otherCharges:
            otherCharges == null ? this.otherCharges : otherCharges(),
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
      lineIds: [...lineIds]..removeAt(index),
      lineItemIds: [...lineItemIds]..removeAt(index),
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
      confidence: confidence,
      warnings: warnings,
      model: model,
    );
  }

  ScannedReviewState withLineQuantity(String lineId, double value) =>
      _mapLine(lineId, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: value, rate: l.rate,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: l.gstRate, cessRate: l.cessRate,
          ));

  ScannedReviewState withLineRate(String lineId, double value) =>
      _mapLine(lineId, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: l.quantity, rate: value,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: l.gstRate, cessRate: l.cessRate,
          ));

  ScannedReviewState withLineGst(String lineId, double value) =>
      _mapLine(lineId, (l) => ScannedLineSeed(
            name: l.name, hsn: l.hsn, quantity: l.quantity, rate: l.rate,
            unit: l.unit, discountPercent: l.discountPercent,
            gstRate: value, cessRate: l.cessRate,
          ));

  /// Records the catalogue row a line is linked to (null clears the link).
  ScannedReviewState withLineItem(String lineId, String? itemId) {
    final index = lineIds.indexOf(lineId);
    if (index < 0 || index >= lineItemIds.length) return this;
    return ScannedReviewState(
      supplierName: supplierName,
      supplierGstin: supplierGstin,
      supplierPhone: supplierPhone,
      supplierAddress: supplierAddress,
      invoiceNumber: invoiceNumber,
      billDateRaw: billDateRaw,
      dueDateRaw: dueDateRaw,
      placeOfSupply: placeOfSupply,
      lines: lines,
      lineIds: lineIds,
      lineItemIds: [
        for (var i = 0; i < lineItemIds.length; i++)
          i == index ? itemId : lineItemIds[i],
      ],
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
      confidence: confidence,
      warnings: warnings,
      model: model,
    );
  }

  ScannedReviewState _mapLine(
    String lineId,
    ScannedLineSeed Function(ScannedLineSeed) mapper,
  ) {
    final index = lineIds.indexOf(lineId);
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
      // An edit to a line's numbers never moves it, and never unlinks it.
      lineIds: lineIds,
      lineItemIds: lineItemIds,
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
      confidence: confidence,
      warnings: warnings,
      model: model,
    );
  }

  /// What the editor receives. Null when nothing survived - the editor is
  /// not opened at all in that case.
  ///
  /// Always a [CataloguedBillSeed] so the per-line catalogue picks the reviewer
  /// made here survive into the bill (and its stock movements).
  CataloguedBillSeed? toSeed() {
    final name = supplierName?.trim();
    final lines = this.lines;
    if ((name == null || name.isEmpty) && lines.isEmpty) return null;
    return CataloguedBillSeed(
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
      lineItemIds: lineItemIds,
      shippingCharge: shippingCharge,
      otherCharges: otherCharges,
    );
  }
}

/// A [ScannedBillSeed] that also carries, per line, the catalogue item the
/// reviewer picked on the review screen.
///
/// Without it a scanned line arrives in the editor as free text with a null
/// `itemId`, and the save path skips it (`if (line.itemId == null …) continue;`)
/// — the bill looks complete, the list shows it, and no stock ever moves. The
/// seed's own line class has no room for the pick, so the choice travels in
/// this subclass, index-aligned with [ScannedBillSeed.lines].
class CataloguedBillSeed extends ScannedBillSeed {
  const CataloguedBillSeed({
    required super.lines,
    required this.lineItemIds,
    super.supplierName,
    super.supplierGstin,
    super.supplierPhone,
    super.supplierAddress,
    super.invoiceNumber,
    super.billDate,
    super.dueDate,
    super.placeOfSupply,
    super.shippingCharge,
    super.otherCharges,
  });

  /// Catalogue item id per line, null where the reviewer left it unlinked.
  final List<String?> lineItemIds;
}

/// Resolves one scanned line to a catalogue item on exact identity, ignoring
/// case and surrounding whitespace.
///
/// Deliberately strict, and deliberately ambiguous-hostile: this runs without
/// a human in the loop, and a wrong match moves the WRONG item's stock, which
/// is worse than moving none. Keys are tried in trust order — barcode, SKU,
/// name, HSN — and a key only counts when exactly one live item answers it, so
/// two items sharing a name (or the many items that legitimately share an HSN)
/// produce no match rather than an arbitrary one. Anything this refuses, the
/// review screen offers as a choice and the editor says out loud that the line
/// will not move stock.
ItemEntity? matchScannedItem(
  List<ItemEntity> items,
  ScannedLineSeed line,
) {
  final description = line.name.trim().toLowerCase();
  if (description.isNotEmpty) {
    // The scanned line carries only a description, so identity is matched
    // against the three keys a description can legitimately BE on the bill.
    final match = _uniqueItem(items, (item) {
      return item.name.trim().toLowerCase() == description ||
          (item.sku ?? '').trim().toLowerCase() == description ||
          (item.barcode ?? '').trim().toLowerCase() == description;
    });
    if (match != null) return match;
  }
  // The scanned HSN is a strong key, but it is read off a photo too, so it is
  // only ever tried when the description identified nothing.
  final hsn = (line.hsn ?? '').trim().toLowerCase();
  if (hsn.isEmpty) return null;
  return _uniqueItem(
      items, (item) => (item.hsn ?? '').trim().toLowerCase() == hsn);
}

ItemEntity? _uniqueItem(
  List<ItemEntity> items,
  bool Function(ItemEntity) test,
) {
  ItemEntity? found;
  for (final item in items) {
    if (!test(item)) continue;
    if (found != null) return null; // ambiguous: never guess
    found = item;
  }
  return found;
}
