import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/database/repositories/repository_extensions.dart';
import '../../core/database/repositories/settings_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/common_widgets.dart';

/// Local JSON backup export and restore. Backups live on the device itself,
/// so the app keeps working fully offline.
class BackupRestoreScreen extends ConsumerStatefulWidget {
  const BackupRestoreScreen({super.key});

  @override
  ConsumerState<BackupRestoreScreen> createState() =>
      _BackupRestoreScreenState();
}

enum _State { idle, exporting, importing }

class _BackupRestoreScreenState extends ConsumerState<BackupRestoreScreen> {
  _State _state = _State.idle;
  String? _exportPath;
  DateTime? _lastBackup;

  @override
  void initState() {
    super.initState();
    _loadLastBackup();
  }

  Future<void> _loadLastBackup() async {
    final stamp = await ref
        .read(appDatabaseProvider)
        .settingsRepository
        .get(SettingsRepository.kLastBackupAt);
    if (!mounted) return;
    setState(() {
      _lastBackup =
          stamp == null ? null : DateTime.tryParse(stamp)?.toLocal();
    });
  }

  // ---- Export ------------------------------------------------------------

  Future<void> _export() async {
    setState(() {
      _state = _State.exporting;
      _exportPath = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      final path = await db.backupRepository.exportToFile();
      // A backup that cannot be read back is not a backup. Offer Share and Open
      // only once the file is really there and non-empty — sharing a missing
      // path hands the user a broken file with a cheerful label.
      final file = File(path);
      final written = await file.exists() && await file.length() > 0;
      final stamp = DateTime.now();
      // Only stamp the backup as taken when the file is really there: otherwise
      // the "last backup" line would promise a file that cannot be restored.
      if (written) {
        await db.settingsRepository.set(
          SettingsRepository.kLastBackupAt,
          stamp.toUtc().toIso8601String(),
        );
      }
      if (!mounted) return;
      setState(() {
        _state = _State.idle;
        _exportPath = written ? path : null;
        if (written) _lastBackup = stamp;
      });
      if (!written) {
        messenger?.showSnackBar(SnackBar(
          content: Text('The backup file could not be read back from '
              '${Formatters.ellipsis(path, 40)} — try exporting again.'),
        ));
        return;
      }
      messenger?.showSnackBar(
        const SnackBar(content: Text('Backup created')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _state = _State.idle);
      messenger?.showSnackBar(SnackBar(content: Text('Backup failed: $error')));
    }
  }

  // ---- Restore -----------------------------------------------------------

  Future<void> _pickAndRestore() async {
    // withData: false, deliberately. A backup is every firm, party, item and
    // document on the device as JSON — pulling it through the platform channel
    // put the whole thing in RAM twice (once as bytes, once as the decoded
    // payload) and made the file.path fallback below unreachable. Reading the
    // path lets the OS stream it instead.
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    Map<String, dynamic>? payload;
    try {
      final path = file.path;
      final json = path != null
          ? await _readFile(path)
          : // No path (an unusual provider, or a cloud-backed pick): the bytes
            // the plugin did give us are the only way in.
            utf8.decode(file.bytes ?? const <int>[]);
      payload = jsonDecode(json) as Map<String, dynamic>;
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not read that file: $error')),
      );
      return;
    }
    if (!mounted) return;

    // Reject a wrong file BEFORE the destructive confirmation — the restore
    // itself also validates, but by then the user has already been asked to
    // wipe their books.
    try {
      BackupRepository.validateBackupJson(payload);
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return;
    }

    final confirmed = await _confirmRestore(context);
    if (!confirmed || !mounted) return;

    setState(() => _state = _State.importing);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final rows = await ref
          .read(appDatabaseProvider)
          .backupRepository
          .importFromJson(payload);
      if (!mounted) return;
      setState(() => _state = _State.idle);
      messenger?.showSnackBar(
        SnackBar(content: Text('Restored $rows records')),
      );
      context.pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _state = _State.idle);
      messenger?.showSnackBar(
        SnackBar(content: Text('Restore failed: $error')),
      );
    }
  }

  Future<bool> _confirmRestore(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: atriaColors(dialogContext).warning,
          size: 32,
        ),
        title: const Text('Replace all data?'),
        content: const Text(
          'Restoring replaces every firm, party, invoice and transaction '
          'currently on this device with the contents of the backup file. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<String> _readFile(String path) {
    return File(path).readAsString();
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
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
                    _exportCard(),
                    const SizedBox(height: 16),
                    _restoreCard(),
                    const SizedBox(height: 16),
                    if (_lastBackup != null) _lastBackupTile(),
                  ],
                ),
              ),
            );
          },
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
            PhosphorIconsRegular.deviceMobile,
            size: 20,
            color: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Backups are stored locally on this device or computer — nothing '
              'leaves it. Export regularly and keep a copy somewhere safe.',
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

  Widget _exportCard() {
    final colors = atriaColors(context);
    final exporting = _state == _State.exporting;
    return _BigCard(
      icon: PhosphorIconsRegular.uploadSimple,
      iconBackground: colors.brandGradientStart,
      title: 'Export backup',
      subtitle: 'Save every firm, party, item, invoice and payment into a '
          'single JSON file you can share or keep.',
      action: exporting
          ? const _ProgressButton(label: 'Exporting…')
          : FilledButton.icon(
              onPressed: _state == _State.importing ? null : _export,
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('Export backup'),
            ),
      trailing: _exportPath == null
          ? null
          : _ExportResult(
              path: _exportPath!,
              busy: _state != _State.idle,
            ),
    );
  }

  Widget _restoreCard() {
    final colors = atriaColors(context);
    final importing = _state == _State.importing;
    return _BigCard(
      icon: PhosphorIconsRegular.downloadSimple,
      iconBackground: colors.saffronGradientStart,
      title: 'Restore backup',
      subtitle: 'Replace the books on this device with the contents of a '
          'previously exported Apex Books JSON file.',
      action: importing
          ? const _ProgressButton(label: 'Restoring…')
          : OutlinedButton.icon(
              onPressed: _state == _State.exporting ? null : _pickAndRestore,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Choose a file'),
            ),
    );
  }

  Widget _lastBackupTile() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.clock,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            'Last backup ${Formatters.dateTime(_lastBackup)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ],
      ),
    );
  }
}

class _BigCard extends StatelessWidget {
  const _BigCard({
    required this.icon,
    required this.iconBackground,
    required this.title,
    required this.subtitle,
    required this.action,
    this.trailing,
  });

  final IconData icon;
  final Color iconBackground;
  final String title;
  final String subtitle;
  final Widget action;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AtriaCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      iconBackground,
                      iconBackground.withValues(alpha: 0.72),
                    ],
                  ),
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.md)),
                  boxShadow: [
                    BoxShadow(
                      color: iconBackground
                          .withValues(alpha: isDark ? 0.36 : 0.24),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: PhosphorIcon(icon, size: 22, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                            height: 1.5,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: action),
          if (trailing != null) ...[
            const SizedBox(height: 16),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _ExportResult extends StatelessWidget {
  const _ExportResult({required this.path, required this.busy});

  final String path;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = atriaColors(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIconsRegular.checkCircle,
                size: 16,
                color: colors.positive,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Backup saved',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.positive,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            Formatters.ellipsis(path, 64),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () => Share.shareXFiles([XFile(path)]),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: const Text('Share'),
              ),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        final result = await OpenFilex.open(path);
                        if (result.type != ResultType.done &&
                            context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                result.message.isEmpty
                                    ? 'Could not open the file'
                                    : result.message,
                              ),
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open'),
              ),
            ],
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
