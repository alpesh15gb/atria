import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/responsive/platform_ui.dart';
import 'mobile_page.dart';
import '../../core/theme/app_sizes.dart';
import 'atria_list_toolbar.dart';
import 'atria_page_header.dart';

/// The frame every branch-root list screen is built from.
///
/// Before this existed each screen assembled the same five things — heading,
/// search field, filter strip, summary, body — with its own paddings, and they
/// drifted: a 20px gutter on Sales/Items/Parties/Payments, a centred 1100px
/// column on Purchase, 840px on Expenses; a 20px toolbar over a 16px list; a
/// filter strip 42px tall on one screen and 44px on the next because it was
/// nested inside the search field's padding on one of them.
///
/// None of that is a bug on any single screen. Together it is why moving
/// between two lists felt like moving between two apps. The frame makes the
/// anatomy un-driftable: one gutter, one rhythm, one place the heading and its
/// actions live.
///
/// Order is fixed — heading, search, filters, [toolbar], body — because that is
/// the order every screen in the app now reads in.
///
/// **The body (or slivers) must be given a bounded height.** The frame puts the
/// body in an [Expanded], so it is only valid inside a parent that gives this
/// widget a finite height: a `Scaffold` body, a `Column` that is itself
/// bounded, or a pane the shell has already sized. Dropped into a
/// `SingleChildScrollView`, a `ListView` or a `Column(mainAxisSize:
/// MainAxisSize.min)` — anything that hands its children an unbounded height —
/// the [Expanded] throws at build time. A screen whose body has to scroll its
/// *whole* page instead of just its rows should build the `Scaffold` itself and
/// use [AtriaPageHeader], [AtriaFilterBar] and the toolbar rows directly rather
/// than reaching for this frame.
class AtriaListPage extends StatelessWidget {
  const AtriaListPage({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.search,
    this.filters = const [],
    this.toolbar = const [],
    this.body,
    this.slivers,
    this.mobileHeader,
  }) : assert(
         body == null || slivers == null,
         'Give AtriaListPage either a body or slivers, not both.',
       );

  /// Page heading, top-left.
  final String title;

  /// Optional quiet line under the heading.
  final String? subtitle;

  /// Page actions, right-aligned on the heading line: primary first.
  final List<Widget> actions;

  /// The page's search field ([TransactionSearchField] on every list today).
  final Widget? search;

  /// One [AtriaAdaptiveFilter] per filter group, in reading order.
  final List<Widget> filters;

  /// Extra full-width rows between the filters and the body — a summary card,
  /// a results line, a period selector.
  final List<Widget> toolbar;

  /// The scrolling body, when the screen is a plain box list.
  ///
  /// Requires a bounded height — see the class doc.
  final Widget? body;

  /// The scrolling body, when the screen is built from slivers.
  ///
  /// Requires a bounded height — see the class doc.
  final List<Widget>? slivers;
  final Widget? mobileHeader;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform.isMobileUi) {
      final date = filters
          .whereType<AtriaAdaptiveFilter>()
          .where((filter) => filter.label == 'Date')
          .firstOrNull;
      final remaining = filters.where((filter) => filter != date).toList();
      return MobileListPage(
        title: title,
        subtitle: subtitle,
        header: mobileHeader,
        actions: actions,
        toolbar: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (search != null && date != null)
                  Row(
                    children: [
                      Expanded(child: search!),
                      const SizedBox(width: 6),
                      date,
                    ],
                  )
                else
                  ?search,
                if (date != null && search == null) date,
                if (remaining.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 8),
                    child: AtriaFilterBar(
                      filters: remaining,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                for (final row in toolbar)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: row,
                  ),
              ],
            ),
          ),
        ],
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: body ?? CustomScrollView(slivers: slivers ?? const []),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.isCompact;
        final gutter = compact ? AppPage.gutterCompact : AppPage.gutter;
        final searchField = search;

        // The frame is also the page's Material. Each of these screens used to
        // own a `Scaffold` — the shell already provides one, so they were
        // nested — and dropping that took away the Material ancestor the
        // search `TextField` and the row `InkWell`s need. A transparent
        // Material gives them that without a second Scaffold's chrome.
        //
        // Centred and capped on a wide window: a document row at 1920dp is
        // ~1860dp of text, which nobody reads past the middle of. The cap only
        // applies past `expanded`, so a phone and a 900dp window are untouched.
        return Material(
          type: MaterialType.transparency,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.contentMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AtriaPageHeader(
                    title: title,
                    subtitle: subtitle,
                    compact: compact,
                    actions: actions,
                  ),
                  if (searchField != null)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        0,
                        gutter,
                        AppSpace.md,
                      ),
                      child: searchField,
                    ),
                  if (filters.isNotEmpty)
                    AtriaFilterBar(
                      filters: filters,
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        0,
                        gutter,
                        AppSpace.sm,
                      ),
                    ),
                  for (final row in toolbar)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        gutter,
                        0,
                        gutter,
                        AppSpace.md,
                      ),
                      child: row,
                    ),
                  // The body inherits the *same* gutter as the heading, the search
                  // field and the filter strip. Each list used to spell its own
                  // horizontal inset into its ListView — 16 here, 20 there, 8 in the
                  // master-detail split — so on a desktop window the rows sat 4px to
                  // the left of the search box directly above them, and on Purchase
                  // the summary card did not line up with either. Bodies therefore
                  // pad vertically only.
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gutter),
                      child:
                          body ??
                          CustomScrollView(slivers: slivers ?? const []),
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
}
