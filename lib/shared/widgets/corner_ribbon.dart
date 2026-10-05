import 'package:flutter/material.dart';

import '../../core/theme/app_radius.dart';

/// The **corner ribbon** a warning sits on, from the reference's cards.
///
/// "Overdue by 211 days" and "Qty: -3.00 UNT" are not chips sitting inside the
/// card — they are blocks on its **top-right corner**, overhanging the corner's
/// rounding. That overhang is what makes the badge read as attached to the card
/// rather than floating inside it, which is why this is its own widget rather
/// than a `Chip`.
///
/// The distinction is not cosmetic: a chip in the flow takes space from the
/// card's own layout, so a row whose warning is long enough to wrap pushes the
/// party name and the amount apart. The ribbon takes space from **nowhere** —
/// it is painted in the card's top-right and the content below starts at the
/// card's own padding.
class CornerRibbon extends StatelessWidget {
  const CornerRibbon({
    super.key,
    required this.label,
    required this.tone,
    this.width = 116,
  });

  /// The words. Short by design — a ribbon is a signal, not a sentence.
  final String label;

  /// [RibbonTone.amber] for something overdue, [RibbonTone.red] for something
  /// negative, [RibbonTone.neutral] for a plain note.
  final RibbonTone tone;

  /// How wide the block is, so its left edge lands in the same place on every
  /// card in a list. Without a fixed width the block grows with its label and
  /// the ribbon's left edge becomes a ragged edge down the list.
  final double width;

  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (tone) {
      RibbonTone.amber => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      RibbonTone.red => (scheme.errorContainer, scheme.onErrorContainer),
      RibbonTone.neutral => (scheme.surfaceContainerHighest, scheme.onSurface),
    };

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        // Only the two corners the ribbon touches. The card's own rounding shows
        // through the other two, which is what makes it read as overhanging.
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(AppRadius.sm),
          topRight: Radius.circular(AppRadius.sm),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
      ),
    );
  }
}

/// What a [CornerRibbon] is warning about.
///
/// **Three tones, and the third is not an error.** An amber ribbon means overdue
/// — attention without alarm. A red one means a negative number, which is a fact
/// about the books rather than a thing to chase. Neutral is for a plain
/// annotation, and it exists so a caller reaching for "something to show here"
/// does not reach for red by default.
enum RibbonTone { amber, red, neutral }

/// A card that carries a corner ribbon.
///
/// The ribbon is **overlaid**, not laid out: it is painted in the card's top-right
/// corner and the card's own padding is increased by [ribbonHeight] so the first
/// row of content still starts below it. Laying it out instead — a `Row` with a
/// `Spacer` and the ribbon as a sibling — would make every card's content height
/// depend on whether it happened to have a warning, so a list would not line up.
///
/// Desktop cards do not use this. The ribbon is phone grammar; on a wide table
/// the status is a column, and a block overhanging a table row reads as damage.
class RibbonCard extends StatelessWidget {
  const RibbonCard({
    super.key,
    required this.child,
    this.ribbon,
    this.padding = const EdgeInsets.fromLTRB(12, 12, 12, 12),
  });

  final Widget child;
  final CornerRibbon? ribbon;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        // The card's own surface, first, so the content and the ribbon both sit
        // over it. A `Stack` paints in order and a background added last would
        // cover the very thing it is a background for.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: AppRadius.mdAll,
            ),
          ),
        ),
        Padding(
          // Extra top padding while a ribbon is present, so nothing the card
          // says is painted under it.
          padding: ribbon == null
              ? padding
              : padding.add(const EdgeInsets.only(top: CornerRibbon.height)),
          child: child,
        ),
        if (ribbon != null)
          Positioned(top: 0, right: 0, child: ribbon!),
      ],
    );
  }
}