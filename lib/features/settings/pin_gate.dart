import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/app_database.dart';
import '../../core/domain/member_role.dart';
import '../../core/state/member_session_controller.dart';
import '../../core/state/providers.dart';
import '../../shared/widgets/common_widgets.dart';

/// The counter gate: pick who you are, then prove it with a PIN.
///
/// Mounted as an **overlay over the whole app**, not as a route. That is the
/// whole design and it is load-bearing: the app's boot flow is a router
/// redirect whose `refreshListenable` only pulses on initialisation, so a
/// mutable "signed in" flag behind a route would either need a second
/// notifier threaded through the router or would strand the person on a splash
/// they cannot get past. An overlay sidesteps the router entirely, which is
/// what lets "the feature is off" be genuinely identical to not having written
/// this file.
///
/// It also cannot be dismissed by navigation: `PopScope` refuses a back
/// gesture, and there is no dismiss control, because a gate you can swipe away
/// is not a gate.
class PinGate extends ConsumerStatefulWidget {
  const PinGate({super.key});

  @override
  ConsumerState<PinGate> createState() => _PinGateState();
}

class _PinGateState extends ConsumerState<PinGate> {
  FirmMemberEntity? _picked;
  String _pin = '';
  String? _error;
  bool _busy = false;

  /// Wrong attempts before the picker is offered again.
  ///
  /// Deliberately small and deliberately local: this is a shop counter, and a
  /// lockout that persists would mean a locked-out shop. It exists to stop a
  /// sibling trying every PIN, not to defend against a determined attacker —
  /// a determined attacker has the database, which is why the hash is salted
  /// and iterated but the threat model is stated plainly in `PinHasher`.
  static const int _maxAttempts = 5;

  int _attempts = 0;

  void _pick(FirmMemberEntity member) {
    setState(() {
      _picked = member;
      _pin = '';
      _error = null;
      _attempts = 0;
    });
  }

  Future<void> _submit() async {
    final repo = ref.read(membersRepositoryProvider);
    final picked = _picked;
    if (repo == null || picked == null || _busy) return;
    if (_pin.length < 4) {
      setState(() => _error = 'Enter at least 4 digits.');
      return;
    }
    setState(() => _busy = true);
    final session = await repo.signIn(memberId: picked.id, pin: _pin);
    if (!mounted) return;
    if (session == null) {
      setState(() {
        _busy = false;
        _attempts++;
        _pin = '';
        _error = _attempts >= _maxAttempts
            ? 'Too many wrong PINs. Pick your name again.'
            : 'That PIN is not right.';
      });
      if (_attempts >= _maxAttempts) _picked = null;
      return;
    }
    ref.read(memberSessionProvider.notifier).signIn(session);
  }

  void _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      if (_pin.isNotEmpty) {
        setState(() {
          _pin = _pin.substring(0, _pin.length - 1);
          _error = null;
        });
      }
      return;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return;
    }
    final ch = event.character;
    if (ch != null && RegExp(r'^\d$').hasMatch(ch) && _pin.length < 12) {
      setState(() {
        _pin += ch;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final members = ref.watch(membersProvider).valueOrNull ?? const [];
    final selectable = members.where((m) => m.isActive).toList();

    return PopScope(
      canPop: false,
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          _onKey(event);
          return KeyEventResult.handled;
        },
        child: Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: PhosphorIcon(
                          _picked == null
                              ? PhosphorIconsRegular.userCircle
                              : PhosphorIconsRegular.lockKey,
                          size: 44,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _picked == null
                            ? 'Who is at the counter?'
                            : 'Enter your PIN',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _picked == null
                            ? 'Pick your name to sign in to ${_firmName(ref)}.'
                            : '${_picked!.name} — ${MemberRole.of(_picked!.role).label}',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 24),
                      if (_picked == null)
                        ..._picker(context, selectable)
                      else
                        _keypad(context),
                      if (_error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _firmName(WidgetRef ref) {
    final firm = ref.watch(activeFirmProvider).valueOrNull;
    return firm == null || firm.name.isEmpty ? 'these books' : firm.name;
  }

  /// The name list. A keypad is the wrong control for choosing a person — this
  /// is a tap, and it is one fewer thing to get wrong at a busy counter.
  List<Widget> _picker(
    BuildContext context,
    List<FirmMemberEntity> selectable,
  ) {
    if (selectable.isEmpty) {
      return [
        Text(
          'No active members yet. Add one in Settings ▸ Members.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ];
    }
    return [
      for (final member in selectable)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AtriaCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            onTap: () => _pick(member),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        member.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        MemberRole.of(member.role).label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const PhosphorIcon(PhosphorIconsRegular.caretRight, size: 16),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _keypad(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        // The dots are the only place the typed PIN is ever shown, and they
        // show its length and nothing else.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < _pin.length; i++)
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.7,
          children: [
            for (final digit in const [
              '1',
              '2',
              '3',
              '4',
              '5',
              '6',
              '7',
              '8',
              '9',
            ])
              _key(context, digit, () => _push(digit)),
            _key(context, '', null),
            _key(context, '0', () => _push('0')),
            _key(
              context,
              '⌫',
              () => setState(() {
                if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
              }),
            ),
          ],
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy || _pin.length < 4 ? null : _submit,
          child: Text(_busy ? 'Checking…' : 'Sign in'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _picked = null),
          child: const Text('Not you? Pick another name'),
        ),
      ],
    );
  }

  void _push(String digit) {
    if (_pin.length >= 12) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  Widget _key(BuildContext context, String label, VoidCallback? onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge
            ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

/// The whole app, with the gate on top of it when the firm has turned local
/// users on and nobody is signed in.
///
/// Returns the child untouched when the gate is not showing — which is the
/// common case and the one that has to be free: with the feature off this is
/// one provider read and the same widget tree the app had before.
class MemberGateOverlay extends ConsumerWidget {
  const MemberGateOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(pinGateVisibleProvider);
    if (!visible) return child;
    // `Stack` with the child beneath rather than `child:` on the Scaffold: the
    // gate must cover a Navigator that already exists, and `Positioned.fill`
    // over the app keeps whatever was on screen behind it rather than
    // destroying it (a gate that resets the nav stack every time it appears
    // would drop the person back at the dashboard after every sign-in).
    return Stack(
      children: [
        child,
        const Positioned.fill(child: PinGate()),
      ],
    );
  }
}
