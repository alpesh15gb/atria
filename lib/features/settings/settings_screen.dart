import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/database/repositories/settings_repository.dart';
import '../../core/services/csv_export.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_logo.dart';
import '../../shared/widgets/common_widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _switchExpanded = false;
  bool _syncEnabled = false;
  bool _obscureSupabaseKey = true;
  bool _syncLoading = true;
  bool _backingUp = false;
  bool _exporting = false;
  String? _exportResult;
  DateTime? _lastBackup;
  PackageInfo? _packageInfo;

  late final TextEditingController _supabaseUrlController;
  late final TextEditingController _supabaseKeyController;

  @override
  void initState() {
    super.initState();
    _supabaseUrlController = TextEditingController();
    _supabaseKeyController = TextEditingController();
    _loadSettings();
  }

  @override
  void dispose() {
    _supabaseUrlController.dispose();
    _supabaseKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final db = ref.read(appDatabaseProvider);
    final syncEnabled =
        await db.settingsRepository.getBool(SettingsRepository.kSyncEnabled);
    final url = await db.settingsRepository.get(SettingsRepository.kSupabaseUrl);
    final key =
        await db.settingsRepository.get(SettingsRepository.kSupabaseAnonKey);
    final stamp =
        await db.settingsRepository.get(SettingsRepository.kLastBackupAt);
    final info = await PackageInfo.fromPlatform();

    if (!mounted) return;
    setState(() {
      _syncEnabled = syncEnabled;
      _supabaseUrlController.text = url ?? '';
      _supabaseKeyController.text = key ?? '';
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
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        border: Border.all(color: scheme.outline, width: 0.9),
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
              size: 19,
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
                        fontWeight: FontWeight.w800,
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

  // ---- Sync --------------------------------------------------------------

  Widget _syncSection() {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Cloud sync',
          subtitle: 'Experimental — not active yet. Atria works fully offline.',
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
                    // The outbox that would feed this is already written to on
                    // every save; only the worker that drains it is missing.
                    // Say so plainly rather than letting the toggle imply live
                    // syncing.
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colors.warningSurface,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'EXPERIMENTAL',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colors.warning,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _syncEnabled,
                      onChanged: _toggleSync,
                      title: const Text('Enable cloud sync'),
                      subtitle: const Text(
                        'Coming soon — nothing leaves this device yet',
                      ),
                    ),
                    AnimatedCrossFade(
                      duration: const Duration(milliseconds: 220),
                      crossFadeState: _syncEnabled
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                      firstChild: const SizedBox(width: double.infinity),
                      secondChild: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _supabaseUrlController,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            // Saved on every change AND on done — saving only
                            // on onEditingComplete meant tapping away (or
                            // switching apps) silently discarded the URL.
                            onChanged: (_) => _saveSetting(
                              SettingsRepository.kSupabaseUrl,
                              _supabaseUrlController.text.trim(),
                              quiet: true,
                            ),
                            onEditingComplete: () => _saveSetting(
                              SettingsRepository.kSupabaseUrl,
                              _supabaseUrlController.text.trim(),
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Supabase project URL',
                              hintText: 'https://xxxx.supabase.co',
                              prefixIcon: Icon(Icons.link_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _supabaseKeyController,
                            keyboardType: TextInputType.visiblePassword,
                            // Credentials are secrets — the field rendered
                            // them in clear text.
                            obscureText: _obscureSupabaseKey,
                            textInputAction: TextInputAction.done,
                            onChanged: (_) => _saveSetting(
                              SettingsRepository.kSupabaseAnonKey,
                              _supabaseKeyController.text.trim(),
                              quiet: true,
                            ),
                            onEditingComplete: () => _saveSetting(
                              SettingsRepository.kSupabaseAnonKey,
                              _supabaseKeyController.text.trim(),
                            ),
                            decoration: InputDecoration(
                              labelText: 'Supabase anon key',
                              hintText: 'ey…',
                              prefixIcon: const Icon(Icons.key_rounded),
                              suffixIcon: IconButton(
                                tooltip: _obscureSupabaseKey
                                    ? 'Show key'
                                    : 'Hide key',
                                icon: Icon(_obscureSupabaseKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined),
                                onPressed: () => setState(
                                    () => _obscureSupabaseKey =
                                        !_obscureSupabaseKey),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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
