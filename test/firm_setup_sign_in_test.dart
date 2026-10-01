import 'package:atria/core/api/api_config.dart';
import 'package:atria/core/api/auth_client.dart';
import 'package:atria/core/api/server_client.dart' show ServerRequestException;
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/settings_repository.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/state/providers.dart';
import 'package:atria/core/theme/app_theme.dart';
import 'package:atria/features/onboarding/firm_setup_screen.dart';
import 'package:atria/features/settings/sign_in_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// First-run sign-in: the "Sign in with email" path on firm setup, and the
/// guard that a sign-in alone never drops the user into an app shell with no
/// business configured.
///
/// The redirect rule is covered at the decision-function level in
/// `onboarding_flow_test.dart`; this file covers what only a rendered screen
/// can — the choice card opening the form, a successful sign-in swapping it
/// for the continue panel, a wrong password surfacing the server's own
/// message, and the flag only flipping on success.
///
/// The network half is a stub, and deliberately so: a `testWidgets` body runs
/// in a zone where every `HttpClient` call is intercepted and answered with
/// 400 (flutter_test's own warning says as much), so the loopback-server
/// pattern that `auth_controller_test.dart` uses in plain `test()`s cannot
/// work here. What the stub cannot fake — the real request/response round
/// trip — is already covered there; what it can fake is the controller path,
/// and the drift-backed session and onboarding writes below it run for real.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _StubAuthClient authClient;
  late SettingsRepository settings;

  setUp(() async {
    db = AppDatabase.test(NativeDatabase.memory());
    settings = SettingsRepository(db);
    authClient = _StubAuthClient();
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiConfigProvider.overrideWithValue(ApiConfig(settings)),
        authClientProvider.overrideWithValue(authClient),
      ],
    );
    // Construct and settle the boot-gate providers now, exactly as the real
    // app does at launch. Reading them lazily from inside a screen callback
    // instead would let a fresh controller's still-in-flight _init() race the
    // very write the callback just made.
    await container.read(appInitializationProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    // A desktop-window surface, not the 800x600 default: this screen ships on
    // Windows first, and at the default width the PAN/State IntrinsicHeight
    // row overflows its dropdown before anything under test is reachable.
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const FirmSetupScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Bounded settle: the sign-in handler chains several drift writes through
  /// microtasks, and only then does the auth flip start the form's 280 ms
  /// AnimatedSwitcher fade-out — so the window has to cover the writes AND
  /// the transition, not just one of them.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Future<bool> onboardingPersisted() => container
      .read(settingsRepositoryProvider)
      .getBool(SettingsRepository.kOnboardingDone);

  Future<void> openSignIn(WidgetTester tester) async {
    await tester.tap(find.text('Sign in with email'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  const perTest = Timeout(Duration(minutes: 2));

  testWidgets('firm setup offers sign in with email as a third path',
      (tester) async {
    await pump(tester);

    expect(find.text('Sign in with email'), findsOneWidget);

    await openSignIn(tester);

    // The embedded form, not the Settings screen.
    expect(find.byType(SignInForm), findsOneWidget);
    expect(find.byType(SignInScreen), findsNothing);
    expect(find.byType(FirmSetupScreen), findsOneWidget);
  }, timeout: perTest);

  testWidgets('a successful sign-in shows the continue panel, flips the '
      'first-run flag, and configures no business', (tester) async {
    await pump(tester);
    await openSignIn(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'longenough',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    expect(find.text('owner@apexbooks.in'), findsOneWidget);
    expect(find.text('Create a new business on this device'), findsOneWidget);
    expect(find.byType(SignInForm), findsNothing);
    expect(authClient.calls, ['/v1/auth/login']);

    // The device is signed in, and first run is over — but no firm exists,
    // so the router will still land the user here after the flag flips.
    expect(await onboardingPersisted(), isTrue);
    expect(container.read(onboardingDoneProvider), isTrue);
    expect(container.read(activeFirmIdProvider), isNull);

    // "Create a new business" opens the manual form on this same screen. Its
    // submit button sits below the fold, so assert on the form's own top
    // content rather than dragging — a synthetic drag over a form full of
    // fields lands on one of them and opens it.
    await tester.tap(find.text('Create a new business on this device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Business profile'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Business name *'),
        findsOneWidget);
  }, timeout: perTest);

  testWidgets('a wrong password leaves first run unfinished and shows the '
      "server's message", (tester) async {
    authClient.loginError = 'Email or password is incorrect.';

    await pump(tester);
    await openSignIn(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'wrong',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    expect(find.text('Email or password is incorrect.'), findsOneWidget);
    expect(find.byType(SignInForm), findsOneWidget,
        reason: 'the form stays up so the user can retry');
    expect(await onboardingPersisted(), isFalse);
    expect(container.read(onboardingDoneProvider), isFalse);
  }, timeout: perTest);

  testWidgets('an account can be created from the embedded form too',
      (tester) async {
    await pump(tester);
    await openSignIn(tester);

    await tester.tap(find.text('Create an account instead'));
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'newowner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'longenough',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await settle(tester);

    expect(authClient.calls, ['/v1/auth/signup']);
    expect(find.text('newowner@apexbooks.in'), findsOneWidget);
  }, timeout: perTest);

  testWidgets('a session that predates the screen skips straight to the '
      'continue panel', (tester) async {
    await settings.set(SettingsRepository.kUserEmail, 'owner@apexbooks.in');
    await settings.set(SettingsRepository.kAccessToken, 'access-1');
    await settings.set(SettingsRepository.kRefreshToken, 'refresh-1');
    await settings.set(
      SettingsRepository.kAccessTokenExpiresAt,
      DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    );

    await pump(tester);
    await openSignIn(tester);

    // Signed in already, so the form never shows — and nothing re-auths.
    expect(find.byType(SignInForm), findsNothing);
    expect(find.text('Create a new business on this device'), findsOneWidget);
    expect(authClient.calls, isEmpty);
  }, timeout: perTest);

  testWidgets('the embedded form shows the server address, prefilled with '
      'the one requests would use', (tester) async {
    await pump(tester);
    await openSignIn(tester);

    // No setting is saved on a fresh install, so the field shows the
    // built-in default rather than an empty box.
    expect(find.text('Server address'), findsOneWidget);
    expect(
      tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Server address'),
      ).controller!.text,
      'https://api.apexbooks.in',
    );
  }, timeout: perTest);

  testWidgets('a typed server address is saved before the credentials '
      'travel', (tester) async {
    await pump(tester);
    await openSignIn(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'http://127.0.0.1:9000',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'longenough',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    // The address is normalised and persisted — and because the save is
    // awaited ahead of signIn, no future request can land on the previous
    // server. Loopback http is the one non-https address the config accepts.
    expect(
      await settings.get(SettingsRepository.kApiBaseUrl),
      'http://127.0.0.1:9000',
    );
    expect(authClient.calls, ['/v1/auth/login']);
  }, timeout: perTest);

  testWidgets('an unusable server address is refused before anything is '
      'sent', (tester) async {
    await pump(tester);
    await openSignIn(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      'not a server address',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'longenough',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    // The form never submits: validation runs first, so no credentials and
    // no sign-in reach a server the user has just mistyped.
    expect(find.byType(SignInForm), findsOneWidget);
    expect(authClient.calls, isEmpty);
    expect(
      await settings.get(SettingsRepository.kApiBaseUrl),
      isNull,
    );
  }, timeout: perTest);

  testWidgets('clearing the server field keeps the configured address and '
      'signs in anyway', (tester) async {
    await pump(tester);
    await openSignIn(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Server address'),
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'owner@apexbooks.in',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'longenough',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await settle(tester);

    // Empty means "use what is configured": nothing is overwritten, and the
    // sign-in proceeds.
    expect(
      await settings.get(SettingsRepository.kApiBaseUrl),
      isNull,
    );
    expect(find.text('Create a new business on this device'), findsOneWidget);
  }, timeout: perTest);

  test('a fresh sign-in alone still routes to firm setup, never the dashboard',
      () {
    // The redirect the router will run the moment the flag flips: signed in,
    // onboarding done, no business yet. It must come back HERE, not into a
    // shell with no firm.
    expect(
      resolveOnboardingRedirect(
        onboardingDone: true,
        activeFirmId: null,
        path: '/onboarding/firm-setup',
      ),
      isNull,
    );
  });
}

/// [AuthClient] with the network replaced. Only the two calls the onboarding
/// form can make are overridden; the class is subclassed rather than mocked
/// so a new method added to [AuthClient] keeps this stub compiling.
class _StubAuthClient extends AuthClient {
  _StubAuthClient() : super(ApiConfig(_NoSettings()));

  final calls = <String>[];

  /// When set, the next sign-in fails with this server message.
  String? loginError;

  @override
  Future<AuthTokens> signIn({
    required String email,
    required String password,
  }) async {
    calls.add('/v1/auth/login');
    final error = loginError;
    if (error != null) throw ServerRequestException(error);
    return _tokens(email);
  }

  @override
  Future<AuthTokens> signUp({
    required String email,
    required String password,
  }) async {
    calls.add('/v1/auth/signup');
    if (password.length < 8) {
      throw const ServerRequestException('Use at least 8 characters.');
    }
    return _tokens(email);
  }

  AuthTokens _tokens(String email) => AuthTokens(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        email: email,
      );
}

/// The stub never touches its config, but the constructor needs one.
class _NoSettings implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
