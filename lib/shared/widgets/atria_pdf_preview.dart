import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../core/theme/app_radius.dart';
import '../../core/theme/app_shadows.dart';

/// A document preview block: the PDF rendered inline inside a neutral, rounded
/// frame, with its actions in the app's own button language.
///
/// `printing`'s [PdfPreview] draws its own action bar, and that bar is
/// full-bleed in `Theme.primaryColor` with the actions spread to the 25% and
/// 75% marks and no labels. Dropped inside a card that read as a stray violet
/// slab with two unlabelled icons floating far apart, with the grey viewer
/// background butting square against the card's rounded corners.
///
/// This widget turns the built-in bar off ([PdfPreview.useActions] false) and
/// renders the same actions as labelled buttons in a footer, so the preview
/// looks like part of the card rather than a foreign widget inside it.
class AtriaPdfPreview extends StatelessWidget {
  const AtriaPdfPreview({
    super.key,
    required this.builder,
    this.height = 420,
    this.onPrint,
    this.onShare,
  });

  /// Rasterised on demand by [PdfPreview] whenever the format changes.
  final LayoutCallback builder;

  /// Height of the page viewer; the footer adds its own height below it.
  final double height;

  /// Both are optional — the footer only shows the actions it is given, so a
  /// read-only preview can render bare.
  final VoidCallback? onPrint;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ColoredBox(
        color: scheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: height,
              child: PdfPreview(
                build: builder,
                maxPageWidth: 620,
                canChangeOrientation: false,
                canChangePageFormat: false,
                // The built-in action bar is replaced by the footer below.
                useActions: false,
                actions: const [],
                // Gap between the page and the frame, and between the pages.
                padding: const EdgeInsets.all(12),
                previewPageMargin: const EdgeInsets.all(6),
                scrollViewDecoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                ),
                pdfPreviewPageDecoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadius.xs),
                  boxShadow: AppShadows.card,
                ),
                loadingWidget: const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
            if (onPrint != null || onShare != null) _footer(context),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          children: [
            if (onPrint != null)
              TextButton.icon(
                onPressed: onPrint,
                icon: const Icon(Icons.print_outlined, size: 18),
                label: const Text('Print'),
              ),
            const Spacer(),
            if (onShare != null)
              FilledButton.tonalIcon(
                onPressed: onShare,
                icon: const Icon(Icons.share_outlined, size: 18),
                label: const Text('Share PDF'),
              ),
          ],
        ),
      ),
    );
  }
}
