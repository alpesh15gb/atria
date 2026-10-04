import 'package:flutter/material.dart';

import '../../core/domain/document_status.dart';
import '../../core/theme/app_theme.dart';

/// Small status pill used for payment / document states.
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.kind,
    this.icon,
    this.size = ChipSize.small,
  });

  final String label;
  final ChipKind kind;
  final IconData? icon;
  final ChipSize size;

  factory StatusChip.payment(String status) {
    switch (status) {
      case 'paid':
        return const StatusChip(label: 'Paid', kind: ChipKind.success);
      case 'partial':
        return const StatusChip(label: 'Partial', kind: ChipKind.warning);
      default:
        return const StatusChip(label: 'Unpaid', kind: ChipKind.neutral);
    }
  }

  /// The chip for a document lifecycle.
  ///
  /// Resolved through [DocumentStatus] rather than a switch of its own. This
  /// factory used to carry a second copy of the vocabulary, and it had already
  /// drifted from the sales list's private one — 'converted' fell through to
  /// grey here while the list showed a blue badge. One enum means a status
  /// cannot exist in one place and be missing in the other.
  factory StatusChip.doc(String status, {String docType = 'invoice'}) {
    final resolved = DocumentStatus.of(status, docType);
    return StatusChip(label: resolved.label, kind: resolved.kind);
  }

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final scheme = Theme.of(context).colorScheme;

    Color fg;
    Color bg;
    switch (kind) {
      case ChipKind.success:
        fg = colors.onSuccessSurface;
        bg = colors.successSurface;
        break;
      case ChipKind.warning:
        fg = colors.onWarningSurface;
        bg = colors.warningSurface;
        break;
      case ChipKind.danger:
        fg = colors.onDangerSurface;
        bg = colors.dangerSurface;
        break;
      case ChipKind.info:
        fg = scheme.primary;
        bg = scheme.primaryContainer;
        break;
      case ChipKind.neutral:
        fg = scheme.onSurfaceVariant;
        bg = scheme.surfaceContainerHighest;
        break;
    }

    final padding = size == ChipSize.small
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 3)
        : const EdgeInsets.symmetric(horizontal: 10, vertical: 5);
    // 10.5 was below comfortable legibility at desktop scaling.
    final double fontSize = size == ChipSize.small ? 11 : 11.5;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 3, color: fg),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              height: 1.2,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

enum ChipKind { success, warning, danger, info, neutral }

enum ChipSize { small, medium }
