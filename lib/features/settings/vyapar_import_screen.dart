import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/services/vyapar_import.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Brings a Vyapar company across.
///
/// Vyapar's `.vyb` backup is a ZIP holding its whole SQLite database, so this
/// reads the real thing rather than a spreadsheet: parties, items, GST rates,
/// stock, invoices, bills and the money received against them. The import
/// always creates a *new* firm, so the books already on the device are never
/// touched — which is also why it needs no "this cannot be undone" warning.
class VyaparImportScreen extends ConsumerStatefulWidget {
  const VyaparImportScreen({super.key});

  @override
  ConsumerState<VyaparImportScreen> createState() =>
      _VyaparImportScreenState();
}

/// [reading] is separate from [importing] on purpose: the first is unpacking a
/// ZIP and parsing a whole foreign SQLite database — minutes on a big company,
/// with no progress to report — and the second is writing into Apex Books. Showing
/// "Importing…" for the parse told the user their books were already being
/// rewritten when nothing had been touched yet, and gave the genuine import the
/// same vague spinner.
enum _Stage { idle, ready, reading, importing, done }

class _VyaparImportScreenState extends ConsumerState<VyaparImportScreen> {
  _Stage _stage = _Stage.idle;
  String? _fileName;

  /// The bytes the preview was built from, kept so importing does not have to
  /// ask for the file a second time.
  Uint8List? _bytes;

  VyaparImportPreview? _preview;
  VyaparImportResult? _result;
  String? _error;

  // ---- Picking -----------------------------------------------------------

  Future<void> _pick() async {
    setState(() {
      _error = null;
      _result = null;
    });

    final FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['vyb'],
        withData: true,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the file picker: $error');
      return;
    }
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    // Reading, not importing: nothing is written during this stage.
    setState(() => _stage = _Stage.reading);
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } on Object catch (error) {
        if (!mounted) return;
        setState(() {
          _stage = _Stage.idle;
          _error = 'Could not read that file: $error';
        });
        return;
      }
    }
    if (bytes == null) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _error = 'That file could not be read.';
      });
      return;
    }

    final pickedBytes = bytes;
    try {
      final preview = await VyaparImportService(ref.read(appDatabaseProvider))
          .preview(pickedBytes);
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _bytes = pickedBytes;
        _preview = preview;
        _stage = preview.isEmpty ? _Stage.idle : _Stage.ready;
        _error = preview.isEmpty
            ? 'That backup has no transactions to import.'
            : null;
      });
    } on VyaparFormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _fileName = file.name;
        _preview = null;
        _stage = _Stage.idle;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _stage = _Stage.idle;
        _error = 'Could not read that backup: $error';
      });
    }
  }

  // ---- Importing ---------------------------------------------------------

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: PhosphorIcon(
          PhosphorIconsRegular.downloadSimple,
          color: atriaColors(dialogContext).brandGradientStart,
          size: 32,
        ),
        title: Text('Import ${preview.firmName}?'),
        content: Text(
          'Apex Books will create a new business called "${preview.firmName}" and '
          'copy ${preview.counts.total} records into it. The books already on '
          'this device are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final bytes = _bytes;
    if (bytes == null) return;

    setState(() => _stage = _Stage.importing);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result =
          await VyaparImportService(ref.read(appDatabaseProvider)).run(bytes);
      if (!mounted) return;
      // Open the imported books straight away: importing a company the user
      // then has to go and find in a switcher would be a strange ending.
      await ref.read(activeFirmIdProvider.notifier).select(result.firmId);
      if (!mounted) return;
      setState(() {
        _result = result;
        _stage = _Stage.done;
      });
      messenger?.showSnackBar(
        SnackBar(content: Text('Imported ${result.counts.total} records')),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.ready;
        _error = 'Import failed: $error';
      });
    }
  }

  // ---- Build -------------------------------------------------------------

  /// True while a long, uninterruptible-by-UI stage is running.
  bool get _busy =>
      _stage == _Stage.reading || _stage == _Stage.importing;

  @override
  Widget build(BuildContext context) {
    return UnsavedGuard(
      // Reading a multi-hundred-megabyte Vyapar backup can sit on a spinner for
      // minutes with nothing on screen to say why. Back is still allowed — but
      // it now asks first, so leaving is a decision rather than an accident.
      hasChanges: _busy,
      message: _stage == _Stage.importing
          ? 'An import is running. Leaving now may stop it part way through.'
          : 'Reading the backup can take a few minutes on a large company. '
              'Leaving now stops the read — nothing has been written yet.',
      child: Scaffold(
        appBar: AppBar(title: const Text('Import from Vyapar')),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.isCompact ? double.infinity : 720,
                  ),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                    children: [
                      _noteCard(),
                      const SizedBox(height: 20),
                      _fileCard(),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        _errorCard(_error!),
                      ],
                      if (_preview != null && _stage != _Stage.done) ...[
                        const SizedBox(height: 16),
                        _previewCard(_preview!),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: _busy
                              ? _ProgressButton(
                                  label: _stage == _Stage.reading
                                      ? 'Reading backup…'
                                      : 'Importing…',
                                )
                              : FilledButton.icon(
                                  onPressed: _import,
                                  icon: const Icon(
                                    Icons.download_rounded,
                                    size: 18,
                                  ),
                                  label: const Text(
                                    'Import into a new business',
                                  ),
                                ),
                        ),
                      ],
                      if (_result != null) ...[
                        const SizedBox(height: 16),
                        _resultCard(_result!),
                      ],
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _noteCard() {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      background: scheme.primaryContainer,
      showBorder: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.arrowLineDown,
            size: 20,
            color: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'In Vyapar, open Backup & Restore and create a backup — the file '
              'it saves ends in .vyb. Choose that file here and Apex Books will read '
              'the company out of it. Nothing is uploaded anywhere.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.9),
                    height: 1.5,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileCard() {
    final colors = atriaColors(context);
    final busy = _busy;
    return AtriaCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIconsRegular.fileArrowDown,
                size: 22,
                color: colors.brandGradientStart,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _fileName ?? 'Choose your Vyapar backup',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              // The spinner sits on the file card because that is the thing
              // being worked on, and it is the only visible sign that anything
              // is happening during a read that can run for minutes.
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _fileName == null
                ? 'A single .vyb file. Apex Books reads it on this device.'
                : _stage == _Stage.reading
                    // No percentage is available — the ZIP gives none — so this
                    // says what is happening and how long it can take, rather
                    // than leaving a bare spinner.
                    ? 'Unpacking the backup and reading the company out of it. '
                        'A large company can take a few minutes; nothing is '
                        'written to your books yet.'
                    : _stage == _Stage.importing
                        ? 'Writing the new business. Keep the app open until '
                            'this finishes.'
                        : 'Ready to import — check the summary below first.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : _pick,
              icon: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(_fileName == null ? 'Choose a file' : 'Choose again'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewCard(VyaparImportPreview preview) {
    final counts = preview.counts;
    return AtriaCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'What will be imported',
            subtitle: 'The numbers Apex Books read out of the backup.',
          ),
          _KeyValue(label: 'Business', value: preview.firmName),
          if (preview.gstin != null)
            _KeyValue(label: 'GSTIN', value: preview.gstin!),
          if (preview.state != null)
            _KeyValue(label: 'State', value: preview.state!),
          if (preview.from != null && preview.to != null)
            _KeyValue(
              label: 'Period',
              value: '${Formatters.date(preview.from)} — '
                  '${Formatters.date(preview.to)}',
            ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (counts.parties > 0) _CountChip('Parties', counts.parties),
              if (counts.items > 0) _CountChip('Items', counts.items),
              if (counts.saleInvoices > 0)
                _CountChip('Invoices', counts.saleInvoices),
              if (counts.quotations > 0)
                _CountChip('Quotations', counts.quotations),
              if (counts.saleOrders > 0)
                _CountChip('Sales orders', counts.saleOrders),
              if (counts.deliveryNotes > 0)
                _CountChip('Delivery notes', counts.deliveryNotes),
              if (counts.purchaseBills > 0)
                _CountChip('Purchase bills', counts.purchaseBills),
              if (counts.purchaseOrders > 0)
                _CountChip('Purchase orders', counts.purchaseOrders),
              if (counts.payments > 0)
                _CountChip('Payments', counts.payments),
              if (counts.expenses > 0)
                _CountChip('Expenses', counts.expenses),
              if (counts.categories > 0)
                _CountChip('Categories', counts.categories),
              if (counts.units > 0) _CountChip('Units', counts.units),
            ],
          ),
          if (preview.warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            _WarningList(warnings: preview.warnings),
          ],
        ],
      ),
    );
  }

  Widget _resultCard(VyaparImportResult result) {
    final colors = atriaColors(context);
    final counts = result.counts;
    return AtriaCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIconsRegular.checkCircle,
                size: 22,
                color: colors.positive,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Imported ${result.firmName}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${counts.total} records are now in Apex Books, and these books are '
            'open. Balances and stock match what Vyapar was showing.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _CountChip('Parties', counts.parties),
              _CountChip('Items', counts.items),
              _CountChip('Documents', counts.documents),
              _CountChip('Payments', counts.payments),
              _CountChip('Expenses', counts.expenses),
            ],
          ),
          if (result.warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            _WarningList(warnings: result.warnings),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => context.go('/dashboard'),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              label: const Text('Open the imported books'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () {
                setState(() {
                  _stage = _Stage.idle;
                  _result = null;
                  _preview = null;
                  _fileName = null;
                  _bytes = null;
                  _error = null;
                });
              },
              child: const Text('Import another backup'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      background: scheme.errorContainer,
      showBorder: false,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.warningCircle,
            size: 20,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                    height: 1.5,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
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

class _CountChip extends StatelessWidget {
  const _CountChip(this.label, this.count);

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$count ',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
            TextSpan(
              text: label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WarningList extends StatelessWidget {
  const _WarningList({required this.warnings});

  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Worth knowing',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5, right: 8),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.onSurfaceVariant,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      warning,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgressButton extends StatelessWidget {
  const _ProgressButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: null,
      icon: const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      label: Text(label),
    );
  }
}
