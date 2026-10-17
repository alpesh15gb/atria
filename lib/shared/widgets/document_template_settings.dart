import 'package:flutter/material.dart';

import '../../core/database/app_database.dart';
import '../../core/services/pdf_template_style.dart';
import 'mobile_template_picker.dart';

/// The same chooser and real PDF previews on desktop and mobile.
class DocumentTemplateSettings extends StatefulWidget {
  const DocumentTemplateSettings({
    super.key,
    required this.firm,
    required this.value,
    required this.onChanged,
  });
  final FirmEntity firm;
  final DocumentTemplates value;
  final ValueChanged<DocumentTemplates> onChanged;
  @override
  State<DocumentTemplateSettings> createState() =>
      _DocumentTemplateSettingsState();
}

class _DocumentTemplateSettingsState extends State<DocumentTemplateSettings> {
  String scope = 'default';
  @override
  Widget build(BuildContext context) {
    final override = widget.value.overrideFor(scope);
    final selected = scope == 'default'
        ? widget.value.defaultStyle
        : widget.value.forDocument(scope);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: scope,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Choose format for'),
            items: const [
              DropdownMenuItem(
                value: 'default',
                child: Text('Default for all documents'),
              ),
              DropdownMenuItem(value: 'invoice', child: Text('Invoices')),
              DropdownMenuItem(value: 'purchase', child: Text('Purchases')),
              DropdownMenuItem(value: 'quotation', child: Text('Quotations')),
            ],
            onChanged: (value) => setState(() => scope = value ?? 'default'),
          ),
          if (scope != 'default')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use shared default'),
              subtitle: Text(
                override == null
                    ? widget.value.defaultStyle.name
                    : 'This document has its own format',
              ),
              value: override == null,
              onChanged: (inherit) => widget.onChanged(
                widget.value.withChoice(scope, inherit ? null : selected.id),
              ),
            ),
          if (scope == 'default')
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'Applies wherever “Use shared default” is on. Save to apply your choices.',
              ),
            ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey('format-$scope-${selected.id}'),
            initialValue: PdfTemplateStyle.all.contains(selected)
                ? selected.id
                : 'classic',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Format'),
            items: [
              for (final style in PdfTemplateStyle.all)
                DropdownMenuItem(value: style.id, child: Text(style.name)),
            ],
            onChanged: (id) {
              if (id != null) {
                widget.onChanged(widget.value.withChoice(scope, id));
              }
            },
          ),
          Expanded(
            child: MobileTemplatePicker(
              key: ValueKey('$scope|${selected.id}'),
              firm: widget.firm,
              selected: selected,
              document: scope == 'purchase'
                  ? 1
                  : scope == 'quotation'
                  ? 2
                  : 0,
              onChanged: (style) =>
                  widget.onChanged(widget.value.withChoice(scope, style.id)),
            ),
          ),
        ],
      ),
    );
  }
}
