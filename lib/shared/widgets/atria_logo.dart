import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Atria brand mark. Renders the bundled SVG on a transparent background,
/// or falls back to a painted gradient tile if the asset is unavailable.
class AtriaLogo extends StatelessWidget {
  const AtriaLogo({
    super.key,
    this.size = 40,
    this.borderRadius,
    this.showFallback = true,
  });

  final double size;
  final double? borderRadius;
  final bool showFallback;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? size * 0.28;
    return ClipRRect(
      borderRadius: BorderRadius.all(Radius.circular(radius)),
      child: SizedBox(
        width: size,
        height: size,
        child: SvgPicture.asset(
          'assets/logo/atria_logo.svg',
          fit: BoxFit.cover,
          placeholderBuilder: showFallback
              ? (context) => _FallbackTile(size: size)
              : null,
        ),
      ),
    );
  }
}

class _FallbackTile extends StatelessWidget {
  const _FallbackTile({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF60A5FA),
            Color(0xFF1D4ED8),
            Color(0xFF1E3A8A),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        'A',
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.52,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}

/// A wordmark: logo + "Atria" text.
class AtriaWordmark extends StatelessWidget {
  const AtriaWordmark({
    super.key,
    this.logoSize = 32,
    this.fontSize = 19,
    this.color,
    this.showTagline = false,
  });

  final double logoSize;
  final double fontSize;
  final Color? color;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AtriaLogo(size: logoSize),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Atria',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                    color: color ?? scheme.onSurface,
                    height: 1.1,
                  ),
            ),
            if (showTagline)
              Text(
                'Vyapar, simplified.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color ?? scheme.onSurfaceVariant,
                      letterSpacing: 0.1,
                    ),
              ),
          ],
        ),
      ],
    );
  }
}
