import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/database/repositories/members_repository.dart';
import '../../core/domain/member_role.dart';
import '../../core/state/member_session_controller.dart';
import '../../core/state/providers.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/confirm_destructive.dart';

/// Add, remove and set the role of everyone who works at the counter.
///
/// Reached from Settings only when the firm has turned local users on. Every
/// write here is a `manageMasters` action, so an accountant who somehow reaches
/// this screen sees the list and gets a refusal from the repository rather than
/// a form that quietly does nothing.
class MembersScreen extends ConsumerWidget {
  const MembersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final firmId = ref.watch(activeFirmIdProvider);
    final enabled = ref.watch(localUsersEnabledProvider).valueOrNull == true;
    final members = ref.watch(membersProvider);

    if (firmId == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Members')),
        body: const Center(child: Text('Open a business first.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Members'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: enabled
                  ? () => _editMember(context, ref, firmId, null)
                  : null,
              icon: const PhosphorIcon(PhosphorIconsRegular.plus, size: 16),
              label: const Text('Add'),
            ),
          ),
        ],
      ),
      body: members.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load members: $e')),
        data: (rows) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _featureToggle(context, ref, firmId, enabled),
            const SizedBox(height: 24),
            if (!enabled)
              _offNotice(context)
            else if (rows.isEmpty)
              _empty(context, ref, firmId)
            else
              for (final member in rows) ...[
                _MemberTile(
                  member: member,
                  onEdit: () => _editMember(context, ref, firmId, member),
                  onDelete: () => _deleteMember(context, ref, firmId, member),
                ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  /// The switch that makes the feature real.
  ///
  /// Turning it **on** with nobody on the roster is allowed and does not lock
  /// anyone out: [pinGateVisibleProvider] requires at least one active member
  /// before the gate appears, so an operator can enable it, then add people.
  /// Turning it **off** clears the session as well as the flag — see
  /// [MemberSessionController.disable] for why leaving the old role in place
  /// would keep filtering writes after the firm said "no PINs".
  Widget _featureToggle(
    BuildContext context,
    WidgetRef ref,
    String firmId,
    bool enabled,
  ) {
    final db = ref.read(appDatabaseProvider);
    return AtriaCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: enabled,
        title: const Text('Require a PIN at the counter'),
        subtitle: Text(
          enabled
              ? 'Each person picks their name and enters a PIN before they can '
                    'use the app.'
              : 'Off. Nobody signs in, and every action is allowed — exactly '
                    'as before this feature existed.',
        ),
        onChanged: (value) async {
          await db.setLocalUsersEnabled(firmId, value);
          if (!value) {
            ref.read(memberSessionProvider.notifier).disable();
          }
          ref.invalidate(localUsersEnabledProvider);
        },
      ),
    );
  }

  Widget _offNotice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.info,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Turn this on to give each person their own PIN and role. '
              'While it is off, the app behaves exactly as it always has — '
              'no sign-in, and nothing restricted.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref, String firmId) {
    return Column(
      children: [
        AtriaCard(
          child: Text(
            'No members yet. Add yourself first — with the switch on and '
            'nobody on the roster, the app deliberately stays open.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => _editMember(context, ref, firmId, null),
          icon: const PhosphorIcon(PhosphorIconsRegular.userPlus, size: 16),
          label: const Text('Add the first member'),
        ),
      ],
    );
  }
}

class _MemberTile extends ConsumerWidget {
  const _MemberTile({
    required this.member,
    required this.onEdit,
    required this.onDelete,
  });

  final FirmMemberEntity member;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final role = MemberRole.of(member.role);
    final hasPin = member.pinHash != null;
    return AtriaCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: onEdit,
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: member.isActive
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            child: Text(
              member.name.isEmpty ? '?' : member.name.characters.first,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        member.name,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!member.isActive) ...[
                      const SizedBox(width: 8),
                      const Chip(
                        label: Text('Inactive'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    role.label,
                    // A member with no PIN can be listed here but cannot sign
                    // in, which is a state worth stating rather than leaving
                    // the operator to infer from a missing keypad.
                    hasPin ? 'PIN set' : 'No PIN yet',
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            icon: const PhosphorIcon(PhosphorIconsRegular.trash, size: 18),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// Add a member, or edit one — including their role and PIN.
///
/// Role changes and PIN changes are separate controls on purpose: setting a
/// PIN on a *different* member to the one being edited would be the kind of
/// thing that silently re-points a permission, so the sheet edits one person.
Future<void> _editMember(
  BuildContext context,
  WidgetRef ref,
  String firmId,
  FirmMemberEntity? existing,
) async {
  final repo = ref.read(membersRepositoryProvider);
  final db = ref.read(appDatabaseProvider);
  if (repo == null) return;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) =>
        _MemberEditorDialog(repo: repo, db: db, existing: existing),
  );
  // The members stream re-emits on the write, so invalidating is only needed
  // for the *toggle*, which lives in a different screen.
  ref.invalidate(membersProvider);
}

class _MemberEditorDialog extends StatefulWidget {
  const _MemberEditorDialog({
    required this.repo,
    required this.db,
    required this.existing,
  });

  final MembersRepository repo;
  final AppDatabase db;
  final FirmMemberEntity? existing;

  @override
  State<_MemberEditorDialog> createState() => _MemberEditorDialogState();
}

class _MemberEditorDialogState extends State<_MemberEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late MemberRole _role = MemberRole.of(
    widget.existing?.role ?? MemberRole.staff.name,
  );
  late bool _active = widget.existing?.isActive ?? true;
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirmPin = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  /// A PIN is optional on create and every PIN change is checked twice.
  ///
  /// The second box is not ceremony for its own sake — a four-digit entry on a
  /// counter keypad with sticky fingers is exactly how a member ends up
  /// locked out of their own account on their first shift.
  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name is required.');
      return;
    }
    final pin = _pin.text;
    if (pin.isNotEmpty) {
      if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) {
        setState(() => _error = 'The PIN must be 4 to 12 digits.');
        return;
      }
      if (pin != _confirmPin.text) {
        setState(() => _error = 'The two PINs do not match.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final existing = widget.existing;
      if (existing == null) {
        final created = await widget.repo.create(
          name: name,
          role: _role,
          pin: pin.isEmpty ? null : pin,
        );
        if (pin.isEmpty) {
          if (mounted) {
            setState(
              () => _error =
                  'Created ${created.name}. They can be listed at the counter '
                  'but cannot sign in until they are given a PIN.',
            );
          }
          setState(() => _busy = false);
          return;
        }
      } else {
        await widget.repo.update(
          existing.id,
          name: name,
          role: _role,
          isActive: _active,
        );
        if (pin.isNotEmpty) await widget.repo.setPin(existing.id, pin);
      }
      if (mounted) Navigator.of(context).pop();
    } on PermissionDeniedException catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = 'Could not save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final creating = widget.existing == null;
    return AlertDialog(
      title: Text(creating ? 'Add member' : 'Edit member'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<MemberRole>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final role in MemberRole.values)
                    DropdownMenuItem(value: role, child: Text(role.label)),
                ],
                onChanged: (role) => setState(() => _role = role ?? _role),
              ),
              const SizedBox(height: 8),
              Text(switch (_role) {
                MemberRole.admin =>
                  'Can do everything, including deleting and removing the '
                      'business.',
                MemberRole.staff =>
                  'Can create invoices, bills and payments. Cannot delete, '
                      'cancel, or re-open a locked period.',
                MemberRole.accountant =>
                  'Read-only, plus reports and exports. Cannot change '
                      'anything.',
              }, style: Theme.of(context).textTheme.bodySmall),
              if (!creating) ...[
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _active,
                  title: const Text('Active'),
                  subtitle: Text(
                    _active
                        ? 'Can sign in at the counter.'
                        : 'Kept for the audit trail, but cannot sign in.',
                  ),
                  onChanged: (v) => setState(() => _active = v),
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _pin,
                keyboardType: TextInputType.number,
                obscureText: true,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: creating
                      ? 'PIN (optional — leave blank to set it later)'
                      : 'New PIN (blank to keep the current one)',
                ),
              ),
              const SizedBox(height: 12),
              if (_pin.text.isNotEmpty)
                TextField(
                  controller: _confirmPin,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Repeat PIN'),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}

Future<void> _deleteMember(
  BuildContext context,
  WidgetRef ref,
  String firmId,
  FirmMemberEntity member,
) async {
  final repo = ref.read(membersRepositoryProvider);
  if (repo == null) return;
  final confirmed = await confirmDestructive(
    context,
    title: 'Remove ${member.name}?',
    message: member.isActive
        ? 'They will no longer be able to sign in. Documents they created '
              'keep their history, which records their name.'
        : 'This member is already inactive and cannot sign in. Removing them '
              'deletes the record.',
    confirmLabel: 'Remove',
  );
  if (!confirmed) return;
  try {
    await repo.delete(member.id);
    ref.invalidate(membersProvider);
  } on PermissionDeniedException catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
