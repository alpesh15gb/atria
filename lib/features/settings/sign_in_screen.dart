import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/api_config.dart';
import '../../core/api/server_client.dart' show ServerRequestException;
import '../../core/database/repositories/settings_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/auth_controller.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/common_widgets.dart';

/// The Apex Books account this device signs in to.
///
/// Signing in is what makes the account-scoped half of the app possible at all:
/// erasing a business from the server, and (with the sync engine) pushing local
/// books to it. The screen is deliberately a plain email/password form and not
/// an "account dashboard" — the account has no settings here, only a session.
///
/// The form itself is [SignInForm], extracted from this screen so first-run
/// firm setup can embed it; this screen is the standalone Settings entry
/// point.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({
    super.key,
    this.onAuthenticated,
    this.showServerField = false,
  });

  static const String routePath = '/settings/sign-in';

  /// Called with the signed-in address after a successful sign-in or
  /// sign-up, and awaited before the form reports completion, so a host that
  /// persists something (first-run's onboarding flag) finishes before the
  /// busy state clears. [FirmSetupScreen] embeds the form and continues
  /// onboarding from the callback; the standalone Settings screen leaves it
  /// null and lets the auth state swap the form for the session card.
  final Future<void> Function(String email)? onAuthenticated;

  /// Whether the form offers the server address for editing. Settings keeps
  /// its own dedicated server card with a connection test, so the standalone
  /// screen does not duplicate it — but on first run there is no way to reach
  /// that card at all, and a firm on its own server would be stuck signing
  /// into the built-in address with nowhere to say otherwise.
  final bool showServerField;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final note = await ref.read(authControllerProvider.notifier).signOut();
    if (!mounted) return;
    setState(() => _busy = false);
    messenger?.showSnackBar(
      SnackBar(content: Text(note ?? 'Signed out on this device.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Apex Books account')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.isCompact ? double.infinity : 560,
              ),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (!auth.ready)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (auth.signedIn)
                    _sessionCard(auth)
                  else
                    SignInForm(
                      onAuthenticated: widget.onAuthenticated,
                      showServerField: widget.showServerField,
                    ),
                  const SizedBox(height: 20),
                  _whyCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- Signed in ---------------------------------------------------------

  Widget _sessionCard(AuthState auth) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Signed in'),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIconsRegular.userCircleCheck,
                    size: 22,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      auth.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                auth.expiresAt == null
                    ? 'This device holds a session for this account.'
                    : 'Session valid until '
                        '${Formatters.dateTime(auth.expiresAt!.toLocal())}. '
                        'It renews by itself while Apex Books is reachable.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _signOut,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout_rounded, size: AppIconSize.md),
                  label: const Text('Sign out on this device'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---- Signed out --------------------------------------------------------

  Widget _whyCard() {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.shieldCheck,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Signing in never moves your books by itself. Apex Books only sends '
              'data when you ask it to — erasing a business from the server, '
              'or turning on sync in Settings.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.55,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The email/password half of [SignInScreen], extractable so first-run firm
/// setup can offer "Sign in with email" without routing the user into
/// Settings mid-onboarding.
///
/// Two rules the form follows, both learned from what the server does:
///
/// * the password rule is enforced at sign-up only. Re-checking it at sign-in
///   would lock out anyone whose password predates a rule change, and the
///   server deliberately does not re-validate it either;
/// * the error shown is the server's own message, because "Email or password
///   is incorrect" is a decision the server makes (it refuses to say which),
///   and rewriting it here would either leak that distinction or contradict
///   it.
///
/// When [onAuthenticated] is set the form is embedded: a successful call does
/// not celebrate with a SnackBar, because the host reacts instead — a
/// standalone screen confirms and lets the signed-in card take over.
class SignInForm extends ConsumerStatefulWidget {
  const SignInForm({super.key, this.onAuthenticated, this.showServerField = false});

  /// See [SignInScreen.onAuthenticated]. Null means standalone: the form
  /// confirms with a SnackBar after signing in.
  final Future<void> Function(String email)? onAuthenticated;

  /// Shows an editable server-address field above the credentials. See
  /// [SignInScreen.showServerField].
  final bool showServerField;

  @override
  ConsumerState<SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends ConsumerState<SignInForm> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _serverController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  /// Sign in is the default; creating an account is one tap away.
  bool _createAccount = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.showServerField) {
      // Prefill with the address requests would use right now — the saved
      // override, a build-time one, or the built-in default, in that order.
      // An install that has never touched Settings therefore shows the
      // production address rather than an empty box.
      () async {
        try {
          final base = await ref.read(apiConfigProvider).baseUrl();
          if (mounted) _serverController.text = base;
        } on Object {
          // A stored address this app cannot parse stays an empty field: the
          // user is about to retype one anyway, and an error here would fire
          // before they have touched anything.
        }
      }();
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    final auth = ref.read(authControllerProvider.notifier);
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (widget.showServerField) {
        // Persist the address BEFORE the credentials travel: a sign-in that
        // succeeds against a server the next request will not use is the
        // half-configured state this field exists to prevent. The form
        // validator has already accepted empty (meaning "use what is
        // configured") and rejected anything unnormalisable.
        final typed = _serverController.text.trim();
        if (typed.isNotEmpty) {
          await ref
              .read(settingsRepositoryProvider)
              .set(SettingsRepository.kApiBaseUrl, ApiConfig.normaliseBaseUrl(typed));
        }
      }
      if (_createAccount) {
        await auth.signUp(email: email, password: password);
      } else {
        await auth.signIn(email: email, password: password);
      }
      // The password never lingers in the field after a successful sign-in.
      if (mounted) _passwordController.clear();

      final callback = widget.onAuthenticated;
      if (callback != null) {
        // Deliberately NOT gated on this State's `mounted`: the moment the
        // auth state flips, the host's AnimatedSwitcher retires this form and
        // unmounts it mid-await — that is the embedded flow working, not
        // failing. The callback belongs to the host, which outlives the form,
        // and skipping it here is what would strand a first-run user back on
        // the welcome pages with their first-run flag never written.
        await callback(email);
      } else {
        if (!mounted) return;
        messenger?.showSnackBar(
          SnackBar(
            content: Text(_createAccount
                ? 'Account created. This device is signed in as $email.'
                : 'Signed in as $email.'),
          ),
        );
      }
    } on ServerRequestException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not sign in: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: _createAccount ? 'Create an Apex Books account' : 'Sign in',
          subtitle: 'Businesses stay on this device and work offline either '
              'way. Signing in is what lets Apex Books erase or sync them for you.',
        ),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.showServerField) ...[
                  TextFormField(
                    controller: _serverController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://api.apexbooks.in',
                      prefixIcon: AtriaFieldIcon(Icons.link_rounded),
                      helperText: 'Leave as is for the standard Apex Books server.',
                    ),
                    // Empty is valid on purpose: it means "keep whatever is
                    // configured" (a fresh install falls back to the built-in
                    // address). Anything typed must be a usable server.
                    validator: (value) {
                      final raw = (value ?? '').trim();
                      if (raw.isEmpty) return null;
                      return ApiConfig.validateBaseUrl(raw);
                    },
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: AtriaFieldIcon(Icons.alternate_email_rounded),
                  ),
                  validator: (value) {
                    final email = (value ?? '').trim();
                    if (email.isEmpty) return 'Enter the email you sign in with.';
                    // Deliberately as loose as the server's own check: the only
                    // authoritative test of an address is whether mail arrives.
                    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                        .hasMatch(email)) {
                      return 'That does not look like an email address.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _busy ? null : _submit(),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const AtriaFieldIcon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  validator: (value) {
                    final password = value ?? '';
                    if (password.isEmpty) return 'Enter your password.';
                    // 8 characters is the server's floor at sign-up; it is
                    // checked only when creating an account, so an older
                    // password still signs in.
                    if (_createAccount && password.length < 8) {
                      return 'Use at least 8 characters.';
                    }
                    return null;
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer,
                      borderRadius:
                          const BorderRadius.all(Radius.circular(AppRadius.md)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: AppIconSize.md, color: scheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : Text(_createAccount ? 'Create account' : 'Sign in'),
                  ),
                ),
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _createAccount = !_createAccount;
                              _error = null;
                            }),
                    child: Text(_createAccount
                        ? 'I already have an account'
                        : 'Create an account instead'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
