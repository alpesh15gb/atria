import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/indian_states.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/atria_form_section.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../core/theme/app_sizes.dart';

class PartyEditorScreen extends ConsumerStatefulWidget {
  const PartyEditorScreen({super.key, this.editId, this.initialType});

  final String? editId;

  /// Preselects the party type. Suppliers are created from the purchase
  /// editor, customers from the sale editor; without this both landed on
  /// "Customer".
  final String? initialType;

  @override
  ConsumerState<PartyEditorScreen> createState() => _PartyEditorScreenState();
}

class _PartyEditorScreenState extends ConsumerState<PartyEditorScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _gstinController;
  late final TextEditingController _panController;
  late final TextEditingController _contactController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _address1Controller;
  late final TextEditingController _address2Controller;
  late final TextEditingController _cityController;
  late final TextEditingController _pincodeController;
  late final TextEditingController _openingController;
  late final TextEditingController _creditLimitController;
  late final TextEditingController _creditDaysController;
  late final TextEditingController _notesController;

  bool _loading = false;
  bool _saving = false;
  Object? _loadError;

  bool _dirty = false;
  void _markDirty() => _dirty = true;

  String _type = 'customer';
  String _gstType = 'unregistered';
  String _openingBalanceType = 'dr';
  String? _stateCode;

  static const Map<String, String> _gstTypes = {
    'registered': 'Registered (Regular)',
    'unregistered': 'Unregistered Business',
    'consumer': 'Consumer (B2C)',
    'composition': 'Composition Scheme',
    'overseas': 'Overseas / Export',
    'sez': 'SEZ / EOU',
  };

  static const Map<String, String> _typeLabels = {
    'customer': 'Customer',
    'supplier': 'Supplier',
    'both': 'Both',
  };

  @override
  void initState() {
    super.initState();
    final preset = widget.initialType;
    if (preset != null && _typeLabels.containsKey(preset)) {
      _type = preset;
    }
    _nameController = TextEditingController();
    _gstinController = TextEditingController();
    _panController = TextEditingController();
    _contactController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
    _address1Controller = TextEditingController();
    _address2Controller = TextEditingController();
    _cityController = TextEditingController();
    _pincodeController = TextEditingController();
    _openingController = TextEditingController(text: '0.00');
    _creditLimitController = TextEditingController();
    _creditDaysController = TextEditingController();
    _notesController = TextEditingController();

    // TextController listeners only fire on user input, so prefilling an
    // existing row above does not mark the form dirty — but a keystroke does.
    for (final controller in [
      _nameController,
      _gstinController,
      _panController,
      _contactController,
      _phoneController,
      _emailController,
      _address1Controller,
      _address2Controller,
      _cityController,
      _pincodeController,
      _openingController,
      _creditLimitController,
      _creditDaysController,
      _notesController,
    ]) {
      controller.addListener(_markDirty);
    }

    if (widget.editId != null) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadParty());
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _gstinController,
      _panController,
      _contactController,
      _phoneController,
      _emailController,
      _address1Controller,
      _address2Controller,
      _cityController,
      _pincodeController,
      _openingController,
      _creditLimitController,
      _creditDaysController,
      _notesController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadParty() async {
    final repository = ref.read(partyRepositoryProvider);
    try {
      final party = await repository?.getById(widget.editId!);
      // A binned party must not open for editing; saving it would flip it
      // live again while no list shows it.
      if (party != null && party.isDeleted) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = 'This party is in the recycle bin and can no longer '
                'be edited.';
          });
        }
        return;
      }
      if (party == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = 'This party no longer exists.';
          });
        }
        return;
      }
      _nameController.text = party.name;
      _gstinController.text = party.gstin ?? '';
      _panController.text = party.pan ?? '';
      _contactController.text = party.contactPerson ?? '';
      _phoneController.text = party.phone ?? '';
      _emailController.text = party.email ?? '';
      _address1Controller.text = party.addressLine1 ?? '';
      _address2Controller.text = party.addressLine2 ?? '';
      _cityController.text = party.city ?? '';
      _pincodeController.text = party.pincode ?? '';
      _openingController.text = party.openingBalance.toStringAsFixed(2);
      _creditLimitController.text = party.creditLimit?.toStringAsFixed(2) ?? '';
      _creditDaysController.text = party.creditDays?.toString() ?? '';
      _notesController.text = party.notes ?? '';
      setState(() {
        _type = party.type;
        _gstType = party.gstType;
        _openingBalanceType = party.openingBalanceType;
        _stateCode = party.stateCode;
        _loading = false;
      });
      // The initState listeners fired on every prefill `text =` assignment
      // above. Nothing is interactive until now, so clearing the flag here
      // cannot lose user input — and opening a party for editing no longer
      // starts out "dirty" (back then asked to discard changes nobody made).
      _dirty = false;
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = error;
        });
      }
    }
  }

  bool get _showGstin => _gstType != 'unregistered' && _gstType != 'consumer';

  /// A registered, composition or SEZ party carries a GSTIN by law; overseas
  /// parties often don't file one in India. Without this the form happily
  /// saved a "Registered" party with an empty GSTIN, which then silently
  /// produced a non-GST invoice.
  bool get _gstinRequired =>
      _gstType == 'registered' ||
      _gstType == 'composition' ||
      _gstType == 'sez';

  /// The selected state is 97 — "Other Territory".
  ///
  /// 97 is a real, issued GSTIN state code: it is in the state dropdown, and a
  /// business registered there files a 97 GSTIN exactly like any other. It used
  /// to be unselectable in practice — `Validators._gstinRegex` admitted only
  /// 00-38, so picking 97 turned every GSTIN into a permanent error the person
  /// could not resolve no matter what they typed. The regex now admits 97 and
  /// `Validators.gstinStateMismatch` already compares the first two digits
  /// against the selected state, which is the right test for 97, so this form
  /// validates a 97 GSTIN like any other.
  bool get _isOtherTerritory => _stateCode == '97';

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_saving) return; // double-submit guard.

    final messenger = ScaffoldMessenger.maybeOf(context);
    final repository = ref.read(partyRepositoryProvider);

    // With no firm open there is no repository, so `create` returned null,
    // `savedId` stayed null and `context.pop(null)` closed the form as though it
    // had saved — no error, no snackbar, the entry simply gone. This form
    // renders in full with no firm (the global Create ▸ Customer menu reaches
    // it unconditionally), so the dead end is reachable, not theoretical. Same
    // wording and same behaviour as the expense editor.
    if (repository == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Open a firm before saving a party.')),
      );
      return;
    }

    setState(() => _saving = true);

    final name = _nameController.text.trim();
    final gstin = _gstinController.text.trim().toUpperCase();
    final pan = _panController.text.trim().toUpperCase();
    final contactPerson = _contactController.text.trim();
    final phone = _phoneController.text.trim();
    final email = _emailController.text.trim();
    final address1 = _address1Controller.text.trim();
    final address2 = _address2Controller.text.trim();
    final city = _cityController.text.trim();
    final pincode = _pincodeController.text.trim();
    final openingBalance =
        double.tryParse(_openingController.text.replaceAll(',', '')) ?? 0;
    final creditLimit = double.tryParse(
      _creditLimitController.text.replaceAll(',', '').trim(),
    );
    final creditDays = int.tryParse(_creditDaysController.text.trim());
    final notes = _notesController.text.trim();

    // GSTIN uniqueness, app-side: the same GSTIN on two parties silently
    // misroutes every e-invoice and every GSTR-1 bifurcation, and a party
    // auto-match keyed on the number would attach the bill to the wrong row.
    // Blank GSTINs (unregistered/consumer) are exempt.
    if (gstin.isNotEmpty) {
      final db = ref.read(appDatabaseProvider);
      final clash = await (db.select(db.parties)
            ..where((t) =>
                t.firmId.equals(repository.firmId) &
                t.gstin.equals(gstin) &
                t.isDeleted.equals(false)))
          .get();
      final other = clash.where((p) => p.id != (widget.editId ?? '')).toList();
      if (other.isNotEmpty) {
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              'GSTIN $gstin is already used by "${other.first.name}".',
            ),
          ),
        );
        setState(() => _saving = false);
        return;
      }
    }

    try {
      String? savedId;
      if (widget.editId == null) {
        final created = await repository.create(
          name: name,
          type: _type,
          gstin: gstin.isEmpty ? null : gstin,
          pan: pan.isEmpty ? null : pan,
          gstType: _gstType,
          contactPerson: contactPerson.isEmpty ? null : contactPerson,
          phone: phone.isEmpty ? null : phone,
          email: email.isEmpty ? null : email,
          addressLine1: address1.isEmpty ? null : address1,
          addressLine2: address2.isEmpty ? null : address2,
          city: city.isEmpty ? null : city,
          stateCode: _stateCode,
          pincode: pincode.isEmpty ? null : pincode,
          openingBalance: openingBalance,
          openingBalanceType: _openingBalanceType,
          creditLimit: creditLimit,
          creditDays: creditDays,
          notes: notes.isEmpty ? null : notes,
        );
        savedId = created.id;
      } else {
        final existing = await repository.getById(widget.editId!);
        if (existing == null) {
          messenger?.showSnackBar(
            const SnackBar(content: Text('This party no longer exists.')),
          );
          return;
        }
        await repository.update(
          existing.copyWith(
            name: name,
            type: _type,
            gstin: Value(gstin.isEmpty ? null : gstin),
            pan: Value(pan.isEmpty ? null : pan),
            gstType: _gstType,
            contactPerson: Value(contactPerson.isEmpty ? null : contactPerson),
            phone: Value(phone.isEmpty ? null : phone),
            email: Value(email.isEmpty ? null : email),
            addressLine1: Value(address1.isEmpty ? null : address1),
            addressLine2: Value(address2.isEmpty ? null : address2),
            city: Value(city.isEmpty ? null : city),
            stateCode: Value(_stateCode),
            pincode: Value(pincode.isEmpty ? null : pincode),
            openingBalance: openingBalance,
            openingBalanceType: _openingBalanceType,
            creditLimit: Value(creditLimit),
            creditDays: Value(creditDays),
            notes: Value(notes.isEmpty ? null : notes),
          ),
        );
      }
      if (mounted) {
        // A successful save pops this screen itself; the guard would otherwise
        // read the still-set dirty flag and ask whether to discard the very
        // thing that was just saved.
        _dirty = false;
        // Return the id so a caller that spawned this editor from its own
        // picker (the purchase/sale editors) can select the new party.
        context.pop(savedId ?? widget.editId);
      }
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Failed to save: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = atriaColors(context);
    final text = Theme.of(context).textTheme;

    return SaveShortcut(
      enabled: !_saving,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _dirty && !_saving,
        child: Scaffold(
          appBar: EditorAppBar(
            title: widget.editId == null ? 'Add Party' : 'Edit Party',
            saving: _saving || _loading,
            onSave: _save,
            onExit: () => context.pop(),
          ),
          // On a phone the app bar hands Save down here, where a thumb is.
          bottomNavigationBar: EditorBottomBar(
            onSave: _save,
            saving: _saving || _loading,
          ),
          // Full-bleed, like every other editor, and *through the same widget*:
          // this page used to re-implement the scroll view, the gutter and the
          // section columns itself, so on a 1680px window it kept a 24px gutter
          // where the invoice, item and expense editors stepped up to 32, and a
          // 16px section gap where they used 12.
          body: SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                    ? _errorState(colors, text)
                    : Form(
                        key: _formKey,
                        child: AtriaEditorForm(
                          maxContentWidth: 1000,
                          sections: [
                            _basicSection(colors, text),
                            _contactSection(colors, text),
                            _addressSection(colors, text),
                            _creditSection(colors, text),
                          ],
                        ),
                      ),
          ),
        ),
      ),
    );
  }

  Widget _errorState(AtriaColorsExtension colors, TextTheme text) {
    return EmptyState(
      icon: Icons.error_outline_rounded,
      title: 'Could not load party',
      message: '$_loadError',
      actionLabel: 'Go back',
      onAction: () => context.pop(),
    );
  }

  Widget _basicSection(AtriaColorsExtension colors, TextTheme text) {
    return AtriaFormSection(
      icon: Icons.badge_outlined,
      title: 'Basic details',
      children: [
        TextFormField(
          controller: _nameController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          validator: Validators.name,
          decoration: const InputDecoration(
            labelText: 'Party name *',
            hintText: 'e.g. Shree Trading Co.',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Type',
          style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        _segmentedControl<String>(
          value: _type,
          values: _typeLabels.keys.toList(),
          labels: _typeLabels,
          onChanged: (value) => setState(() {
            _type = value;
            _dirty = true;
          }),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          iconSize: AppIconSize.md,
          initialValue: _gstType,
          // isExpanded: a DropdownButton sizes to its WIDEST item, so an
          // unexpanded one overflows the field on a phone.
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'GST type'),
          items: [
            for (final entry in _gstTypes.entries)
              DropdownMenuItem<String>(
                value: entry.key,
                child: Text(
                  entry.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _gstType = value;
              _dirty = true;
              if (!_showGstin) {
                _gstinController.clear();
              }
            });
          },
        ),
        const SizedBox(height: 16),
        if (_showGstin) ...[
          TextFormField(
            controller: _gstinController,
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              UpperCaseInputFormatter(),
              LengthLimitingTextInputFormatter(15),
            ],
            validator: (value) {
              final error = Validators.gstin(value, required: _gstinRequired);
              if (error != null) return error;
              // 97 is checked like any other state: the first two digits must
              // be 97. See [_isOtherTerritory].
              return Validators.gstinStateMismatch(value, _stateCode);
            },
            decoration: InputDecoration(
              labelText: 'GSTIN',
              hintText: _isOtherTerritory ? '97ABCDE1234F1Z0' : '29ABCDE1234F1Z5',
              counterText: '',
              helperMaxLines: 3,
            ),
            maxLength: 15,
          ),
          const SizedBox(height: 16),
        ],
        TextFormField(
          controller: _panController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [
            UpperCaseInputFormatter(),
            LengthLimitingTextInputFormatter(10),
          ],
          validator: Validators.pan,
          decoration: const InputDecoration(
            labelText: 'PAN',
            hintText: 'ABCDE1234F',
            counterText: '',
          ),
          maxLength: 10,
        ),
      ],
    );
  }

  Widget _contactSection(AtriaColorsExtension colors, TextTheme text) {
    return AtriaFormSection(
      icon: Icons.call_outlined,
      title: 'Contact',
      children: [
        TextFormField(
          controller: _contactController,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Contact person',
            hintText: 'e.g. Ramesh Kumar',
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _phoneController,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.phone,
          validator: Validators.phone,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(10),
          ],
          decoration: const InputDecoration(
            labelText: 'Phone',
            hintText: '9876543210',
            prefixText: '+91 ',
            counterText: '',
          ),
          maxLength: 10,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _emailController,
          textInputAction: TextInputAction.next,
          keyboardType: TextInputType.emailAddress,
          validator: Validators.email,
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'name@business.in',
          ),
        ),
      ],
    );
  }

  Widget _addressSection(AtriaColorsExtension colors, TextTheme text) {
    return AtriaFormSection(
      icon: Icons.location_on_outlined,
      title: 'Billing address',
      children: [
        TextFormField(
          controller: _address1Controller,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Address line 1',
            hintText: 'Shop / building no., street',
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _address2Controller,
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Address line 2',
            hintText: 'Area, locality',
          ),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: TextFormField(
                controller: _cityController,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'City'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: TextFormField(
                controller: _pincodeController,
                textInputAction: TextInputAction.done,
                keyboardType: TextInputType.number,
                validator: Validators.pincode,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                decoration: const InputDecoration(
                  labelText: 'PIN code',
                  counterText: '',
                ),
                maxLength: 6,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          iconSize: AppIconSize.md,
          initialValue: _stateCode,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'State',
            hintText: 'Select state',
          ),
          items: [
            for (final state in IndianStates.all)
              DropdownMenuItem<String>(
                value: state.code,
                child: Text(
                  '${state.code} — ${state.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) => setState(() {
            _stateCode = value;
            _dirty = true;
          }),
          validator: (value) =>
              _gstinRequired && value == null ? 'Select a state' : null,
        ),
      ],
    );
  }

  Widget _creditSection(AtriaColorsExtension colors, TextTheme text) {
    return AtriaFormSection(
      icon: Icons.account_balance_wallet_outlined,
      title: 'Opening balance & credit terms',
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _openingController,
                keyboardType: TextInputType.number,
                inputFormatters: [IndianAmountInputFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Opening balance',
                  prefixText: '₹',
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 160,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Type',
                    style: text.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _segmentedControl<String>(
                    value: _openingBalanceType,
                    values: const ['dr', 'cr'],
                    labels: const {'dr': 'Dr', 'cr': 'Cr'},
                    onChanged: (value) => setState(() {
                      _openingBalanceType = value;
                      _dirty = true;
                    }),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextFormField(
                controller: _creditLimitController,
                textInputAction: TextInputAction.next,
                keyboardType: TextInputType.number,
                inputFormatters: [IndianAmountInputFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Credit limit',
                  prefixText: '₹',
                  hintText: 'Optional',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _creditDaysController,
                textInputAction: TextInputAction.done,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4),
                ],
                decoration: const InputDecoration(
                  labelText: 'Credit days',
                  hintText: 'Optional',
                  counterText: '',
                ),
                maxLength: 4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _notesController,
          textInputAction: TextInputAction.newline,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Notes',
            hintText: 'Anything to remember about this party',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  /// A labelled exclusive choice, rendered as a real [SegmentedButton].
  ///
  /// This was a hand-rolled `GestureDetector` pill: ~35dp tall (under the
  /// 44/48dp minimum) and with NO focus node at all, so on Windows the whole
  /// control was unreachable by Tab and could not be toggled with Space or
  /// Enter. [SegmentedButton] is what every other form in the app already uses
  /// (the item editor's Item type / Stock tracking toggles), and each segment
  /// is a real button: focusable, keyboard-operable, and announced as one.
  ///
  /// The 48dp minimum size is explicit because the app's theme sets
  /// `materialTapTargetSize: shrinkWrap`, which opts out of Material's 48dp
  /// tap target and leaves a segment at its 40dp default.
  Widget _segmentedControl<T>({
    required T value,
    required List<T> values,
    required Map<T, String> labels,
    required ValueChanged<T> onChanged,
  }) {
    return SegmentedButton<T>(
      segments: [
        for (final v in values)
          ButtonSegment<T>(value: v, label: Text(labels[v]!)),
      ],
      selected: {value},
      // The tick duplicates the label on a two-or-three option control and
      // squeezes the labels on a phone; selection is already shown by fill.
      showSelectedIcon: false,
      style: const ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, 48)),
      ),
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}
