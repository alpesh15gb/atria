// Measures what every screen actually renders — resolved text styles, icon
// sizes, radii, insets, chrome geometry and contrast — straight off the render
// tree, and writes a text report to build/visual/audit.txt.
//
// The point: "looks off" is usually inconsistency you can COUNT. Twelve
// font sizes where the design has four, nine icon sizes, right edges that
// differ by 2px from screen to screen. Those are measurable without eyes.
//
//   flutter test tool/visual_audit_test.dart
import 'dart:io';
import 'dart:math' as math;

import 'package:atria/app.dart';
import 'package:atria/core/database/app_database.dart';
import 'package:atria/core/database/repositories/repository_extensions.dart';
import 'package:atria/core/router/app_router.dart';
import 'package:atria/core/services/demo_seeder.dart';
import 'package:atria/core/state/providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart' as gr;
import 'package:atria/shared/widgets/atria_form_section.dart';
import 'package:atria/shared/widgets/atria_line_grid.dart';
import 'package:atria/shared/widgets/atria_page_header.dart';
import 'package:atria/shared/widgets/atria_list_toolbar.dart';
import 'package:atria/shared/widgets/atria_top_bar.dart';
import 'package:atria/shared/widgets/editor_totals.dart';

const Size kDesktop = Size(1440, 900);
const Size kPhone = Size(412, 892);

/// A maximised desktop window — where a centred form strands its margins.
const Size kWide = Size(1680, 950);

/// Between phone and desktop: the sheet has to fall back to stacked cards.
const Size kTablet = Size(900, 900);

AppDatabase? _db;
ProviderContainer? _container;
late gr.GoRouter router;
late String firmId;
late String invoiceId;
late String billId;
late String itemId;
late String customerId;
late String expenseId;

final _report = StringBuffer();

// ---------------------------------------------------------------- collection

class Para {
  Para(this.text, this.style, this.rect, this.owner, this.bg);

  final String text;
  final TextStyle style;
  final Rect rect;
  final String owner;
  final Color bg;

  bool get isIcon => (style.fontFamily ?? 'Inter') != 'Inter';

  /// The glyph's code point(s), so an off-scale icon can be traced back to a
  /// named constant (`0xe1a1` → `Icons.swipe_right_rounded`) instead of
  /// hunted down by guessing which widget sits at a given coordinate.
  String get codePoint => text.runes
      .map((r) => 'U+${r.toRadixString(16).toUpperCase()}')
      .join(' ');
}

class Census<T> {
  final Map<T, int> counts = {};
  final Map<T, List<String>> samples = {};

  void add(T key, String sample) {
    counts[key] = (counts[key] ?? 0) + 1;
    final list = samples[key] ??= [];
    if (list.length < 4) list.add(sample);
  }
}

/// Walks the element tree once, collecting paragraphs (text and icons),
/// resolved styles, geometry and the widget that owns each one.
class TreeWalk {
  TreeWalk(this.root);

  final Element root;
  final paragraphs = <Para>[];

  final radii = Census<double>();
  final pads = Census<EdgeInsetsGeometry>();
  final gaps = Census<double>();
  final boxWidths = Census<double>();
  final owners = Census<String>();

  /// Text/label widget types that decide the look of a row or a field, plus
  /// the values that should be shared across screens.
  final controlLineHeights = Census<String>();
  final decorationValues = Census<String>();

  /// Counted so the report can prove the invisibility filter is still
  /// working: if a Flutter upgrade renames the private scope that
  /// [IndexedStack] uses to hide its inactive branches, this drops to zero and
  /// every screen silently starts reporting the dashboard's widgets as its
  /// own. It did exactly that before this filter existed.
  int hiddenBranches = 0;

  void run() => _visit(root, const Color(0xFFFFFFFF));

  void _visit(Element element, Color inheritedBg) {
    final widget = element.widget;
    var bg = inheritedBg;

    // `StatefulShellRoute.indexedStack` keeps every visited branch alive, and
    // those subtrees are laid out at the *same* origin as the active one, so
    // their text was landing in each screen's census at identical coordinates.
    // Skip anything the framework has marked invisible instead of measuring
    // it.
    if (widget is Offstage && widget.offstage) return;
    if (widget is Visibility && !widget.visible) return;
    if (_isHiddenByIndexedStack(widget)) {
      hiddenBranches++;
      return;
    }

    // A translucent fill must be COMPOSITED over what is behind it, not
    // treated as the background: a 14%-alpha brand tint reported as "#2ca01c on
    // #2ca01c24" produces a phantom 1:1 contrast failure on every tinted
    // avatar and chip in the app.
    void tint(Color color) {
      bg = color.a >= 0.999 ? color : Color.alphaBlend(color, bg);
    }

    void collectDecoration(BoxDecoration d) {
      final r = d.borderRadius;
      if (r is BorderRadius) {
        for (final radius in [
          r.topLeft,
          r.topRight,
          r.bottomLeft,
          r.bottomRight,
        ]) {
          radii.add(radius.x, '$element');
        }
      }
      if (d.color != null && d.color!.a > 0.01) tint(d.color!);
    }

    if (widget is Container) {
      final d = widget.decoration;
      if (d is BoxDecoration) collectDecoration(d);
      if (widget.color != null && widget.color!.a > 0.01) tint(widget.color!);
      if (widget.padding != null) {
        pads.add(widget.padding!, 'Container.padding');
      }
      if (widget.margin != null) {
        pads.add(widget.margin!, 'Container.margin');
      }
    }
    if (widget is DecoratedBox) {
      final d = widget.decoration;
      if (d is BoxDecoration) collectDecoration(d);
    }
    if (widget is ColoredBox && widget.color.a > 0.01) tint(widget.color);
    if (widget is Material && widget.color != null && widget.color!.a > 0.01) {
      tint(widget.color!);
      if (widget.borderRadius is BorderRadius) {
        radii.add((widget.borderRadius as BorderRadius).topLeft.x, 'Material');
      }
    }
    if (widget is InkWell && widget.borderRadius is BorderRadius) {
      radii.add((widget.borderRadius as BorderRadius).topLeft.x, 'InkWell');
    }
    if (widget is Card) radii.add(12, 'Card');
    if (widget is Padding) pads.add(widget.padding, 'Padding');
    if (widget is Row) gaps.add(widget.spacing, 'Row.spacing');
    if (widget is Column) gaps.add(widget.spacing, 'Column.spacing');
    if (widget is SizedBox) {
      if (widget.width != null) boxWidths.add(widget.width!, 'SizedBox.w');
      if (widget.height != null) boxWidths.add(widget.height!, 'SizedBox.h');
    }

    final renderObject = element.renderObject;
    if (renderObject is RenderParagraph && renderObject.hasSize) {
      // hasSize matters: an unlaid-out paragraph (one inside a menu or an
      // overlay that is mid-animation) asserts when `.size` is read, and
      // reading it from the tree walk crashed the audit on the screens that
      // own a dropdown.
      final box = renderObject;
      paragraphs.add(
        Para(
          box.text.toPlainText(),
          box.text.style ?? const TextStyle(),
          box.localToGlobal(Offset.zero) & box.size,
          _ownerOf(element),
          bg,
        ),
      );
    }

    element.visitChildren((child) => _visit(child, bg));
  }

  /// [IndexedStack] hides its inactive children with a private
  /// `_VisibilityScope` inherited widget rather than [Offstage] or
  /// [Visibility], so it has to be detected by name.
  static bool _isHiddenByIndexedStack(Widget widget) {
    if (widget.runtimeType.toString() != '_VisibilityScope') return false;
    try {
      return (widget as dynamic).isVisible == false;
    } on NoSuchMethodError {
      return false;
    }
  }

  /// The nearest ancestor widget whose type is not a framework primitive —
  /// i.e. the app-level widget that put this thing on screen.
  static String _ownerOf(Element element) {
    var name = element.widget.runtimeType.toString();
    element.visitAncestorElements((el) {
      final candidate = el.widget.runtimeType.toString();
      final generic =
          candidate.startsWith('_') ||
          candidate.contains('Render') ||
          candidate == 'AnimatedDefaultTextStyle' ||
          candidate == 'DefaultTextStyle' ||
          candidate == 'Semantics' ||
          candidate == 'Builder' ||
          candidate == 'RepaintBoundary';
      if (!generic) {
        name = candidate;
        return false;
      }
      return true;
    });
    return name;
  }
}

String hex(Color c) =>
    '#${(c.r * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.g * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.b * 255).round().toRadixString(16).padLeft(2, '0')}'
    '${(c.a * 255).round().toRadixString(16).padLeft(2, '0')}';

String rectText(Rect r) =>
    '${r.left.round()},${r.top.round()} ${r.width.round()}x${r.height.round()}';

double luminance(Color c) {
  double channel(double v) {
    v = v / 255;
    return v <= 0.03928
        ? v / 12.92
        : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.r * 255) +
      0.7152 * channel(c.g * 255) +
      0.0722 * channel(c.b * 255);
}

double contrast(Color a, Color b) {
  final la = luminance(a);
  final lb = luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Future<void> loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  var any = false;
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) continue;
    any = true;
    final bytes = file.readAsBytesSync();
    loader.addFont(
      Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
    );
  }
  if (any) await loader.load();
}

Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadFont('Inter', ['assets/fonts/Inter[opsz,wght].ttf']);
    for (final root in ['C:/flutter', 'C:/src/flutter']) {
      final p =
          '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf';
      if (File(p).existsSync()) {
        await loadFont('MaterialIcons', [p]);
        break;
      }
    }
    const phosphor = 'third_party/phosphor_flutter/lib/fonts';
    await loadFont('PhosphorRegular', ['$phosphor/Phosphor.ttf']);
    await loadFont('PhosphorFill', ['$phosphor/Phosphor-Fill.ttf']);
    await loadFont('PhosphorBold', ['$phosphor/Phosphor-Bold.ttf']);

    final db = AppDatabase.test(NativeDatabase.memory());
    await DemoSeeder(db).seedIfNeeded();
    _db = db;

    firmId = (await db.firmRepository.all()).first.id;
    invoiceId = (await db.salesRepositoryFor(firmId).list()).first.id;
    billId = (await db.purchaseRepositoryFor(firmId).list()).first.id;
    itemId = (await db.itemRepositoryFor(firmId).all(limit: 50))
        .firstWhere((i) => !i.isService)
        .id;
    customerId = (await db.partyRepositoryFor(firmId).all(type: 'customer'))
        .first
        .id;
    expenseId = (await db.expenseRepositoryFor(firmId).list()).first.id;
  });

  tearDownAll(() async {
    File('build/visual/audit.txt').writeAsStringSync(_report.toString());
    await _db?.close().timeout(const Duration(seconds: 20), onTimeout: () {});
  });

  setUp(() async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(_db!)],
    );
    _container = container;
    // Initialization loads the *persisted* onboarding flag and active firm and
    // pushes them into these controllers, so setting them before it resolves
    // gets overwritten — which is why the very first case in this file (the
    // desktop dashboard) silently spent its whole run on `/onboarding` and the
    // real dashboard was never measured at 1440px at all.
    await container.read(appInitializationProvider.future);
    await container.read(onboardingDoneProvider.notifier).complete();
    await container.read(activeFirmIdProvider.notifier).select(firmId);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (call) async => call.method == 'getAll'
              ? <String, dynamic>{
                  'appName': 'Atria',
                  'packageName': 'com.example.atria',
                  'version': '1.0.0',
                  'buildNumber': '1',
                  'installerStore': null,
                }
              : null,
        );
  });

  tearDown(() async {
    _container?.dispose();
    _container = null;
  });

  Future<void> audit(
    WidgetTester tester,
    String name,
    String route, {
    Size size = kDesktop,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container!,
        child: const AtriaApp(),
      ),
    );
    await pumpFrames(tester);
    router = _container!.read(appRouterProvider);
    router.go(route);
    await pumpFrames(tester, frames: 12);

    final walk = TreeWalk(tester.binding.rootElement!);
    walk.run();

    final textStyles = Census<String>();
    final iconStyles = Census<String>();
    final textColors = Census<String>();
    final contrastIssues = <String>[];

    for (final p in walk.paragraphs) {
      final family = p.style.fontFamily ?? 'Inter';
      final size = p.style.fontSize;
      final weight = p.style.fontWeight?.value ?? 400;
      final key = '${size?.toStringAsFixed(1) ?? '?'}px w$weight $family';
      if (p.isIcon) {
        iconStyles.add(key, '${rectText(p.rect)} ${p.codePoint} ${p.owner}');
      } else {
        textStyles.add(key, '${rectText(p.rect)} "${p.text}" <${p.owner}>');
      }

      final fg = p.style.color;
      if (!p.isIcon && fg != null && p.text.trim().isNotEmpty) {
        textColors.add(hex(fg), '${rectText(p.rect)} "${p.text}" <${p.owner}>');
        final effective = fg.a < 0.999 ? Color.alphaBlend(fg, p.bg) : fg;
        final ratio = contrast(effective, p.bg);
        // WCAG's "large text" is 24px, or 18.66px when bold. A 14px bold
        // label is NOT large text, and treating it as such would have hidden
        // the white-on-brand-green failure on every primary button.
        final large =
            (size ?? 13) >= 24 || ((size ?? 13) >= 18.66 && weight >= 700);
        final floor = large ? 3.0 : 4.5;
        if (ratio < floor) {
          contrastIssues.add(
            '   ${ratio.toStringAsFixed(2)}:1 (need $floor)  '
            '${hex(effective)} on ${hex(p.bg)}  ${rectText(p.rect)} '
            '"${p.text}" <${p.owner}>',
          );
        }
      }
    }

    // The route the router actually settled on, which is not always the one we
    // asked for: a redirect can swap the screen under us, and the report would
    // then describe a different screen under this screen's name. That happened
    // to `/dashboard`, which silently measured the onboarding welcome pages
    // until this line was added.
    final landed = router.routerDelegate.currentConfiguration.uri.path;

    _report.writeln('');
    _report.writeln('=' * 110);
    _report.writeln(
      '## $name   ($route)   ${size.width.toInt()}x${size.height.toInt()}',
    );
    _report.writeln('=' * 110);
    _report.writeln('landed on: $landed${landed == route ? '' : '  <-- REDIRECTED'}');
    _report.writeln('inactive shell branches skipped: ${walk.hiddenBranches}');

    void dump<T>(String title, Census<T> census, {int limit = 30}) {
      if (census.counts.isEmpty) return;
      final entries = census.counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      _report.writeln('-- $title  (${entries.length} distinct)');
      for (final e in entries.take(limit)) {
        _report.writeln('  ${e.value.toString().padLeft(4)}x  ${e.key}');
        for (final s in (census.samples[e.key] ?? const [])) {
          _report.writeln('          $s');
        }
      }
    }

    if (contrastIssues.isNotEmpty) {
      _report.writeln('-- CONTRAST BELOW AA  (${contrastIssues.length})');
      for (final i in contrastIssues.take(20)) {
        _report.writeln(i);
      }
    }

    // The display limits must stay above the number of distinct values these
    // censuses actually hold, or a truncated section reads as "exactly 20
    // distinct everywhere" and the per-screen scoreboard stops discriminating.
    dump('TEXT STYLES', textStyles, limit: 90);
    dump('ICON STYLES', iconStyles, limit: 60);
    dump('TEXT COLOURS', textColors, limit: 60);
    dump('RADII', walk.radii, limit: 40);
    dump('PADDINGS', walk.pads, limit: 120);
    dump('GAPS (Row/Column.spacing)', walk.gaps, limit: 30);
    dump('SIZEDBOX SIZES', walk.boxWidths, limit: 120);

    _report.writeln('-- CHROME GEOMETRY');
    void box<T extends Widget>(String label) {
      final finder = find.byType(T);
      if (finder.evaluate().isEmpty) {
        _report.writeln('  $label: ABSENT');
        return;
      }
      for (final el in finder.evaluate().take(2)) {
        final ro = el.renderObject;
        if (ro is! RenderBox || !ro.hasSize) continue;
        _report.writeln(
          '  $label: '
          '${rectText(ro.localToGlobal(Offset.zero) & ro.size)}',
        );
      }
    }

    box<AtriaTopBar>('topbar');
    box<AtriaPageHeader>('page-header');
    box<AtriaPrimaryAction>('primary-action');
    box<AtriaResultsBar>('results-bar');
    box<AtriaFilterBar>('filter-bar');
    box<AtriaLineGrid>('line-grid');
    box<AtriaTotalsBlock>('totals-block');
    box<AtriaEditorForm>('editor-form');

    await tester.pumpWidget(const SizedBox.shrink());
    await pumpFrames(tester, frames: 2);
  }

  final t = Timeout(Duration(minutes: 3));

  testWidgets(
    'dashboard',
    (w) => audit(w, 'dashboard', '/dashboard'),
    timeout: t,
  );
  testWidgets('sales', (w) => audit(w, 'sales', '/sales'), timeout: t);
  testWidgets('purchase', (w) => audit(w, 'purchase', '/purchase'), timeout: t);
  testWidgets('items', (w) => audit(w, 'items', '/items'), timeout: t);
  testWidgets('parties', (w) => audit(w, 'parties', '/parties'), timeout: t);
  testWidgets('payments', (w) => audit(w, 'payments', '/payments'), timeout: t);
  testWidgets('expenses', (w) => audit(w, 'expenses', '/expenses'), timeout: t);
  testWidgets('stock', (w) => audit(w, 'stock', '/stock'), timeout: t);
  testWidgets('reports', (w) => audit(w, 'reports', '/reports'), timeout: t);
  testWidgets(
    'gst-reports',
    (w) => audit(w, 'gst', '/gst-reports'),
    timeout: t,
  );
  testWidgets('settings', (w) => audit(w, 'settings', '/settings'), timeout: t);
  testWidgets(
    'settings-firm',
    (w) => audit(w, 'settings_firm', '/settings/firm'),
    timeout: t,
  );
  testWidgets(
    'sale-new',
    (w) => audit(w, 'sale_new', '/sales/new'),
    timeout: t,
  );
  testWidgets(
    'sale-edit',
    (w) => audit(w, 'sale_edit', '/sales/edit/$invoiceId'),
    timeout: t,
  );
  testWidgets(
    'sale-detail',
    (w) => audit(w, 'sale_detail', '/sales/detail/$invoiceId'),
    timeout: t,
  );
  testWidgets(
    'purchase-new',
    (w) => audit(w, 'purchase_new', '/purchase/new'),
    timeout: t,
  );
  testWidgets(
    'purchase-edit',
    (w) => audit(w, 'purchase_edit', '/purchase/edit/$billId'),
    timeout: t,
  );
  testWidgets(
    'item-new',
    (w) => audit(w, 'item_new', '/items/new'),
    timeout: t,
  );
  testWidgets(
    'party-new',
    (w) => audit(w, 'party_new', '/parties/new'),
    timeout: t,
  );
  testWidgets(
    'expense-new',
    (w) => audit(w, 'expense_new', '/expenses/new'),
    timeout: t,
  );
  testWidgets(
    'expense-edit',
    (w) => audit(w, 'expense_edit', '/expenses/edit/$expenseId'),
    timeout: t,
  );
  testWidgets(
    'wide-sale-edit',
    (w) => audit(w, 'wide_sale_edit', '/sales/edit/$invoiceId', size: kWide),
    timeout: t,
  );
  testWidgets(
    'wide-purchase-edit',
    (w) =>
        audit(w, 'wide_purchase_edit', '/purchase/edit/$billId', size: kWide),
    timeout: t,
  );
  testWidgets(
    'wide-item-new',
    (w) => audit(w, 'wide_item_new', '/items/new', size: kWide),
    timeout: t,
  );
  testWidgets(
    'wide-party-new',
    (w) => audit(w, 'wide_party_new', '/parties/new', size: kWide),
    timeout: t,
  );
  testWidgets(
    'wide-expense-new',
    (w) => audit(w, 'wide_expense_new', '/expenses/new', size: kWide),
    timeout: t,
  );
  testWidgets(
    'tablet-sale-new',
    (w) => audit(w, 'tablet_sale_new', '/sales/new', size: kTablet),
    timeout: t,
  );
  testWidgets(
    'phone-sale-edit',
    (w) => audit(w, 'phone_sale_edit', '/sales/edit/$invoiceId', size: kPhone),
    timeout: t,
  );
  testWidgets(
    'phone-item-new',
    (w) => audit(w, 'phone_item_new', '/items/new', size: kPhone),
    timeout: t,
  );
  testWidgets(
    'phone-party-new',
    (w) => audit(w, 'phone_party_new', '/parties/new', size: kPhone),
    timeout: t,
  );
  testWidgets(
    'phone-sale-new',
    (w) => audit(w, 'phone_sale_new', '/sales/new', size: kPhone),
    timeout: t,
  );
  testWidgets(
    'phone-dashboard',
    (w) => audit(w, 'phone_dashboard', '/dashboard', size: kPhone),
    timeout: t,
  );
}
