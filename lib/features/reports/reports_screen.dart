import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/domain/gst_registration.dart';
import '../../core/reports/catalogue/report_catalogue.dart';

import '../../core/reports/window/report_window.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../shared/widgets/atria_page_header.dart';
import '../../shared/widgets/common_widgets.dart';
import 'reports_overview.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  ReportWindow _range = ReportWindow.resolve(ReportWindowPreset.thisMonth);
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(reportRepositoryProvider);
    final isGstRegistered =
        ref.watch(activeFirmProvider).valueOrNull?.isGstRegistered == true;

    if (repo == null) {
      return const Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.storefront_outlined,
            title: 'No business open',
            message:
                'Set up a firm in Settings to generate GST, profit-and-loss and day-book reports.',
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AtriaPageHeader(
              title: 'Reports',
              subtitle: 'Financial reports, registers and statements',
            ),
            Material(
              color: scheme.surface,
              child: TabBar(
                controller: _tabController,
                onTap: (_) => setState(() {}),
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'All Reports'),
                ],
                indicatorSize: TabBarIndicatorSize.tab,
                labelStyle: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: theme.textTheme.titleSmall,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  ReportsOverview(
                    repo: repo,
                    range: _range,
                    onRangeChanged: (next) => setState(() => _range = next),
                  ),
                  _ReportsList(
                    searchQuery: _searchQuery,
                    onSearchChanged: (q) => setState(() => _searchQuery = q),
                    isGstRegistered: isGstRegistered,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportsList extends ConsumerWidget {
  const _ReportsList({
    required this.searchQuery,
    required this.onSearchChanged,
    required this.isGstRegistered,
  });

  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final bool isGstRegistered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = searchQuery.toLowerCase().trim();

    final all = ReportCatalogue.all;
    final filtered = q.isEmpty
        ? all
        : all.where((d) {
            final spec = d.spec;
            return spec.title.toLowerCase().contains(q) ||
                spec.category.toLowerCase().contains(q) ||
                spec.id.toLowerCase().contains(q);
          }).toList();

    final byCategory = <ReportCategory, List<ReportDefinition>>{};
    for (final def in filtered) {
      byCategory.putIfAbsent(def.category, () => []).add(def);
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: TextField(
              onChanged: onSearchChanged,
              decoration: InputDecoration(
                hintText: 'Search reports by name, category or ID',
                prefixIcon: const Icon(Icons.search_rounded),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide(color: scheme.outline),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  borderSide: BorderSide(color: scheme.outlineVariant),
                ),
                filled: true,
                fillColor: scheme.surfaceContainerLow,
              ),
            ),
          ),
        ),
        if (filtered.isEmpty)
          const SliverFillRemaining(
            child: Center(
              child: EmptyState(
                icon: Icons.search_off_rounded,
                title: 'No reports found',
                message: 'Try adjusting your search term.',
                compact: true,
              ),
            ),
          )
        else
          for (final entry in ReportCategory.values)
            if (byCategory.containsKey(entry) &&
                byCategory[entry]!.isNotEmpty)
              SliverToBoxAdapter(
                child: _CategorySection(
                  category: entry,
                  definitions: byCategory[entry]!,
                  isGstRegistered: isGstRegistered,
                ),
              ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.definitions,
    required this.isGstRegistered,
  });

  final ReportCategory category;
  final List<ReportDefinition> definitions;
  final bool isGstRegistered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
            child: Text(
              category.label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: definitions.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.4),
                indent: 16,
                endIndent: 16,
              ),
              itemBuilder: (context, i) {
                final def = definitions[i];
                final spec = def.spec;
                final isGst = spec.category == 'GST' || def.spec.id.startsWith('gstr');

                if (isGst && !isGstRegistered) {
                  return ListTile(
                    leading: Icon(
                      Icons.lock_outline_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    title: Text(spec.title),
                    subtitle: const Text('GST registration required'),
                    enabled: false,
                  );
                }

                return ListTile(
                  leading: Icon(
                    _iconForCategory(category),
                    color: scheme.primary,
                  ),
                  title: Text(spec.title),
                  subtitle: Text(
                    spec.footnote ?? '${spec.category} • ${spec.layout.name}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.go('/reports/${def.spec.id}'),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconForCategory(ReportCategory category) => switch (category) {
      ReportCategory.transaction => Icons.receipt_long_rounded,
      ReportCategory.party => Icons.people_outline_rounded,
      ReportCategory.gst => Icons.fact_check_outlined,
      ReportCategory.itemStock => Icons.inventory_2_outlined,
      ReportCategory.businessStatus => Icons.analytics_outlined,
      ReportCategory.taxes => Icons.percent_rounded,
      ReportCategory.expense => Icons.account_balance_wallet_outlined,
      ReportCategory.order => Icons.shopping_cart_outlined,
      ReportCategory.loan => Icons.account_balance_outlined,
    };
