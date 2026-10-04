import 'package:flutter/widgets.dart';

/// Icon sizes.
///
/// There are five, and only five. The audit that prompted this file found
/// thirteen in use at once — 13, 14, 15, 16, 17, 18, 19, 20, 22, 28, 40, 44,
/// 53 — each chosen by hand, a pixel or two from its neighbour. That is what
/// "looks off" means when nothing is actually broken: a toolbar of icons that
/// are all *nearly* the same size reads as ragged, while four sizes that are
/// clearly different read as deliberate.
///
/// Pick by role, not by how big the icon should look in a particular row:
///
/// * [xs] — inside a dense cell or beside 12px text (a chip's caret).
/// * [sm] — inside a control: buttons, fields, segmented pills, list rows.
/// * [md] — a standalone affordance: an icon button, a filter glyph.
/// * [lg] — a leading glyph for a row or card heading.
/// * [xl] — navigation chrome (the rail).
///
/// [empty] is the oversized glyph an empty state or a hero card uses.
class AppIconSize {
  AppIconSize._();

  static const double xs = 14;
  static const double sm = 16;
  static const double md = 18;
  static const double lg = 20;
  static const double xl = 22;
  static const double empty = 44;

  /// The size every bare `Icon` falls back to. Set once in [AppTheme] so a
  /// widget that forgets a size is still on the scale.
  static const double fallback = sm;
}

/// Vertical rhythm, on a 4px grid.
///
/// The audit found 64 distinct paddings in the app, including 1px and 3px
/// vertical fudges on table rows and 14/15/18/19px card insets. Anything not
/// on this scale should be a deliberate exception, not a guess.
class AppSpace {
  AppSpace._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

/// Page-level geometry, in one place so a list screen cannot drift.
///
/// Sales, Items, Parties and Payments used a 20px gutter on a full-bleed body;
/// Purchase wrapped everything in a centred 1100px column (a 52px gutter) and
/// Expenses the same with 840px (a 182px gutter). Three different left edges
/// and three different right edges for the same kind of page — the single
/// most visible inconsistency in the product.
class AppPage {
  AppPage._();

  /// Left/right inset of page content from the chrome.
  static const double gutter = 20;

  /// The same inset on a phone, where 20 costs too much width.
  static const double gutterCompact = 16;

  /// Height of a page-level control: search field, filter select.
  static const double controlHeight = 34;

  /// Height of a table row.
  static const double rowHeight = 44;

  /// Vertical padding inside a card.
  static const EdgeInsets cardPadding = EdgeInsets.all(AppSpace.lg);

  /// The horizontal inset of a page toolbar row.
  static const EdgeInsets toolbar = EdgeInsets.symmetric(
    horizontal: gutter,
  );
}
