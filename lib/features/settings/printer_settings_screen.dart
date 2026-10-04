import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/printer/printer_service.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../shared/widgets/atria_content_width.dart';
import '../../shared/widgets/common_widgets.dart';

/// Where the shop's TSC and Zebra label printers are set up.
///
/// Two things have to be right before a label comes out of a thermal printer,
/// and this screen is where both are pinned down: the *protocol* (a TSC speaks
/// TSPL, a Zebra speaks ZPL, and neither understands the other) and the *label
/// geometry* (dots per inch, the physical size, and the die-cut gap). Everything
/// an operator can get wrong — a wrong IP, a wrong queue name, a 300 dpi head
/// told it is 203 — shows up as a label printed half off the sticker, so the
/// editor keeps a **test print** next to the settings that cause it.
class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() =>
      _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends ConsumerState<PrinterSettingsScreen> {
  /// Set while a probe or a test print is in flight, so the buttons can be
  /// disabled and the outcome shown against the printer that produced it.
  String? _busyId;
  ({String id, String message, bool ok})? _result;

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(printersProvider);
    final defaultId = ref.watch(defaultPrinterProvider).valueOrNull?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Label printers'),
        actions: [
          TextButton.icon(
            onPressed: () => _edit(null),
            icon: const Icon(PhosphorIconsRegular.plus),
            label: const Text('Add'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AtriaContentWidth(
        // The profile *list* needs the cap as much as the editor does: without
        // it a printer card and its action row spread across a 1920dp window
        // and the probe/test buttons end up a full screen from the printer's
        // name.
        child: printers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not read the printer settings: $error'),
            ),
          ),
          data: (profiles) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const _Intro(),
              const SizedBox(height: 16),
              if (profiles.isEmpty)
                const EmptyState(
                  icon: PhosphorIconsRegular.printer,
                  title: 'No label printer yet',
                  message:
                      'Add the TSC or Zebra printer at the counter, then print '
                      'barcode stickers straight from an item or a counter sale.',
                )
              else
                for (final profile in profiles) ...[
                  _PrinterCard(
                    profile: profile,
                    isDefault: profile.id == defaultId,
                    busy: _busyId == profile.id,
                    result: _result?.id == profile.id ? _result : null,
                    onMakeDefault: () async {
                      try {
                        await ref
                            .read(printerRegistryProvider)
                            .setDefault(profile.id);
                      } on Object catch (error) {
                        if (mounted) _snack('Could not set the default: $error');
                        return;
                      }
                      _refresh();
                    },
                    onTest: () => _run(profile, test: true),
                    onProbe: () => _run(profile, test: false),
                    onEdit: () => _edit(profile),
                    onDelete: () => _delete(profile),
                  ),
                  const SizedBox(height: 12),
                ],
            ],
          ),
        ),
      ),
    );
  }

  void _refresh() {
    ref
      ..invalidate(printersProvider)
      ..invalidate(defaultPrinterProvider);
  }

  /// Runs a test print or a reachability check and surfaces the outcome.
  ///
  /// The result is deliberately attached to the printer card rather than shown
  /// as a snack bar: an operator setting up four printers needs to see which
  /// one answered.
  ///
  /// Nothing is allowed to escape: this runs from an `onSelected` on a menu,
  /// so an exception is an unhandled zone error on a phone, and what the
  /// operator asked for was an answer.
  Future<void> _run(PrinterProfile profile, {required bool test}) async {
    final problem = profile.problem;
    if (problem != null) {
      setState(() => _result = (id: profile.id, message: problem, ok: false));
      return;
    }
    setState(() => _busyId = profile.id);
    try {
      final message = test
          ? await ThermalPrinterService.printTest(profile).then(
              (_) =>
                  'Test label sent to ${profile.name}. If nothing printed, '
                  'check the printer is on the right port and loaded with the '
                  'label size set here.',
            )
          : await ThermalPrinterService.probe(profile);
      if (mounted) {
        setState(() => _result = (id: profile.id, message: message, ok: true));
      }
    } on LabelException catch (error) {
      _fail(profile, error.message);
    } on Object catch (error) {
      _fail(profile, '$error');
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// Every failure ends up on the card, not in the log.
  void _fail(PrinterProfile profile, String reason) {
    if (!mounted) return;
    setState(
      () => _result = (
        id: profile.id,
        message: 'The printer did not answer: $reason',
        ok: false,
      ),
    );
  }

  Future<void> _edit(PrinterProfile? existing) async {
    final saved = await Navigator.of(context).push<PrinterProfile>(
      MaterialPageRoute(
        builder: (_) => PrinterEditorScreen(existing: existing),
        fullscreenDialog: true,
      ),
    );
    if (saved == null) return;
    try {
      await ref.read(printerRegistryProvider).upsert(saved);
    } on Object catch (error) {
      if (mounted) _snack('Could not save the printer: $error');
      return;
    }
    _refresh();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _delete(PrinterProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${profile.name}?'),
        content: const Text(
          'Labels will stop going to this printer. Nothing already printed is '
          'affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(printerRegistryProvider).remove(profile.id);
    } on Object catch (error) {
      if (mounted) _snack('Could not remove the printer: $error');
      return;
    }
    _refresh();
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return AtriaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Thermal barcode printers', style: text.titleSmall),
          const SizedBox(height: 6),
          Text(
            'Atria sends the printer its own language — TSPL for TSC, ZPL for '
            'Zebra — so labels come out crisp and instant instead of being '
            'rendered to a PDF and sent through a driver. A printer on the shop '
            'network is reached by its IP; a USB printer is reached through the '
            'queue Windows already has for it.',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.profile,
    required this.isDefault,
    required this.busy,
    required this.result,
    required this.onMakeDefault,
    required this.onTest,
    required this.onProbe,
    required this.onEdit,
    required this.onDelete,
  });

  final PrinterProfile profile;
  final bool isDefault;
  final bool busy;
  final ({String id, String message, bool ok})? result;
  final VoidCallback onMakeDefault;
  final VoidCallback onTest;
  final VoidCallback onProbe;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// A printer that was configured on a computer and is being looked at on a
  /// phone. Its profile is complete and its queue name is perfectly correct —
  /// there is just no Windows print spooler here to hand it to.
  bool get _unreachableHere =>
      !profile.transport.isSupportedHere && profile.queueName.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return AtriaCard(
      showBorder: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(profile.name, style: text.titleSmall),
                        ),
                        if (isDefault) ...[
                          const SizedBox(width: 8),
                          _Chip(label: 'Default', color: colors.primary),
                        ],
                        if (_unreachableHere) ...[
                          const SizedBox(width: 8),
                          _Chip(
                            label: 'Computer only',
                            color: colors.error,
                          ),
                        ] else if (profile.problem != null) ...[
                          const SizedBox(width: 8),
                          _Chip(label: 'Not configured', color: colors.error),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profile.describe,
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    if (_unreachableHere) ...[
                      const SizedBox(height: 6),
                      // Said up front rather than after a failed print: the
                      // profile is perfectly valid, so "Not configured" would
                      // send the operator looking for a typo that isn't there.
                      Text(
                        PrinterProfile.unsupportedTransportMessage,
                        style: text.bodySmall?.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                PopupMenuButton<String>(
                  onSelected: (value) => switch (value) {
                    'default' => onMakeDefault(),
                    'test' => onTest(),
                    'probe' => onProbe(),
                    'edit' => onEdit(),
                    'delete' => onDelete(),
                    _ => null,
                  },
                  itemBuilder: (context) => [
                    // A printer this device cannot reach is never made the
                    // default: `PrinterRegistry` skips it, so setting it here
                    // would look like it took and silently do nothing.
                    if (!isDefault && !_unreachableHere)
                      const PopupMenuItem(
                        value: 'default',
                        child: Text('Make default'),
                      ),
                    const PopupMenuItem(
                      value: 'test',
                      child: Text('Print a test label'),
                    ),
                    const PopupMenuItem(
                      value: 'probe',
                      child: Text('Check connection'),
                    ),
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    const PopupMenuItem(value: 'delete', child: Text('Remove')),
                  ],
                ),
            ],
          ),
          if (result != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: AppRadius.smAll,
                color: (result!.ok ? colors.primary : colors.error).withValues(
                  alpha: 0.08,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    result!.ok
                        ? PhosphorIconsRegular.checkCircle
                        : PhosphorIconsRegular.warningCircle,
                    size: 16,
                    color: result!.ok ? colors.primary : colors.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(result!.message, style: text.bodySmall)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: AppRadius.pillAll,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// The add/edit form for one printer.
///
/// A full screen rather than a dialog because it is long and because every
/// field on it can be got wrong in a way that needs the test print next to it.
class PrinterEditorScreen extends ConsumerStatefulWidget {
  const PrinterEditorScreen({super.key, this.existing});

  final PrinterProfile? existing;

  @override
  ConsumerState<PrinterEditorScreen> createState() =>
      _PrinterEditorScreenState();
}

class _PrinterEditorScreenState extends ConsumerState<PrinterEditorScreen> {
  late PrinterProfile _profile = widget.existing ?? PrinterProfile.blank;
  late final TextEditingController _name = TextEditingController(
    text: _profile.name == 'New printer' ? '' : _profile.name,
  );
  late final TextEditingController _host = TextEditingController(
    text: _profile.host,
  );
  late final TextEditingController _port = TextEditingController(
    text: _profile.port.toString(),
  );
  late final TextEditingController _width = TextEditingController(
    text: _trim(_profile.labelWidthMm),
  );
  late final TextEditingController _height = TextEditingController(
    text: _trim(_profile.labelHeightMm),
  );
  late final TextEditingController _gap = TextEditingController(
    text: _trim(_profile.gapMm),
  );

  /// A controller rather than an inline `TextEditingController(text:)` in the
  /// builder: building one per frame resets the field on every keystroke and
  /// the cursor jumps back to the start.
  late final TextEditingController _queue = TextEditingController(
    text: _profile.queueName,
  );

  List<String> _installed = const [];
  bool _loadingPrinters = false;
  String? _outcome;
  bool _outcomeOk = false;
  bool _busy = false;

  /// Set when this printer was configured on a computer and is being edited on
  /// a phone, so the editor opens on the network tab with the reason on
  /// screen instead of on a transport this device cannot use.
  bool _migratedOffQueue = false;

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  @override
  void initState() {
    super.initState();
    // A `usb` profile restored from a desktop. The transport is swapped here
    // rather than in `build`, so the segmented button, the connection fields
    // and `_save` all see the same transport — leaving it as `usb` would keep
    // showing a Windows queue picker and Windows-only copy on a phone. The
    // reason is shown next to the Connection row rather than in `_outcome`,
    // which lives down by the test-print button.
    if (!_profile.transport.isSupportedHere) {
      _profile = _profile.copyWith(transport: PrinterTransport.network);
      _migratedOffQueue = true;
    }
    if (_profile.transport == PrinterTransport.usb) {
      // Deferred to after the first frame: `setState` from `initState` runs
      // inside `buildScope`, and a debug build throws "setState() or
      // markNeedsBuild() called during build" on the very first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadInstalled();
      });
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _host,
      _port,
      _width,
      _height,
      _gap,
      _queue,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInstalled() async {
    if (mounted) setState(() => _loadingPrinters = true);
    final names = await PrinterConnection.installedPrinterNames();
    if (!mounted) return;
    setState(() {
      _installed = names;
      _loadingPrinters = false;
    });
  }

  /// Reads the form into a profile.
  ///
  /// Text fields are parsed with the *current* value as the fallback, so a
  /// half-typed port never becomes 0 and a cleared width never becomes NaN —
  /// the field simply has no effect until it holds a number.
  PrinterProfile _read() {
    final width = double.tryParse(_width.text.trim()) ?? _profile.labelWidthMm;
    final height =
        double.tryParse(_height.text.trim()) ?? _profile.labelHeightMm;
    final gap = double.tryParse(_gap.text.trim()) ?? _profile.gapMm;
    final port = int.tryParse(_port.text.trim()) ?? _profile.port;
    return _profile.copyWith(
      name: _name.text.trim().isEmpty ? 'Printer' : _name.text.trim(),
      host: _host.text.trim(),
      port: port,
      labelWidthMm: width,
      labelHeightMm: height,
      gapMm: gap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final isNew = widget.existing == null;
    final profile = _read();

    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'Add printer' : 'Edit printer'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _save,
            child: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AtriaContentWidth(
        maxWidth: 720,
        // A printer profile is a column of fields, not a table: at 1920dp a
        // text field spans ~1880px and the label settings beside it sit a
        // full screen away from the field they configure.
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                helperText: 'What the operator calls it, e.g. "Counter TSC"',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),

            const SectionHeader(
              title: 'What this printer prints',
              subtitle:
                  'Labels and receipts are different command languages — a '
                  'TSC speaks TSPL, a till-roll printer speaks ESC/POS.',
            ),
            const SizedBox(height: 8),
            SegmentedButton<PrinterKind>(
              segments: [
                for (final kind in PrinterKind.values)
                  ButtonSegment(
                    value: kind,
                    label: Text(kind.title),
                    icon: Icon(
                      kind == PrinterKind.receipt
                          ? Icons.receipt_long_rounded
                          : Icons.qr_code_2_rounded,
                    ),
                  ),
              ],
              selected: {profile.kind},
              onSelectionChanged: (value) => setState(
                () => _profile = _profile.copyWith(kind: value.first),
              ),
            ),
            const SizedBox(height: 10),
            if (profile.kind == PrinterKind.receipt) ...[
              _FieldLabel('Receipt roll', text: text),
              const SizedBox(height: 6),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 58, label: Text('58 mm (32 columns)')),
                  ButtonSegment(value: 80, label: Text('80 mm (48 columns)')),
                ],
                selected: {profile.paperWidthMm},
                onSelectionChanged: (value) => setState(
                  () => _profile = _profile.copyWith(paperWidthMm: value.first),
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: profile.cutPaper,
                onChanged: (value) => setState(
                  () => _profile = _profile.copyWith(cutPaper: value),
                ),
                title: const Text('Cut the paper after each receipt'),
                subtitle: const Text(
                  'Off for a printer with a tear bar, or while calibrating',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: profile.openDrawer,
                onChanged: (value) => setState(
                  () => _profile = _profile.copyWith(openDrawer: value),
                ),
                title: const Text('Open the cash drawer'),
                subtitle: const Text(
                  'The drawer hangs off the printer, so a cash sale can open it '
                  'as the receipt prints',
                ),
              ),
            ],
            const SizedBox(height: 18),

            const SectionHeader(title: 'Printer'),
            const SizedBox(height: 8),
            _FieldLabel('Brand', text: text),
            const SizedBox(height: 6),
            SegmentedButton<PrinterBrand>(
              segments: [
                for (final brand in PrinterBrand.values)
                  ButtonSegment(
                    value: brand,
                    label: Text('${brand.label} (${brand.language})'),
                  ),
              ],
              selected: {profile.brand},
              onSelectionChanged: (value) => setState(
                () => _profile = _profile.copyWith(brand: value.first),
              ),
            ),
            const SizedBox(height: 16),

            _FieldLabel('Connection', text: text),
            const SizedBox(height: 6),
            SegmentedButton<PrinterTransport>(
              segments: [
                // Only the transports this device can actually reach: offering
                // "USB / installed printer" on Android led the operator into
                // Windows-specific copy and an error on every single attempt.
                for (final transport in PrinterTransport.availableHere)
                  ButtonSegment(value: transport, label: Text(transport.label)),
              ],
              selected: {profile.transport},
              onSelectionChanged: (value) {
                setState(() {
                  _profile = _profile.copyWith(transport: value.first);
                  // The reason on screen was about the previous transport.
                  _migratedOffQueue = false;
                  _outcome = null;
                });
                if (value.first == PrinterTransport.usb) _loadInstalled();
              },
            ),
            if (_migratedOffQueue) ...[
              const SizedBox(height: 8),
              Text(
                PrinterProfile.unsupportedTransportMessage,
                style: text.bodySmall?.copyWith(color: colors.error),
              ),
            ],
            const SizedBox(height: 16),

            if (profile.transport == PrinterTransport.network) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _host,
                      decoration: const InputDecoration(
                        labelText: 'IP address or hostname',
                        hintText: '192.168.1.50',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        helperText: 'Raw 9100',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      // `initialValue` is read once, in `FormField.initState` —
                      // and `_installed` is empty on the first frame, because
                      // PowerShell has not answered yet. The dropdown therefore
                      // used to come up blank even though `profile.queueName`
                      // named an installed printer, and the operator either
                      // re-picked it or saved an empty `queueName` and was told
                      // "No installed printer was chosen". Keying the field on
                      // the loaded names rebuilds it once the list lands, so
                      // the configured queue is selected on arrival.
                      key: ValueKey(
                        'queue:${_installed.join('\u0000')}',
                      ),
                      initialValue: _installed
                              .any((name) => name == profile.queueName)
                          ? profile.queueName
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Installed printer',
                      ),
                      items: [
                        for (final name in _installed)
                          DropdownMenuItem(value: name, child: Text(name)),
                      ],
                      onChanged: (value) => setState(() {
                        _profile = _profile.copyWith(queueName: value ?? '');
                        _queue.text = value ?? '';
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Refresh the list',
                    onPressed: _loadingPrinters ? null : _loadInstalled,
                    icon: _loadingPrinters
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(PhosphorIconsRegular.arrowsClockwise),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_installed.isEmpty)
                Text(
                  'No installed printers were listed. Type the exact name '
                  'Windows shows under printers and scanners.',
                  style: text.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              TextField(
                controller: _queue,
                decoration: const InputDecoration(
                  labelText: 'Printer name',
                  helperText: 'Used when the list above is empty',
                ),
                onChanged: (value) => setState(
                  () => _profile = _profile.copyWith(queueName: value),
                ),
              ),
            ],
            const SizedBox(height: 18),

            const SectionHeader(
              title: 'Label setup',
              subtitle:
                  'Dots, size and gap — used when this printer prints '
                  'barcode labels.',
            ),
            const SizedBox(height: 8),
            _FieldLabel('Print head', text: text),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 203, label: Text('203 dpi')),
                ButtonSegment(value: 300, label: Text('300 dpi')),
              ],
              selected: {profile.dpi},
              onSelectionChanged: (value) => setState(
                () => _profile = _profile.copyWith(dpi: value.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              profile.dpi == 203
                  ? '203 dpi is the usual head on a TTP-244 or GK420 — 8 dots per mm.'
                  : '300 dpi needs the finer head: 11.8 dots per mm, so the same '
                        'label is laid out with about half again as many dots.',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),

            _FieldLabel('Label size', text: text),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, width, height) in PrinterProfile.sizePresets)
                  ChoiceChip(
                    label: Text(label),
                    selected:
                        profile.labelWidthMm == width &&
                        profile.labelHeightMm == height,
                    onSelected: (_) {
                      _width.text = _trim(width);
                      _height.text = _trim(height);
                      setState(
                        () => _profile = _profile.copyWith(
                          labelWidthMm: width,
                          labelHeightMm: height,
                        ),
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _width,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Width (mm)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _height,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Height (mm)'),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _gap,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Gap (mm)',
                      helperText: '0 for continuous',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            const SectionHeader(title: 'Print quality'),
            const SizedBox(height: 8),
            _Slider(
              label: 'Darkness',
              value: profile.darkness.toDouble(),
              min: 0,
              max: 15,
              divisions: 15,
              display: '${profile.darkness}',
              helper:
                  'Raise it if the bars look grey; lower it if edges bleed.',
              onChanged: (value) => setState(
                () => _profile = _profile.copyWith(darkness: value.round()),
              ),
            ),
            _Slider(
              label: 'Speed',
              value: profile.speed.toDouble(),
              min: 1,
              max: 6,
              divisions: 5,
              display: '${profile.speed} in/s',
              helper: 'Slower prints darker on glossy stock.',
              onChanged: (value) => setState(
                () => _profile = _profile.copyWith(speed: value.round()),
              ),
            ),
            _Slider(
              label: 'Copies per label',
              value: profile.copies.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              display: '${profile.copies}',
              helper: 'A counter sale multiplies this by the quantity sold.',
              onChanged: (value) => setState(
                () => _profile = _profile.copyWith(copies: value.round()),
              ),
            ),
            _Slider(
              label: 'Nudge across',
              value: profile.offsetXMm,
              min: -10,
              max: 10,
              divisions: 40,
              display: '${profile.offsetXMm.toStringAsFixed(1)} mm',
              helper:
                  'Moves the whole label sideways when the print sits off '
                  'centre.',
              onChanged: (value) => setState(
                () => _profile = _profile.copyWith(offsetXMm: value),
              ),
            ),
            _Slider(
              label: 'Nudge down',
              value: profile.offsetYMm,
              min: -10,
              max: 10,
              divisions: 40,
              display: '${profile.offsetYMm.toStringAsFixed(1)} mm',
              helper:
                  'Moves the whole label up or down when the gap sensor '
                  'stops early.',
              onChanged: (value) => setState(
                () => _profile = _profile.copyWith(offsetYMm: value),
              ),
            ),
            const SizedBox(height: 8),
            AtriaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The label is laid out for ${profile.labelWidthDots} × '
                    '${profile.labelHeightDots} dots.',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _check(profile),
                        icon: const Icon(PhosphorIconsRegular.wifiHigh),
                        label: const Text('Check connection'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : () => _test(profile),
                        icon: const Icon(PhosphorIconsRegular.printer),
                        label: const Text('Print a test label'),
                      ),
                    ],
                  ),
                  if (_outcome != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _outcomeOk
                              ? PhosphorIconsRegular.checkCircle
                              : PhosphorIconsRegular.warningCircle,
                          size: 16,
                          color: _outcomeOk ? colors.primary : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_outcome!, style: text.bodySmall)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(isNew ? 'Add printer' : 'Save changes'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _check(PrinterProfile profile) async {
    final problem = profile.problem;
    if (problem != null) {
      setState(() {
        _outcome = problem;
        _outcomeOk = false;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      final message = await ThermalPrinterService.probe(profile);
      if (mounted) {
        setState(() {
          _outcome = message;
          _outcomeOk = true;
        });
      }
    } on LabelException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      // `Socket.connect` also raises TimeoutException against a firewall that
      // DROPs the SYN, and a bad port raises ArgumentError; neither is a
      // LabelException, and neither may escape an onPressed.
      _fail('The printer did not answer: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test(PrinterProfile profile) async {
    final problem = profile.problem;
    if (problem != null) {
      setState(() {
        _outcome = problem;
        _outcomeOk = false;
      });
      return;
    }
    setState(() => _busy = true);
    try {
      await ThermalPrinterService.printTest(profile);
      if (mounted) {
        setState(() {
          _outcome =
              'Test label sent. If it came out blank, too light, or off '
              'the sticker, adjust the label size and darkness above.';
          _outcomeOk = true;
        });
      }
    } on LabelException catch (error) {
      _fail(error.message);
    } on Object catch (error) {
      _fail('The label could not be printed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Shows [message] against the editor's own result line, which sits beside
  /// the test-print button that was pressed.
  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _outcome = message;
      _outcomeOk = false;
    });
  }

  void _save() {
    final profile = _read();
    // Belt and braces: `initState` has already moved an unsupported transport
    // to `network`, but `_read` is what is saved, and a profile that cannot be
    // sent to must not leave here looking configured.
    if (!profile.transport.isSupportedHere) {
      setState(() {
        _outcome = PrinterProfile.unsupportedTransportMessage;
        _outcomeOk = false;
      });
      return;
    }
    if (profile.problem != null) {
      setState(() {
        _outcome = profile.problem;
        _outcomeOk = false;
      });
      return;
    }
    Navigator.of(context).pop(profile);
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, {required this.text});

  final String label;
  final TextTheme text;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: text.labelMedium?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.helper,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final String helper;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: text.bodyMedium)),
            Text(display, style: text.bodyMedium),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
        Text(
          helper,
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}
