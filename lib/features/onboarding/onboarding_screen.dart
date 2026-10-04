import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/database/repositories/repository_extensions.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/atria_logo.dart';

/// The first-run welcome experience: three pages that pitch the app, then
/// route the user to firm setup or straight to the dashboard.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  static const _pages = <_OnboardingPage>[
    _OnboardingPage(
      icon: PhosphorIconsRegular.invoice,
      headline: 'Invoices in seconds',
      body: 'GST-ready billing with automatic CGST / SGST / IGST split, '
          'e-invoice style print layouts and one-tap WhatsApp share.',
      chips: ['GSTIN & HSN', 'Print & PDF', 'UPI QR'],
    ),
    _OnboardingPage(
      icon: PhosphorIconsRegular.wifiSlash,
      headline: 'Offline-first. Your books stay with you',
      body: 'Everything is stored on this device. Bill in a basement, a '
          'godown or on the road — no internet, no subscription, no lock-in.',
      chips: ['No login needed', 'Works offline', 'Private & local'],
    ),
    _OnboardingPage(
      icon: PhosphorIconsRegular.chartLineUp,
      headline: 'Reports, stock & GST — all in one place',
      body: 'GSTR-style summaries, party ledgers, low-stock alerts and '
          'profit insight across every business you run.',
      chips: ['GSTR reports', 'Stock tracking', 'Multi-business'],
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  bool get _isLastPage => _page == _pages.length - 1;

  Future<void> _finish() async {
    // Flip the in-memory flag first so the router redirect sees it before we
    // navigate; persistence follows.
    await ref.read(onboardingDoneProvider.notifier).complete();

    final db = ref.read(appDatabaseProvider);
    final hasFirm = (await db.firmRepository.defaultFirm) != null;
    if (!mounted) return;
    context.go(hasFirm ? '/dashboard' : '/onboarding/firm-setup');
  }

  void _next() {
    if (_isLastPage) {
      _finish();
      return;
    }
    _pageController.nextPage(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Subtle branded wash across the whole canvas.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 1.5,
                      colors: [
                        Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: isDark ? 0.16 : 0.10),
                        Theme.of(context).scaffoldBackgroundColor,
                      ],
                      stops: const [0.0, 0.65],
                    ),
                  ),
                ),
              ),
            ),
            _body,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _footer,
            ),
          ],
        ),
      ),
    );
  }

  Widget get _body {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Row(
            children: [
              const AtriaWordmark(logoSize: 30, fontSize: 18),
              const Spacer(),
              TextButton(
                onPressed: _finish,
                child: const Text('Skip'),
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pageController,
            // The platform's own page physics — bouncing on iOS/macOS,
            // clamping (with Android's overscroll glow) everywhere else.
            // `BouncingScrollPhysics` was hard-coded here, which handed Android
            // a rubber-band affordance it has nowhere else in the product and
            // which reads as "broken" on a device that always stops dead at the
            // end of a list.
            //
            // `AlwaysScrollableScrollPhysics` stays in the chain: without it
            // `ClampingScrollPhysics.shouldAcceptUserOffset` is false whenever
            // the three pages fit on one screen, so the gesture that opens
            // onboarding would be dead on a tall window.
            physics: ScrollConfiguration.of(context)
                .getScrollPhysics(context)
                .applyTo(const AlwaysScrollableScrollPhysics()),
            onPageChanged: (index) => setState(() => _page = index),
            itemCount: _pages.length,
            itemBuilder: (context, index) => _OnboardingPageView(
              page: _pages[index],
              foreground: index == _page,
            ),
          ),
        ),
      ],
    );
  }

  Widget get _footer {
    final text = Theme.of(context).textTheme;
    final background = Theme.of(context).scaffoldBackgroundColor;
    return Material(
      // Opaque. The page behind is a scrolling view and the footer is an
      // overlay, so with only the padding it used to carry, mid-scroll text
      // passed *behind* the indicator row and the Next button and was visible
      // through the gaps around them — the headline sat on top of a paragraph
      // mid-word. The page's own wash is a gradient that resolves to
      // [scaffoldBackgroundColor] by the time it reaches this height, so this
      // is the colour that already sits under it: the bar disappears except
      // where it must not.
      color: background,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A short fade rather than a hard line, so the page appears to run
          // under the bar instead of stopping at it.
          Container(
            height: 12,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [background.withValues(alpha: 0), background],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _indicator,
                const SizedBox(height: 20),
                Row(
                  children: [
                    // Flexible: at a 2.0× system font (see `app.dart`, which no
                    // longer caps text scaling) "Step 1 of 3" and "Get Started"
                    // together are wider than a 320dp phone, and a bare [Text]
                    // in a [Row] is given an unbounded width — so this was the
                    // overflow, not a squeeze.
                    Flexible(
                      child: Text(
                        _isLastPage
                            ? 'You are all set'
                            : 'Step ${_page + 1} of ${_pages.length}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          fontWeight: _isLastPage ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _next,
                      icon: const Icon(
                        Icons.arrow_forward_rounded,
                        size: AppIconSize.md,
                      ),
                      label: Text(
                        _isLastPage ? 'Get Started' : 'Next',
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget get _indicator {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.start,
      children: [
        for (var i = 0; i < _pages.length; i++) ...[
          if (i != 0) const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            height: 6,
            width: i == _page ? 26 : 6,
            decoration: BoxDecoration(
              color: i == _page
                  ? scheme.primary
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.all(
                Radius.circular(i == _page ? AppRadius.pill : 3),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

@immutable
class _OnboardingPage {
  const _OnboardingPage({
    required this.icon,
    required this.headline,
    required this.body,
    required this.chips,
  });

  final IconData icon;
  final String headline;
  final String body;
  final List<String> chips;
}

class _OnboardingPageView extends StatelessWidget {
  const _OnboardingPageView({required this.page, required this.foreground});

  final _OnboardingPage page;
  final bool foreground;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.isCompact;
        // Room for the footer, which now paints its own background over the
        // tail of the page. 116 covers its height at the default text size; a
        // larger system font makes the button taller, so the reservation grows
        // with it instead of leaving the last line permanently under the bar.
        final footerSpace = 116 *
            MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 2.0);
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            isCompact ? 24 : 48,
            isCompact ? 12 : 28,
            isCompact ? 24 : 48,
            footerSpace,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _hero(context, isCompact),
                  SizedBox(height: isCompact ? 28 : 40),
                  AnimatedSlide(
                    duration: const Duration(milliseconds: 420),
                    curve: Curves.easeOutCubic,
                    offset: foreground ? Offset.zero : const Offset(0, 0.12),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      opacity: foreground ? 1 : 0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            page.headline,
                            style: Theme.of(context)
                                .textTheme
                                .displayMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  height: 1.18,
                                ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            page.body,
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  height: 1.55,
                                ),
                          ),
                          const SizedBox(height: 22),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final chip in page.chips)
                                _FeatureChip(label: chip),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _hero(BuildContext context, bool isCompact) {
    final colors = atriaColors(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // One tile, one glyph. The glyph used to be `size * 0.46`, which made it
    // 42.3px on a phone and 53.4px on a desktop — two sizes that exist nowhere
    // else in the product — and the tile differed too for no reason the layout
    // needed.
    const size = AppSpace.xxxl * 3;

    return Center(
      child: AnimatedScale(
        scale: foreground ? 1.0 : 0.94,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 360),
          opacity: foreground ? 1 : 0.35,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Soft glow halo.
              Container(
                width: size * 1.72,
                height: size * 1.72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      colors.brandGradientStart.withValues(alpha: 0.22),
                      colors.brandGradientStart.withValues(alpha: 0.0),
                    ],
                    stops: const [0.0, 1.0],
                  ),
                ),
              ),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.xl)),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      colors.brandGradientStart,
                      colors.brandGradientEnd,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: colors.brandGradientEnd
                          .withValues(alpha: isDark ? 0.55 : 0.35),
                      blurRadius: 28,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: PhosphorIcon(
                  page.icon,
                  size: AppIconSize.empty,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.pill)),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.14),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PhosphorIcon(
            PhosphorIconsRegular.checkCircle,
            size: 14,
            color: scheme.primary,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}
