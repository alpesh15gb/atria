import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/auth_client.dart' show ServerFirmMembership;
import '../../core/api/server_client.dart' show ServerRequestException;
import '../../core/constants/indian_states.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/services/demo_seeder.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../settings/sign_in_screen.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/atria_logo.dart';
import '../../shared/widgets/common_widgets.dart';

/// First-run business creation. The user may either explore a pre-seeded demo
/// firm or type in their own business details.
class FirmSetupScreen extends ConsumerStatefulWidget {
  const FirmSetupScreen({super.key});

  @override
  ConsumerState<FirmSetupScreen> createState() => _FirmSetupScreenState();
}

enum _Path { undecided, manual, signIn }

class _FirmSetupScreenState extends ConsumerState<FirmSetupScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _legalNameController;
  late final TextEditingController _gstinController;
  late final TextEditingController _panController;
  late final TextEditingController _address1Controller;
  late final TextEditingController _address2Controller;
  late final TextEditingController _cityController;
  late final TextEditingController _pincodeController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;

  _Path _path = _Path.undecided;
  bool _busy = false;
  String? _stateCode;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _legalNameController = TextEditingController();
    _gstinController = TextEditingController();
    _panController = TextEditingController();
    _address1Controller = TextEditingController();
    _address2Controller = TextEditingController();
    _cityController = TextEditingController();
    _pincodeController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _legalNameController,
      _gstinController,
      _panController,
      _address1Controller,
      _address2Controller,
      _cityController,
      _pincodeController,
      _phoneController,
      _emailController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  // ---- Actions -----------------------------------------------------------

  Future<void> _chooseDemo() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      await DemoSeeder(db).seedIfNeeded();
      final firm = await db.firmRepository.defaultFirm;
      if (firm == null) throw StateError('Demo data could not be created.');
      await ref.read(activeFirmIdProvider.notifier).select(firm.id);
      await db.firmRepository.setDefault(firm.id);
      await ref.read(onboardingDoneProvider.notifier).complete();
      if (!mounted) return;
      context.go('/dashboard');
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not set up demo data: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final db = ref.read(appDatabaseProvider);
      final repo = db.firmRepository;
      final name = _nameController.text.trim();
      final legalName = _legalNameController.text.trim();
      final gstin = _gstinController.text.trim().toUpperCase();
      final pan = _panController.text.trim().toUpperCase();
      final address1 = _address1Controller.text.trim();
      final address2 = _address2Controller.text.trim();
      final city = _cityController.text.trim();
      final pincode = _pincodeController.text.trim();
      final phone = _phoneController.text.trim();
      final email = _emailController.text.trim();

      final firm = await repo.create(
        name: name,
        legalName: legalName.isEmpty ? null : legalName,
        gstin: gstin.isEmpty ? null : gstin,
        pan: pan.isEmpty ? null : pan,
        stateCode: _stateCode,
        addressLine1: address1.isEmpty ? null : address1,
        city: city.isEmpty ? null : city,
        pincode: pincode.isEmpty ? null : pincode,
        phone: phone.isEmpty ? null : phone,
        email: email.isEmpty ? null : email,
        makeDefault: true,
      );
      // The create signature has no address-line-2 parameter, so persist it
      // as a follow-up write instead of dropping what the user typed.
      if (address2.isNotEmpty) {
        await repo.update(firm.copyWith(addressLine2: Value(address2)));
      }
      await ref.read(activeFirmIdProvider.notifier).select(firm.id);
      await ref.read(onboardingDoneProvider.notifier).complete();
      if (!mounted) return;
      context.go('/dashboard');
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not save your business: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Flips the first-run flag once this device holds a session. Deliberately
  /// not navigation: the signed-in panel appears on its own when the auth
  /// state flips, and moving to the business form is the panel's button, so
  /// the person sees where they are before moving on.
  Future<void> _completeAfterSignIn() async {
    await ref.read(onboardingDoneProvider.notifier).complete();
  }

  /// What a signed-in user sees instead of the form: confirmation, the one
  /// line of what it means, and the way forward. Reading the address from
  /// [AuthState] rather than a callback keeps the panel truthful even when the
  /// session predates this screen.
  ///
  /// The panel offers RESTORE alongside "Add my business": an account that
  /// already syncs from another device can pull its books here instead of
  /// starting over. That is the point of signing in on a second device —
  /// without it, sign-in would only ever precede re-typing a business.
  Widget _authSignedInPanel(String email) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      key: const ValueKey(_Path.signIn),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        const Center(child: AtriaWordmark(logoSize: 44, fontSize: 26, showTagline: true)),
        const SizedBox(height: 28),
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
                      email,
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
                _restoreMessage ??
                    'This device now holds a session for that account. Your '
                    'books stay on this device and sync is optional — turn it '
                    'on in Settings to send and receive changes.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
              ),
            ],
          ),
        ),
        if (_restoreFirms != null && _restoreFirms!.isNotEmpty) ...[
          const SizedBox(height: 16),
          AtriaCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Businesses on the server for this account:',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                for (final firm in _restoreFirms!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: PhosphorIcon(
                      PhosphorIconsRegular.buildings,
                      size: 20,
                      color: scheme.primary,
                    ),
                    title: Text(
                      firm.name.isEmpty ? firm.firmId : firm.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      firm.role == 'admin' ? 'Full access' : 'Member',
                    ),
                    trailing: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: _busy ? null : () => _restoreFirm(firm),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _loadRestoreOptions,
          child: Text(
            (_restoreFirms == null || _restoreFirms!.isEmpty)
                ? 'Check for businesses on the server'
                : 'Refresh list',
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          onPressed: _busy ? null : () => setState(() => _path = _Path.manual),
          child: const Text('Create a new business on this device'),
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _busy ? null : () => setState(() => _path = _Path.undecided),
            child: const Text('Back to options'),
          ),
        ),
      ],
    );
  }

  /// Memberships the server reports for this account, once fetched.
  List<ServerFirmMembership>? _restoreFirms;
  String? _restoreMessage;

  /// Asks the server what this account could restore.
  Future<void> _loadRestoreOptions() async {
    setState(() => _busy = true);
    try {
      final token = await ref.read(authControllerProvider.notifier).accessToken();
      if (token == null) {
        setState(() {
          _restoreMessage = 'Your session has expired. Sign in again.';
          _restoreFirms = null;
        });
        return;
      }
      final account = await ref
          .read(authClientProvider)
          .me(accessToken: token);
      setState(() {
        _restoreFirms = account.firms;
        _restoreMessage = account.firms.isEmpty
            ? 'The server has no businesses for this account yet. Create one '
                'here, or sign in on the device that has your books and turn '
                'sync on there first.'
            : null;
      });
    } on ServerRequestException catch (error) {
      setState(() {
        _restoreMessage = error.message;
        _restoreFirms = null;
      });
    } on Object catch (error) {
      setState(() {
        _restoreMessage = 'Could not reach the server: $error';
        _restoreFirms = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Restores one firm: pulls its whole journal onto this device, marks
  /// onboarding done, and opens the books.
  ///
  /// The firm row itself arrives through its own journalled insert, so the
  /// pull is all it takes — no local creation, no placeholder. If the journal
  /// is empty (a business created but never synced from the original device),
  /// the restore reports exactly that rather than opening empty books that
  /// look like data loss.
  Future<void> _restoreFirm(ServerFirmMembership firm) async {
    setState(() => _busy = true);
    try {
      final engine = ref.read(syncEngineProvider);
      final report = await engine.restoreFirm(firm.firmId);
      if (!report.restored) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(report.describe)),
          );
        }
        return;
      }
      await ref.read(onboardingDoneProvider.notifier).complete();
      await ref.read(activeFirmIdProvider.notifier).select(firm.firmId);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restore failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onGstinChanged(String value) {
    final gstin = value.trim().toUpperCase();
    if (!Validators.isValidGstin(gstin)) return;
    // Derive state and PAN straight from the GSTIN.
    final stateCode = IndianStates.stateCodeFromGstin(gstin);
    if (stateCode != null && _stateCode == null) {
      setState(() => _stateCode = stateCode);
    }
    if (_panController.text.trim().isEmpty) {
      _panController.text = gstin.substring(2, 12);
    }
  }

  // ---- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Watched so a completed sign-in swaps the form for the continue panel on
    // its own — including a session that already existed when this screen
    // opened, e.g. one signed in from Settings earlier.
    final auth = ref.watch(authControllerProvider);
    return Scaffold(
      appBar: AppBar(
        leading: _path == _Path.undecided
            ? null
            : IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _busy ? null : () => setState(() => _path = _Path.undecided),
              ),
        title: const Text('Set up your business'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 640,
                ),
                child: _busy
                    ? const _BusyPanel(message: 'Preparing your books…')
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: switch (_path) {
                          _Path.undecided => _choiceSection(),
                          _Path.manual => _formSection(),
                          _Path.signIn => auth.signedIn
                              ? _authSignedInPanel(auth.email)
                              : SignInForm(
                                  onAuthenticated: (_) =>
                                      _completeAfterSignIn(),
                                  // First run has no way to reach the Settings
                                  // server card, so this is the one place a
                                  // self-hosting firm can point the app at
                                  // their own server before any credentials
                                  // travel.
                                  showServerField: true,
                                ),
                        },
                      ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _choiceSection() {
    return ListView(
      key: const ValueKey(_Path.undecided),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        const Center(child: AtriaWordmark(logoSize: 44, fontSize: 26, showTagline: true)),
        const SizedBox(height: 28),
        Text(
          'How would you like to begin?',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'You can switch businesses or add your own details any time from Settings.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        _PathCard(
          icon: PhosphorIconsRegular.sparkle,
          title: 'Start with demo data',
          subtitle: 'Explore a sample hardware business with invoices, '
              'parties, stock and reports already filled in.',
          badge: 'Fastest',
          onTap: _chooseDemo,
        ),
        const SizedBox(height: 12),
        _PathCard(
          icon: PhosphorIconsRegular.buildings,
          title: 'Enter my business details',
          subtitle: 'Create your own firm from scratch. Takes about a minute.',
          onTap: () => setState(() => _path = _Path.manual),
        ),
        const SizedBox(height: 12),
        _PathCard(
          icon: PhosphorIconsRegular.signIn,
          title: 'Sign in with email',
          subtitle: 'Use an Atria account on this device, so a later backup '
              'or sync can reach the server.',
          onTap: () => setState(() => _path = _Path.signIn),
        ),
        const SizedBox(height: 20),
        _trustNote,
      ],
    );
  }

  Widget get _trustNote {
    final scheme = Theme.of(context).colorScheme;
    return AtriaCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.lockKey,
            size: 20,
            color: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Everything stays on this device. Atria works fully offline and '
              'never uploads your books anywhere.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formSection() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          _introCard,
          const SizedBox(height: 20),
          const SectionHeader(title: 'Business profile'),
          TextFormField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Business name *',
              hintText: 'e.g. Shri Balaji Traders',
              prefixIcon: AtriaFieldIcon(Icons.storefront_outlined),
            ),
            validator: Validators.name,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _legalNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Legal / registered name',
              hintText: 'Optional — as printed on invoices',
              prefixIcon: AtriaFieldIcon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          _gstinField(),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _panController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                UpperCaseInputFormatter(),
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: const InputDecoration(
                labelText: 'PAN',
                hintText: 'ABCDE1234F',
                prefixIcon: AtriaFieldIcon(Icons.credit_card_outlined),
                counterText: '',
              ),
              maxLength: 10,
              validator: Validators.pan,
            ),
            second: _stateField(),
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Address'),
          TextFormField(
            controller: _address1Controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Address line 1',
              hintText: 'Shop / building no., street',
              prefixIcon: AtriaFieldIcon(Icons.location_on_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _address2Controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Address line 2',
              hintText: 'Area, locality',
              prefixIcon: AtriaFieldIcon(Icons.signpost_outlined),
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _cityController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'City',
                prefixIcon: AtriaFieldIcon(Icons.location_city_outlined),
              ),
            ),
            second: TextFormField(
              controller: _pincodeController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                labelText: 'PIN code',
                prefixIcon: AtriaFieldIcon(Icons.markunread_mailbox_outlined),
                counterText: '',
              ),
              maxLength: 6,
              validator: Validators.pincode,
            ),
          ),
          const SizedBox(height: 24),
          const SectionHeader(title: 'Contact'),
          _FieldRow(
            first: TextFormField(
              controller: _phoneController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone',
                hintText: '9876543210',
                prefixText: '+91 ',
                prefixIcon: AtriaFieldIcon(Icons.phone_outlined),
                counterText: '',
              ),
              maxLength: 10,
              validator: Validators.phone,
            ),
            second: TextFormField(
              controller: _emailController,
              textInputAction: TextInputAction.done,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'name@business.in',
                prefixIcon: AtriaFieldIcon(Icons.mail_outline_rounded),
              ),
              validator: Validators.email,
            ),
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: const Text('Create my business'),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              onPressed: _busy ? null : () => setState(() => _path = _Path.signIn),
              child: const Text('Sign in with email instead'),
            ),
          ),
        ],
      ),
    );
  }

  Widget get _introCard {
    return AtriaCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      background: Theme.of(context).colorScheme.primaryContainer,
      showBorder: false,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
            ),
            alignment: Alignment.center,
            child: PhosphorIcon(
              PhosphorIconsRegular.buildings,
              size: 20,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Almost there',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'These details appear on your invoices and GST reports. '
                  'Only the business name is required.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onPrimaryContainer
                            .withValues(alpha: 0.85),
                        height: 1.45,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gstinField() {
    return ListenableBuilder(
      listenable: _gstinController,
      builder: (context, _) {
        final value = _gstinController.text.trim().toUpperCase();
        final valid = Validators.isValidGstin(value);
        final looksRight = Validators.looksLikeGstin(value);
        final scheme = Theme.of(context).colorScheme;
        final colors = atriaColors(context);

        return TextFormField(
          controller: _gstinController,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            UpperCaseInputFormatter(),
            LengthLimitingTextInputFormatter(15),
          ],
          maxLength: 15,
          onChanged: _onGstinChanged,
          validator: Validators.gstin,
          decoration: InputDecoration(
            labelText: 'GSTIN',
            hintText: '29ABCDE1234F1Z5',
            prefixIcon: const AtriaFieldIcon(Icons.receipt_long_outlined),
            counterText: '',
            helperText: value.isEmpty
                ? 'Optional — leave blank if unregistered'
                : valid
                    ? 'Valid GSTIN'
                    : looksRight
                        ? 'Checking checksum…'
                        : null,
            helperStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: valid ? colors.positive : scheme.onSurfaceVariant,
                  fontWeight: valid ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
            suffixIcon: value.isEmpty
                ? null
                : valid
                    ? Icon(
                        Icons.verified_rounded,
                        size: AppIconSize.md,
                        color: colors.positive,
                      )
                    : looksRight
                        ? Icon(
                            Icons.hourglass_top_rounded,
                            size: AppIconSize.md,
                            color: scheme.onSurfaceVariant,
                          )
                        : Icon(
                            Icons.error_outline_rounded,
                            size: AppIconSize.md,
                            color: scheme.error,
                          ),
          ),
        );
      },
    );
  }

  Widget _stateField() {
    return DropdownButtonFormField<String?>(
      iconSize: AppIconSize.md,
      // Expand the selected item into the field instead of sizing it to its
      // content: state names run to "Dadra & Nagar Haveli and Daman & Diu",
      // and at a half-width field that text overflows the dropdown's inner
      // row instead of being constrained to it.
      isExpanded: true,
      initialValue: _stateCode,
      decoration: const InputDecoration(
        labelText: 'State',
        hintText: 'Select state',
        prefixIcon: AtriaFieldIcon(Icons.map_outlined),
      ),
      items: [
        for (final state in IndianStates.all)
          DropdownMenuItem<String?>(
            value: state.code,
            child: Text(
              '${state.code} — ${state.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
      onChanged: (value) => setState(() => _stateCode = value),
    );
  }
}

/// Two fields side by side on wide content areas, stacked on narrow ones.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: 12),
              second,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: first),
              const SizedBox(width: 12),
              Expanded(child: second),
            ],
          ),
        );
      },
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AtriaCard(
      onTap: onTap,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: isDark ? 0.24 : 0.12),
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.md)),
            ),
            alignment: Alignment.center,
            child: PhosphorIcon(icon, size: 22, color: scheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: atriaColors(context).saffronGradientStart
                              .withValues(alpha: isDark ? 0.22 : 0.14),
                          borderRadius: const BorderRadius.all(
                              Radius.circular(AppRadius.pill)),
                        ),
                        child: Text(
                          badge!,
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: atriaColors(context).warning,
                                  ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _BusyPanel extends StatelessWidget {
  const _BusyPanel({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.6),
        ),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(
            message!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}
