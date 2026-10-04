import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';

import '../../core/reports/catalogue/report_catalogue.dart';
import '../../core/reports/engine/report_providers.dart';
import '../../core/reports/engine/report_result.dart';
import '../../core/reports/export/report_export_service.dart';
import '../../core/reports/export/report_pdf_builder.dart';
import '../../core/reports/spec/report_spec.dart';
import '../../core/services/csv_export.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../shared/widgets/atria_list_page.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/report_data_table.dart';
import '../../shared/widgets/report_filter_bar.dart';
import '../../shared/widgets/report_period_toolbar.dart';
import 'document_registry.dart';
import 'report_document_view.dart';

/// One screen for every report in the catalogue.
///
/// **The reason this file exists rather than 46 of them:** no report screen
/// today has an export affordance. Not one. Each report was written to be read
/// on screen and the numbers left with the reader — there is no CSV, no Excel,
/// no PDF and no print on any of them. One screen with an export button in
/// `actions` makes that true of all 46 by construction, rather than by
/// remembering to add one to each.
///
/// It is also why the export path is identical everywhere: CSV, Excel and PDF
/// come off the same [ReportResult] that the table rendered, so what is exported
/// is what was on screen, including the window and the subtotals.
class ReportViewPage extends ConsumerWidget {
  const ReportViewPage({super.key, required this.reportId});

  final String reportId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(reportWindowProvider);
    final filters = ref.watch(reportFiltersProvider(reportId));
    final query = ReportQuery(
      reportId: reportId,
      window: window,
      filters: filters,
    );
    final async = ref.watch(reportResultProvider(query));
    // The *declared* spec, not the one on the loaded result: the filter row must
    // be on screen from the first frame, or a report whose query takes a moment
    // pops its toolbar in and shifts the table down under the reader's thumb.
    final spec = ReportCatalogue.byId(reportId)?.spec;

    return AtriaListPage(
      title: async.valueOrNull?.spec.title ?? reportId,
      subtitle: window.spanLabel,
      // Unconditional. The single line that makes "every report has an export
      // affordance" true rather than aspirational.
      actions: [_ExportButton(query: query)],
      toolbar: [
        ReportPeriodToolbar(
          window: window,
          onChanged: (next) =>
              ref.read(reportWindowProvider.notifier).state = next,
        ),
        // The filter row, and only for a report that declares one — `hasFilters`
        // rather than a check on the filter list, because a bar that renders as
        // an empty strip is a strip the reader has to look at to learn nothing.
        if (spec?.hasFilters ?? false)
          ReportFilterBar(
            reportId: reportId,
            spec: spec!,
            filters: filters,
          ),
      ],
      body: SizedBox(
        // `AtriaListPage.body` needs a bounded height — see that class's doc.
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stack) => _ErrorPanel(
            message: '$error',
            onRetry: () => ref.invalidate(reportResultProvider(query)),
          ),
          data: (result) => _ReportBody(result: result),
        ),
      ),
    );
  }
}

class _ReportBody extends ConsumerWidget {
  const _ReportBody({required this.result});

  final ReportResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spec = result.spec;
    final integrity = ReportIntegrityChecks.assertIntegrity(result);

    if (result.isEmpty) {
      return EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'Nothing in this period',
        message:
            'No ${spec.title.toLowerCase()} rows between ${result.window.spanLabel}.',
        compact: true,
      );
    }

    final body = spec.layout == ReportLayout.document
        // A document report draws its own shape, but sits under this same
        // toolbar, integrity banner and export — which is the entire point of
        // separating the body from the screen.
        ? ReportDocumentView(
            result: result,
            builder: (context, r) =>
                documentBuilderFor(r.spec.id)?.call(context, r),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;
              return ReportDataTable(
                result: result,
                // The wide table gets every column; the narrow one drops the
                // `wideOnly` ones, because a phone row already says what it is
                // and eight columns of it is unreadable.
                columns: wide ? spec.columns : spec.narrowColumns,
              );
            },
          );

    return Column(
      children: [
        // The integrity banner, above the table rather than below it. A report
        // whose subtotals do not foot is worse than no report — the number looks
        // authoritative and it is wrong — so the reader has to see it before
        // they read the figure, not after.
        if (!integrity.isClean) _IntegrityBanner(integrity: integrity),
        if (result.notes.isNotEmpty) _NotesStrip(notes: result.notes),
        Expanded(child: body),
        if (spec.footnote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.sm,
              AppSpace.xs,
              AppSpace.sm,
              AppSpace.sm,
            ),
            child: Text(
              spec.footnote!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

/// The bespoke body for a document-layout report, by catalogue id.
///
/// Lives in `document_registry.dart` so the registry has no dependency on the
/// screen — a document file registers itself without importing this file, and
/// the screen does not have to know which of the forty-six reports have bespoke
/// bodies.
class _IntegrityBanner extends StatelessWidget {
  const _IntegrityBanner({required this.integrity});

  final ReportIntegrity integrity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        0,
      ),
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.errorSurface,
        border: Border.all(color: scheme.error, width: 0.8),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: scheme.error, size: 18),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This report does not foot — do not use these totals',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: scheme.error),
                ),
                const SizedBox(height: AppSpace.xxs),
                // Every problem, not just the first. Two wrong subtotals and
                // one shown would leave the reader fixing it, re-running, and
                // finding the next one.
                for (final problem in integrity.problems)
                  Text(
                    problem,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurface),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotesStrip extends StatelessWidget {
  const _NotesStrip({required this.notes});

  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        0,
      ),
      padding: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xxs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Expanded(
                    child: Text(
                      note,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.error_outline,
      title: 'Could not build this report',
      message: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

/// The export button, and the flow behind it.
///
/// Snackbar-with-the-path then `OpenFilex.open`, copied unchanged from
/// `statement_of_account_screen.dart:405-447`. Sharing the shape matters more
/// than it looks: the user has to be told where the file went *and* get it open,
/// and a report the user cannot find again is an export they will run twice.
class _ExportButton extends ConsumerWidget {
  const _ExportButton({required this.query});

  final ReportQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_ExportFormat>(
      icon: const Icon(Icons.ios_share),
      tooltip: 'Export',
      onSelected: (format) => _run(context, ref, format),
      itemBuilder: (context) => const [
        PopupMenuItem(value: _ExportFormat.csv, child: Text('Export as CSV')),
        PopupMenuItem(
          value: _ExportFormat.excel,
          child: Text('Export as Excel'),
        ),
        PopupMenuItem(value: _ExportFormat.pdf, child: Text('Export as PDF')),
        PopupMenuItem(value: _ExportFormat.print, child: Text('Print')),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _ExportFormat format,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final async = ref.read(reportResultProvider(query));

    // Nothing to export from a report that failed or has not loaded. Saying so
    // beats writing an empty file the user then opens and finds blank.
    final result = async.valueOrNull;
    if (result == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Wait for the report to load first.')),
      );
      return;
    }

    try {
      final dir = await exportRootDirectory();
      final file = switch (format) {
        _ExportFormat.csv => await const ReportExportService().writeCsv(
          result,
          dir,
        ),
        _ExportFormat.excel => await const ReportExportService().writeExcel(
          result,
          dir,
        ),
        _ExportFormat.pdf => await const ReportPdfBuilder().write(result, dir),
        // Print goes through the spool, not the filesystem — it has no file to
        // open afterwards, so the snackbar is the whole interaction.
        _ExportFormat.print => null,
      };

      if (format == _ExportFormat.print) {
        await const ReportPdfBuilder().print(result);
        return;
      }

      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${ReportExportService.describe(result)} saved to ${dir.path}',
          ),
        ),
      );
      // Only open when there is a file. `file` is null on the print path,
      // which has already returned by here.
      if (file != null) await OpenFilex.open(file.path);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not export: $e')));
    }
  }
}

enum _ExportFormat { csv, excel, pdf, print }
