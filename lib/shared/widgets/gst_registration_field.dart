import 'package:flutter/material.dart';

/// Both business setup and settings use the same registration choice.
class GstRegistrationField extends StatefulWidget {
  const GstRegistrationField({
    super.key,
    required this.controller,
    required this.gstinField,
    required this.onChanged,
  });
  final TextEditingController controller;
  final Widget gstinField;
  final VoidCallback onChanged;

  @override
  State<GstRegistrationField> createState() => _GstRegistrationFieldState();
}

class _GstRegistrationFieldState extends State<GstRegistrationField> {
  late bool registered = widget.controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<bool>(
        initialValue: registered,
        decoration: const InputDecoration(labelText: 'GST registration'),
        items: const [
          DropdownMenuItem(value: false, child: Text('Not GST registered')),
          DropdownMenuItem(value: true, child: Text('GST registered')),
        ],
        onChanged: (value) {
          setState(() => registered = value ?? false);
          if (!registered) widget.controller.clear();
          widget.onChanged();
        },
      ),
      const SizedBox(height: 12),
      if (registered)
        FormField<void>(
          validator: (_) => widget.controller.text.trim().isEmpty
              ? 'Enter the GSTIN for this registered business.'
              : null,
          builder: (state) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              widget.gstinField,
              if (state.hasError)
                Text(
                  state.errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        )
      else
        const Text(
          'Sales invoices will not charge GST. GST paid to suppliers '
          'is included in your costs, without input tax credit.',
        ),
    ],
  );
}
