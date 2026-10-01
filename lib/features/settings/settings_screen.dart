import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/api_config.dart';
import '../../core/api/server_probe.dart';
import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/database/repositories/settings_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/services/csv_export.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_logo.dart';
import '../../shared/widgets/common_widgets.dart';
import 'sign_in_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _switchExpanded = false;
  bool _syncEnabled = false;
  bool _syncLoading = true;
  bool _probing = false;
  /// Inline error for the server address, from [ApiConfig.validateBaseUrl].
  String? _apiUrlError;
  /// Result of the last connection test: null = not run yet.
  String? _probeMessage;
  bool? _probeOk;
  /// True when the address in use was chosen on this device rather than being
  /// the built-in default. The field shows the effective address either way, so
  /// this only affects the caption — but the caption should not claim the user
  /// set something they did not.
  bool _apiUrlIsCustom = false;
  String _deviceLabel = 'This device: —';
  bool _backingUp = false;
  bool _exporting = false;
  bool _purging = false;
  bool _syncing = false;
  String? _exportResult;
  DateTime? _lastBackup;
  PackageInfo? _packageInfo;

  late final TextEditingController _apiUrlController;

  @override
  void initState() {
    super.initState();
    _apiUrlController = TextEditingController();
    _loadSettings();
  }

  @override
  void dispose() {
    _apiUrlController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final db = ref.read(appDatabaseProvider);
    final syncEnabled =
        await db.settingsRepository.getBool(SettingsRepository.kSyncEnabled);
    final storedUrl =
        await db.settingsRepository.get(SettingsRepository.kApiBaseUrl);
    final stamp =
        await db.settingsRepository.get(SettingsRepository.kLastBackupAt);
    final info = await PackageInfo.fromPlatform();

    // Show the address actually in force rather than the raw setting: when the
    // setting is unset, or supplied by --dart-define, the field must still show
    // what the app will really talk to or this screen is quietly lying.
    final api = ref.read(apiConfigProvider);
    final effectiveUrl = await api.baseUrl();
    // Defensive: minting the device id writes to the database, and a failed
    // write must not leave this section stuck on its spinner for ever — the
    // address field above is still perfectly usable without an identity.
    String deviceLabel;
    try {
      final deviceName = await api.deviceName();
      final deviceId = await api.deviceId();
      deviceLabel = 'This device: $deviceName · ${deviceId.split('-').first}';
    } catch (error) {
      deviceLabel = 'This device has no identity yet.';
    }

    if (!mounted) return;
    setState(() {
      _syncEnabled = syncEnabled;
      _apiUrlController.text = effectiveUrl;
      _apiUrlIsCustom = (storedUrl ?? '').trim().isNotEmpty;
      // The short id is what a support request can quote to revoke one device
      // without signing every other one out.
      _deviceLabel = deviceLabel;
      _lastBackup =
          stamp == null ? null : DateTime.tryParse(stamp)?.toLocal();
      _packageInfo = info;
      _syncLoading = false;
    });
  }

  Future<void> _backupNow() async {
    setState(() => _backingUp = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      final path = await db.backupRepository.exportToFile();
      final stamp = DateTime.now();
      await db.settingsRepository.set(
        SettingsRepository.kLastBackupAt,
        stamp.toUtc().toIso8601String(),
      );
      if (!mounted) return;
      setState(() => _lastBackup = stamp);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Backup saved to ${Formatters.ellipsis(path, 48)}'),
          action: SnackBarAction(
            label: 'Manage',
            onPressed: () => context.push('/settings/backup'),
          ),
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Backup failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _exportCsv() async {
    setState(() => _exporting = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      final firmId = ref.read(activeFirmIdProvider);
      if (firmId == null) {
        messenger?.showSnackBar(const SnackBar(
            content: Text('Open a business before exporting.')));
        return;
      }
      final export = CsvExport(db, firmId);
      final files = [
        await export.parties(),
        await export.items(),
        await export.sales(),
        await export.purchases(),
        await export.expenses(),
      ];
      if (!mounted) return;
      setState(() => _exportResult =
          '5 files exported to ${Formatters.ellipsis(files.first.parent.path, 40)}');
      messenger?.showSnackBar(SnackBar(
        content: Text('Exported to ${Formatters.ellipsis(
            files.first.parent.path, 52)}'),
        action: SnackBarAction(
          label: 'Open folder file',
          onPressed: () => OpenFilex.open(files.first.parent.path),
        ),
      ));
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Export failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// The purge endpoint: permanently deletes every row in the recycle bin.
  /// Blocked behind typing PURGE, date-lock aware per row (locked rows are
  /// counted and reported, not silently skipped), and audited once.
  Future<void> _confirmEmptyRecycleBin() async {
    final db = ref.read(appDatabaseProvider);
    final firmId = ref.read(activeFirmIdProvider);
    if (firmId == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('Open a business first.')));
      return;
    }

    // A read-only peek at what would go, so the dialog names its cost.
    Future<int> countAll() async {
      final docs = await (db.select(db.salesInvoices)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final bills = await (db.select(db.purchaseBills)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final pays = await (db.select(db.payments)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final exps = await (db.select(db.expenses)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final prts = await (db.select(db.parties)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final itms = await (db.select(db.items)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      return docs.length +
          bills.length +
          pays.length +
          exps.length +
          prts.length +
          itms.length;
    }

    final total = await countAll();
    if (!mounted) return;
    if (total == 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('The recycle bin is already empty.')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var typed = '';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Empty the recycle bin?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$total deleted item(s) will be permanently destroyed — '
                  'documents, payments, parties and items. This cannot be '
                  'undone.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Type PURGE to confirm.',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                TextField(
                  autofocus: true,
                  onChanged: (v) => setDialogState(() => typed = v.trim()),
                  decoration: const InputDecoration(hintText: 'PURGE'),
                ),
              ],
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
                onPressed: typed == 'PURGE'
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: const Text('Delete forever'),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _purgeAll();
  }

  Future<void> _purgeAll() async {
    setState(() => _purging = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      final firmId = ref.read(activeFirmIdProvider)!;
      var purged = 0;
      var locked = 0;

      Future<void> purgeEach(
        List rows,
        Future<void> Function(String) purge,
      ) async {
        for (final row in rows) {
          try {
            await purge(row.id as String);
            purged++;
          } on StateError {
            locked++; // date inside a locked period
          }
        }
      }

      final sales = db.salesRepositoryFor(firmId);
      final purchases = db.purchaseRepositoryFor(firmId);
      final paymentsRepo = db.paymentRepositoryFor(firmId);
      final expensesRepo = db.expenseRepositoryFor(firmId);
      final partiesRepo = db.partyRepositoryFor(firmId);
      final itemsRepo = db.itemRepositoryFor(firmId);

      final docRows = await (db.select(db.salesInvoices)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final billRows = await (db.select(db.purchaseBills)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final payRows = await (db.select(db.payments)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final expRows = await (db.select(db.expenses)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final partyRows = await (db.select(db.parties)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();
      final itemRows = await (db.select(db.items)
            ..where((t) =>
                t.firmId.equals(firmId) & t.isDeleted.equals(true)))
          .get();

      await purgeEach(docRows, (id) => sales.purge(id));
      await purgeEach(billRows, (id) => purchases.purge(id));
      await purgeEach(payRows, (id) => paymentsRepo.deleteForever(id));
      await purgeEach(expRows, (id) => expensesRepo.deleteForever(id));
      await purgeEach(partyRows, (id) => partiesRepo.deleteForever(id));
      await purgeEach(itemRows, (id) => itemsRepo.deleteForever(id));

      await db.auditRepository.log(
        action: 'purge',
        entity: 'recycle_bin',
        firmId: firmId,
        summary:
            'Emptied the recycle bin: $purged purged, $locked refused '
            '(locked period)',
      );
      if (!mounted) return;
      messenger?.showSnackBar(SnackBar(
        content: Text(locked == 0
            ? 'Recycle bin emptied ($purged deleted forever)'
            : 'Purged $purged; $locked skipped (dates in a locked period)'),
      ));
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not empty the bin: $error')),
      );
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  Future<void> _selectFirm(String firmId) async {
    await ref.read(activeFirmIdProvider.notifier).select(firmId);
    await ref.read(appDatabaseProvider).firmRepository.setDefault(firmId);
    if (!mounted) return;
    setState(() => _switchExpanded = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Switched business')),
    );
  }

  Future<void> _toggleSync(bool value) async {
    setState(() => _syncEnabled = value);
    await ref
        .read(appDatabaseProvider)
        .settingsRepository
        .setBool(SettingsRepository.kSyncEnabled, value);
  }

  @override
  Widget build(BuildContext context) {
    final firmAsync = ref.watch(activeFirmProvider);
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 720,
                ),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    _businessSection(firmAsync),
                    const SizedBox(height: 24),
                    _appearanceSection(themeMode),
                    const SizedBox(height: 24),
                    _dataSection(),
                    const SizedBox(height: 24),
                    _accountSection(),
                    const SizedBox(height: 24),
                    _syncSection(),
                    const SizedBox(height: 24),
                    _aboutSection(),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- Business ----------------------------------------------------------

  Widget _businessSection(AsyncValue<FirmEntity?> firmAsync) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Business'),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: firmAsync.isLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              : _firmBody(firmAsync.valueOrNull),
        ),
      ],
    );
  }

  Widget _firmBody(FirmEntity? firm) {
    final scheme = Theme.of(context).colorScheme;
    final state = IndianStates.byCode(firm?.stateCode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius:
                    const BorderRadius.all(Radius.circular(AppRadius.md)),
              ),
              alignment: Alignment.center,
              child: PhosphorIcon(
                PhosphorIconsRegular.buildings,
                size: 20,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    firm?.name ?? 'No business selected',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (firm?.gstin != null &&
                          firm!.gstin!.trim().isNotEmpty)
                        firm.gstin!.toUpperCase(),
                      if (state != null) state.name,
                      if (firm?.city != null && firm!.city!.isNotEmpty)
                        firm.city,
                    ].join('  •  '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => context.push('/settings/firm'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Edit firm profile'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _switchFirmTile(),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: () => context.push('/onboarding/firm-setup'),
            icon: const Icon(Icons.add_business_outlined, size: 18),
            label: const Text('Add another business'),
          ),
        ),
      ],
    );
  }

  Widget _switchFirmTile() {
    final firmsAsync = ref.watch(allFirmsProvider);
    final activeId = ref.watch(activeFirmIdProvider);
    final scheme = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? AppShadows.darkCard
            : AppShadows.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _switchExpanded = !_switchExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIconsRegular.swap,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Switch firm',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _switchExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _switchExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: firmsAsync.isLoading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Divider(color: scheme.outline, height: 1),
                      for (final firm in firmsAsync.valueOrNull ?? const [])
                        _firmRadioTile(
                          firm: firm,
                          selected: firm.id == activeId,
                        ),
                      if ((firmsAsync.valueOrNull ?? const []).isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('No firms yet'),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _firmRadioTile({required FirmEntity firm, required bool selected}) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: selected ? null : () => _selectFirm(firm.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 18,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    firm.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                  ),
                  if (firm.gstin != null && firm.gstin!.trim().isNotEmpty)
                    Text(
                      firm.gstin!.toUpperCase(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                ],
              ),
            ),
            if (firm.isDefault)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.pill)),
                ),
                child: Text(
                  'Default',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Appearance --------------------------------------------------------

  Widget _appearanceSection(ThemeMode mode) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Appearance'),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Theme',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.system,
                    label: Text('System'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (selection) => ref
                    .read(themeModeProvider.notifier)
                    .set(selection.first),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Data & backup -----------------------------------------------------

  Widget _dataSection() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Data & backup'),
        AtriaCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.floppyDisk,
                  color: scheme.primary,
                ),
                title: const Text('Backup & Restore'),
                subtitle: Text(
                  _lastBackup == null
                      ? 'Export or restore a JSON backup'
                      : 'Last backed up ${Formatters.dateTime(_lastBackup)}',
                  style: TextStyle(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/backup'),
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _backingUp
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : PhosphorIcon(
                        PhosphorIconsRegular.arrowClockwise,
                        color: scheme.primary,
                      ),
                title: const Text('Backup now'),
                subtitle: const Text('Save everything to this device'),
                enabled: !_backingUp,
                onTap: _backupNow,
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.arrowsDownUp,
                  color: scheme.primary,
                ),
                title: const Text('Import from Vyapar'),
                subtitle: const Text(
                    'Bring a Vyapar backup (.vyb) across as a new business'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/vyapar-import'),
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.printer,
                  color: scheme.primary,
                ),
                title: const Text('Label printers'),
                subtitle: const Text(
                    'Set up a TSC or Zebra thermal printer for barcode labels'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/printers'),
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _exporting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : PhosphorIcon(
                        PhosphorIconsRegular.downloadSimple,
                        color: scheme.primary,
                      ),
                title: const Text('Export to CSV'),
                subtitle: Text(_exportResult ??
                    'Parties, items, sales, purchases and expenses as spreadsheets'),
                enabled: !_exporting,
                onTap: _exportCsv,
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.trash,
                  color: scheme.primary,
                ),
                title: const Text('Recycle Bin'),
                subtitle: const Text(
                    'Restore deleted documents, parties and items'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/recycle-bin'),
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _purging
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : PhosphorIcon(
                        PhosphorIconsRegular.trash,
                        color: scheme.error,
                      ),
                title: const Text('Empty recycle bin'),
                subtitle: const Text(
                    'Permanently delete everything in the bin — documents, '
                    'parties and items. Cannot be undone.'),
                enabled: !_purging,
                onTap: _confirmEmptyRecycleBin,
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.lockKey,
                  color: scheme.primary,
                ),
                title: const Text('Period lock'),
                subtitle: const Text(
                    'Freeze books up to a date — no edits to closed periods'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/period-lock'),
              ),
              Divider(color: scheme.outline, height: 1),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.listChecks,
                  color: scheme.primary,
                ),
                title: const Text('Audit log'),
                subtitle: const Text(
                    'Every create, edit, delete and restore — who and when'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => context.push('/settings/audit-log'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Account -----------------------------------------------------------

  /// Who this device is signed in as.
  ///
  /// Above the server section on purpose: the address is a working setting and
  /// the thing a support request needs quoted, whereas the sync worker below is
  /// the experimental part.
  Widget _accountSection() {
    final auth = ref.watch(authControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Atria account',
          subtitle: 'Optional. It is what lets Atria erase or sync your books '
              'on the server for you.',
        ),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: !auth.ready
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                )
              : Row(
                  children: [
                    PhosphorIcon(
                      auth.signedIn
                          ? PhosphorIconsRegular.userCircleCheck
                          : PhosphorIconsRegular.userCircle,
                      size: 22,
                      color: auth.signedIn
                          ? atriaColors(context).positive
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            auth.signedIn ? auth.email : 'Not signed in',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            auth.refreshing
                                ? 'Renewing this device\'s session…'
                                : auth.signedIn
                                    ? 'This device has a session for this '
                                        'account.'
                                    : 'Sign in to erase a business from the '
                                        'server, or to sync.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => context.push(SignInScreen.routePath),
                      child: Text(auth.signedIn ? 'Manage' : 'Sign in'),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  // ---- Sync --------------------------------------------------------------

  Widget _syncSection() {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Atria server',
          subtitle: 'Where this device signs in and syncs. Atria works fully '
              'offline either way.',
        ),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: _syncLoading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The address stays visible whatever the toggle says: it
                    // is a real, working setting, whereas only the sync worker
                    // itself is the experimental part.
                    _serverFields(),
                    const SizedBox(height: 14),
                    Divider(color: scheme.outline, height: 1),
                    const SizedBox(height: 10),
                    // Two-way since pull-sync landed. The badge is kept (now
                    // green) because "sync" deserves a visible contract: both
                    // directions, one merge rule, stated where the switch is.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colors.successSurface,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'TWO-WAY SYNC',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colors.success,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _syncEnabled,
                      onChanged: _toggleSync,
                      title: const Text('Sync my books to the server'),
                      subtitle: const Text(
                        'Changes are sent as you work and other devices\' '
                        'changes are received automatically, about every '
                        'minute while the app is open.',
                      ),
                    ),
                    _syncWorkerRow(),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PhosphorIcon(
                          PhosphorIconsRegular.shieldCheck,
                          size: 16,
                          color: colors.positive,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Cloud sync is optional. Your books are always '
                            'stored locally first, so they never depend on a '
                            'server.',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      height: 1.5,
                                    ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// The outbox: how much is waiting, when it last drained, and a way to make
  /// it happen now.
  ///
  /// The outbox is written on every save whether or not sync is on, so the
  /// pending count is real even with the toggle off — which is exactly why it
  /// is worth showing.
  Widget _syncWorkerRow() {
    final scheme = Theme.of(context).colorScheme;
    final status = ref.watch(syncStatusProvider);
    final account = ref.watch(authControllerProvider);

    final Widget body;
    if (status.isLoading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    } else if (status.hasError) {
      body = Text(
        'Could not read the outbox: ${status.error}',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.error),
      );
    } else {
      final value = status.valueOrNull;
      final pending = value?.pending ?? 0;
      final lastSynced = value?.lastSyncedAt;
      final lastPushed = value?.lastPushedAt;
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pending == 0
                      ? 'Nothing is waiting to be sent.'
                      : '$pending change(s) waiting to be sent.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                Text(
                  lastSynced != null
                      ? 'Last synced ${Formatters.dateTime(lastSynced)}.'
                      : lastPushed != null
                          ? 'Last sent ${Formatters.dateTime(lastPushed)}; '
                              'nothing received yet.'
                          : 'This device has never completed a sync.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _syncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : TextButton(
                  // Only offered where it can work: with sync off, this button
                  // would be a way to send the books out anyway, which is not
                  // what the toggle promises.
                  onPressed: _syncEnabled && account.signedIn ? _syncNow : null,
                  child: const Text('Sync now'),
                ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: body,
    );
  }

  /// Runs a full sync by hand: push the outbox, then pull the journal.
  ///
  /// The same call the automatic timer makes, with the same rules: nothing here
  /// bypasses the toggle. Its value is that the operator gets an answer now
  /// rather than at some indeterminate later moment.
  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final report = await ref.read(syncEngineProvider).sync();
      if (!mounted) return;
      ref.invalidate(syncStatusProvider);
      messenger?.showSnackBar(SnackBar(content: Text(report.describe)));
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not sync: $error')),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// The server address, plus a way to prove it works.
  ///
  /// Deliberately visible whether or not the sync toggle is on: telling the app
  /// which server it belongs to is a real, working setting, and counting the
  /// outbox is useful even while it is not being drained.
  Widget _serverFields() {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        TextFormField(
          controller: _apiUrlController,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Server address',
            hintText: ApiConfig.productionBaseUrl,
            prefixIcon: const AtriaFieldIcon(Icons.link_rounded),
            errorText: _apiUrlError,
            helperText: _apiUrlIsCustom
                ? 'Saved on this device'
                : 'Built-in address — type your own to change it',
          ),
          // Saved on every change AND on done — saving only on
          // onEditingComplete meant tapping away (or switching apps) silently
          // discarded what was typed.
          onChanged: (value) => _saveApiUrl(value, quiet: true),
          onEditingComplete: () => _saveApiUrl(_apiUrlController.text),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _probing ? null : _testServer,
          icon: _probing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.wifi_tethering_rounded,
                  size: AppIconSize.md),
          label: Text(_probing ? 'Testing…' : 'Test connection'),
        ),
        if (_probeMessage != null) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _probeOk == true
                    ? Icons.check_circle_rounded
                    : Icons.error_outline_rounded,
                size: AppIconSize.md,
                color: _probeOk == true ? colors.positive : colors.danger,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_probeMessage!, style: text.bodySmall)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Text(
          _deviceLabel,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// Validates and stores the server address.
  ///
  /// An empty field clears the override, which is why it removes the setting
  /// rather than storing "" — the built-in address takes over again.
  Future<void> _saveApiUrl(String raw, {bool quiet = false}) async {
    final trimmed = raw.trim();

    if (trimmed.isEmpty) {
      setState(() {
        _apiUrlError = null;
        _apiUrlIsCustom = false;
        _probeMessage = null;
        _probeOk = null;
      });
      await _saveSetting(SettingsRepository.kApiBaseUrl, '', quiet: true);
      if (!quiet && mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
              content: Text('Using ${ApiConfig.productionBaseUrl}')),
        );
      }
      return;
    }

    // Refuse to store an address the client cannot use: every request would
    // throw later, far from the screen that caused it.
    final error = ApiConfig.validateBaseUrl(trimmed);
    if (error != null) {
      setState(() => _apiUrlError = error);
      return;
    }

    final normalised = ApiConfig.normaliseBaseUrl(trimmed);
    setState(() {
      _apiUrlError = null;
      _apiUrlIsCustom = true;
      // A previous test result describes a different address now.
      _probeMessage = null;
      _probeOk = null;
    });
    await _saveSetting(SettingsRepository.kApiBaseUrl, normalised,
        quiet: true);
    if (!quiet && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Saving to $normalised')),
      );
    }
  }

  Future<void> _testServer() async {
    final typed = _apiUrlController.text.trim();
    final error = ApiConfig.validateBaseUrl(typed);
    if (error != null) {
      setState(() {
        _apiUrlError = error;
        _probeMessage = null;
        _probeOk = null;
      });
      return;
    }

    setState(() {
      _probing = true;
      _probeMessage = null;
      _probeOk = null;
    });

    final result = await ServerProbe.check(ApiConfig.normaliseBaseUrl(typed));
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeOk = result.ok;
      _probeMessage = result.message;
    });
  }

  Future<void> _saveSetting(String key, String value,
      {bool quiet = false}) async {
    final repository = ref.read(appDatabaseProvider).settingsRepository;
    try {
      if (value.isEmpty) {
        await repository.remove(key);
      } else {
        await repository.set(key, value);
      }
    } catch (e) {
      // Always reported "Sync setting saved", even when the write failed.
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not save sync setting: $e')),
      );
      return;
    }
    if (quiet || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Sync setting saved')),
    );
  }

  // ---- About -------------------------------------------------------------

  Widget _aboutSection() {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    final version = _packageInfo?.version ?? '1.0.0';
    final build = _packageInfo?.buildNumber;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'About'),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const AtriaWordmark(logoSize: 40, fontSize: 19),
                  const Spacer(),
                  Text(
                    build == null
                        ? 'Version $version'
                        : 'Version $version ($build)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(color: scheme.outline, height: 1),
              const SizedBox(height: 12),
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIconsRegular.heart,
                    size: 16,
                    color: colors.saffronGradientStart,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Made in India for Indian businesses. Your data stays '
                      'private and on your device.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
