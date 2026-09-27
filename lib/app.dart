import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/state/providers.dart';
import 'core/theme/app_theme.dart';

class AtriaApp extends ConsumerWidget {
  const AtriaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'Atria — Accounting & GST Billing',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      locale: const Locale('en', 'IN'),
      supportedLocales: const [
        Locale('en', 'IN'),
        Locale('en'),
      ],
      // One router for the app's whole lifetime. The boot splash is now the
      // `/boot` route inside it (see [appRouterProvider]); swapping the
      // routerConfig between a splash router and the real one used to strand
      // Android relaunches — the engine re-delivers the last route after
      // process death, and the splash-only boot router had no such route, so
      // go_router's default "The route /onboarding/firm-setup does not exist"
      // page appeared before the real router ever mounted.
      routerConfig: ref.watch(appRouterProvider),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            // Cap text scaling so accounting tables stay legible and aligned.
            textScaler: MediaQuery.textScalerOf(context).clamp(
              maxScaleFactor: 1.15,
            ),
          ),
          child: child!,
        );
      },
    );
  }
}
