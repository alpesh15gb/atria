import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import 'atria_avatar.dart';
import 'atria_global_search.dart';
import 'atria_logo.dart';

/// The application chrome QuickBooks keeps for the *whole product*: one white
/// band across the top, above both the navigation pane and the page, holding
/// the wordmark, the business switcher, global search and the account
/// controls.
///
/// This is deliberately not a per-page `AppBar`. In Material every screen
/// grows its own title bar, so the search box, the business you are in and the
/// settings gear either disappear as you navigate or get duplicated on every
/// page. QBO pins them once, and the page below only carries its own title and
/// its own actions.
class AtriaTopBar extends ConsumerWidget {
  const AtriaTopBar({
    super.key,
    this.leadingWidth = 0,
    this.compactLeading = false,
  });

  /// Width of the navigation pane below, so the wordmark sits exactly above
  /// the nav column instead of floating over the page.
  final double leadingWidth;

  /// Narrow rail: logo only, no wordmark.
  final bool compactLeading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final firm = ref.watch(activeFirmProvider).valueOrNull;

    return Material(
      color: scheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: scheme.outline)),
        ),
        child: SafeArea(
          bottom: false,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Two things in this bar can shrink: the business name and the
              // search field. Everything else is fixed chrome and is measured
              // first, so the two of them share what is genuinely left.
              //
              // This arithmetic exists because every child of this Row except
              // the Spacer used to have a fixed width, and a Row lays its
              // non-flex children out with an unbounded main-axis constraint —
              // so the 220dp business label and the 300dp search box were each
              // laid out at their full size and the bar overflowed outright
              // between roughly 840 and 944dp. That band is not theoretical:
              // the 1280px default window is 853dp at 150% display scaling.
              //
              // Fixed chrome, worst case (the popup paddings and the caret on
              // the business switcher, the gear, the account avatar, the gaps).
              final pane = leadingWidth > 0 ? leadingWidth + 12 : 132;
              const businessChrome = 52; // popup padding + field padding + caret
              const gearAndAccount = 48 + 52 + 12; // IconButton, menu, gap
              const chrome = businessChrome + 4 + gearAndAccount;

              // The business name keeps its own 220dp cap; the search field
              // takes what is left, up to 300dp.
              final budget = constraints.maxWidth - pane - chrome;
              final labelWidth = budget.clamp(0.0, 220.0);
              final searchWidth = (budget - labelWidth).clamp(0.0, 300.0);

              // A truncated-to-nothing business name is noise, and a search box
              // narrower than its own placeholder is noise too — below these
              // floors the bar drops the feature instead of clipping it.
              final showBusiness =
                  constraints.maxWidth >= 560 && labelWidth >= 40;
              final showSearchField = searchWidth >= 140;

              return SizedBox(
                height: 52,
                child: Row(
                  children: [
                    if (leadingWidth > 0)
                      SizedBox(
                        width: leadingWidth,
                        child: Padding(
                          padding: EdgeInsets.only(left: compactLeading ? 0 : 14),
                          child: compactLeading
                              ? const Center(child: AtriaLogo(size: 26))
                              : const Align(
                                  alignment: Alignment.centerLeft,
                                  child: AtriaWordmark(
                                    logoSize: 24,
                                    fontSize: 16,
                                  ),
                                ),
                        ),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.only(left: 12),
                        child: AtriaWordmark(logoSize: 24, fontSize: 16),
                      ),
                    if (leadingWidth > 0) const SizedBox(width: 12),
                    if (showBusiness) ...[
                      _BusinessSwitcher(
                        firmName: firm?.name,
                        labelWidth: labelWidth,
                      ),
                      const SizedBox(width: 4),
                    ],
                    const Spacer(),
                    if (showSearchField)
                      _SearchBox(
                        width: searchWidth,
                        onTap: () => showAtriaGlobalSearch(context),
                      )
                    else
                      IconButton(
                        tooltip: 'Search',
                        onPressed: () => showAtriaGlobalSearch(context),
                        icon: const Icon(
                          PhosphorIconsRegular.magnifyingGlass,
                          size: 18,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Settings',
                      // `go`, not `push`: /settings is the ROOT of a
                      // StatefulShellBranch, and go_router resolves an
                      // imperative push of a branch root as a sibling of the
                      // shell match — which hosts the page on the ROOT
                      // navigator, outside the nav rail and bottom bar, and
                      // leaves Android Back unwinding to the pre-push screen
                      // instead of behaving like a tab.
                      onPressed: () => context.go('/settings'),
                      icon: const Icon(PhosphorIconsRegular.gear, size: 18),
                    ),
                    _AccountMenu(firmName: firm?.name),
                    const SizedBox(width: 12),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// `Business name ▾` — QBO's company switcher, which is where the app tells
/// you *which set of books* you are looking at.
class _BusinessSwitcher extends ConsumerWidget {
  const _BusinessSwitcher({required this.firmName, required this.labelWidth});

  final String? firmName;

  /// Space the business name may take, computed by the bar from what is left
  /// after the fixed chrome and the search field. Long names ellipsise rather
  /// than pushing the search box off a narrow window.
  final double labelWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final name = (firmName ?? '').trim();
    if (name.isEmpty) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: 'Switch business',
      offset: const Offset(0, 40),
      position: PopupMenuPosition.under,
      // `go`, not `push` — see the comment on the gear. These are all inside
      // the settings branch, so a push would host them on the root navigator,
      // outside the rail.
      onSelected: (route) => context.go(route),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(
            'BUSINESS',
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const PopupMenuItem<String>(
          value: '/settings/firm',
          height: 38,
          child: Text('Company profile'),
        ),
        const PopupMenuItem<String>(
          value: '/settings/backup',
          height: 38,
          child: Text('Data and backup'),
        ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Long business names must not push the search box off a narrow
            // window, so the label is capped at whatever the bar could spare.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: labelWidth),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              PhosphorIconsRegular.caretDown,
              size: 14,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The global search affordance. In QBO this is a real field in the chrome; it
/// opens the search panel rather than filtering whatever page you happen to be
/// on.
class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.width, required this.onTap});

  /// Computed by the bar from the space left after the fixed chrome, so the
  /// field narrows on a tight window instead of overflowing it.
  final double width;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: SizedBox(
        width: width,
        height: 34,
        child: Material(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.xs),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                border: Border.all(color: scheme.outline),
              ),
              child: Row(
                children: [
                  Icon(
                    PhosphorIconsRegular.magnifyingGlass,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Search',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The account control at the far right: QBO's initials avatar opening the
/// account menu.
class _AccountMenu extends ConsumerWidget {
  const _AccountMenu({required this.firmName});

  final String? firmName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return PopupMenuButton<String>(
      tooltip: 'Account',
      offset: const Offset(-150, 40),
      position: PopupMenuPosition.under,
      // `go`, not `push` — see the comment on the gear.
      onSelected: (route) => context.go(route),
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(
            (firmName ?? 'Atria').toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const PopupMenuItem<String>(
          value: '/settings/firm',
          height: 38,
          child: Text('Company profile'),
        ),
        const PopupMenuItem<String>(
          value: '/settings/audit-log',
          height: 38,
          child: Text('Audit log'),
        ),
        const PopupMenuItem<String>(
          value: '/settings',
          height: 38,
          child: Text('Settings'),
        ),
      ],
      // The same avatar the party list and the dashboard use. It used to be a
      // bespoke 32px circle whose initials were built from the *first and last*
      // words of the firm name ("Shri Balaji Traders" -> "ST") while the party
      // list built the same name as "SB".
      child: AtriaAvatar.initials(
        name: firmName ?? 'Atria',
        radius: AtriaAvatar.row,
      ),
    );
  }
}
