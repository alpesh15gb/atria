import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/engine/document_numbering.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/state/providers.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Edits the currently active firm: business profile plus invoicing
/// configuration (prefixes, numbering, payment details).
class FirmSettingsScreen extends ConsumerStatefulWidget {
  const FirmSettingsScreen({super.key});

  @override
  ConsumerState<FirmSettingsScreen> createState() =>
      _FirmSettingsScreenState();
}

class _FirmSettingsScreenState extends ConsumerState<FirmSettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameController;
  late final TextEditingController _legalNameController;
  late final TextEditingController _gstinController;
  late final TextEditingController _panController;
  late final TextEditingController _address1Controller;
  late final TextEditingController _address2Controller;
  late final TextEditingController _cityController;
  late final TextEditingController _pincodeController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  late final TextEditingController _invoicePrefixController;
  late final TextEditingController _quotationPrefixController;
  late final TextEditingController _salesOrderPrefixController;
  late final TextEditingController _purchasePrefixController;
  late final TextEditingController _termsController;
  late final TextEditingController _notesController;
  late final TextEditingController _signatureController;
  late final TextEditingController _upiController;
  late final TextEditingController _bankNameController;
  late final TextEditingController _bankAccountNameController;
  late final TextEditingController _bankAccountNumberController;
  late final TextEditingController _bankIfscController;
  late final TextEditingController _bankBranchController;

  FirmEntity? _firm;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  bool get _hasChanges => _dirty && !_saving && !_loading;

  void _markDirty() {
    if (_dirty) return;
    _dirty = true;
    if (mounted) setState(() {});
  }

  /// Attached after _prefill so restoring stored values doesn't count as an
  /// edit. Every text field routes through here, so leaving with unsaved
  /// edits now asks instead of silently discarding.
  void _listenForEdits() {
    for (final controller in [
      _nameController,
      _legalNameController,
      _gstinController,
      _panController,
      _address1Controller,
      _address2Controller,
      _cityController,
      _pincodeController,
      _phoneController,
      _emailController,
      _invoicePrefixController,
      _quotationPrefixController,
      _salesOrderPrefixController,
      _purchasePrefixController,
      _termsController,
      _notesController,
      _signatureController,
      _upiController,
      _bankNameController,
      _bankAccountNameController,
      _bankAccountNumberController,
      _bankIfscController,
      _bankBranchController,
    ]) {
      controller.addListener(_markDirty);
    }
  }

  String? _stateCode;
  int _numberingStyle = 1;
  int _padding = 3;
  bool _showBank = false;
  bool _showQr = false;
  String? _logoPath;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _legalNameController = TextEditingController();
    _gstinController = TextEditingController();
    _panController = TextEditingController();
    _address1Controller = TextEditingController();
    _address2Controller = TextEditingController();
    _cityController = TextEditingController();
    _pincodeController = TextEditingController();
    _phoneController = TextEditingController();
    _emailController = TextEditingController();
    _invoicePrefixController = TextEditingController();
    _quotationPrefixController = TextEditingController();
    _salesOrderPrefixController = TextEditingController();
    _purchasePrefixController = TextEditingController();
    _termsController = TextEditingController();
    _notesController = TextEditingController();
    _signatureController = TextEditingController();
    _upiController = TextEditingController();
    _bankNameController = TextEditingController();
    _bankAccountNameController = TextEditingController();
    _bankAccountNumberController = TextEditingController();
    _bankIfscController = TextEditingController();
    _bankBranchController = TextEditingController();

    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    for (final controller in [
      _nameController,
      _legalNameController,
      _gstinController,
      _panController,
      _address1Controller,
      _address2Controller,
      _cityController,
      _pincodeController,
      _phoneController,
      _emailController,
      _invoicePrefixController,
      _quotationPrefixController,
      _salesOrderPrefixController,
      _purchasePrefixController,
      _termsController,
      _notesController,
      _signatureController,
      _upiController,
      _bankNameController,
      _bankAccountNameController,
      _bankAccountNumberController,
      _bankIfscController,
      _bankBranchController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final firm = ref.read(activeFirmProvider).valueOrNull ??
        await ref.read(appDatabaseProvider).firmRepository.defaultFirm;
    if (!mounted) return;
    if (firm == null) {
      setState(() => _loading = false);
      return;
    }
    _prefill(firm);
    setState(() {
      _firm = firm;
      _loading = false;
    });
  }

  void _prefill(FirmEntity firm) {
    _nameController.text = firm.name;
    _legalNameController.text = firm.legalName ?? '';
    _gstinController.text = firm.gstin ?? '';
    _panController.text = firm.pan ?? '';
    _address1Controller.text = firm.addressLine1 ?? '';
    _address2Controller.text = firm.addressLine2 ?? '';
    _cityController.text = firm.city ?? '';
    _pincodeController.text = firm.pincode ?? '';
    _phoneController.text = firm.phone ?? '';
    _emailController.text = firm.email ?? '';
    _invoicePrefixController.text = firm.invoicePrefix;
    _quotationPrefixController.text = firm.quotationPrefix;
    _salesOrderPrefixController.text = firm.salesOrderPrefix;
    _purchasePrefixController.text = firm.purchasePrefix;
    _termsController.text = firm.invoiceTerms ?? '';
    _notesController.text = firm.invoiceNotes ?? '';
    _signatureController.text = firm.signatureName ?? '';
    _upiController.text = firm.upiId ?? '';
    _bankNameController.text = firm.bankName ?? '';
    _bankAccountNameController.text = firm.bankAccountName ?? '';
    _bankAccountNumberController.text = firm.bankAccountNumber ?? '';
    _bankIfscController.text = firm.bankIfsc ?? '';
    _bankBranchController.text = firm.bankBranch ?? '';
    _stateCode = firm.stateCode;
    _numberingStyle = firm.numberingStyle;
    _padding = firm.invoiceSequencePadding;
    _showBank = firm.showBankOnInvoice;
    _showQr = firm.showQrOnInvoice;
    _logoPath = firm.logoPath;
    _listenForEdits();
  }

  // ---- Save --------------------------------------------------------------

  Future<void> _save() async {
    final firm = _firm;
    if (firm == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_saving) return; // double-submit guard.

    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      Value<String?> fieldValue(String value) {
        final trimmed = value.trim();
        return trimmed.isEmpty ? const Value.absent() : Value(trimmed);
      }

      await ref.read(appDatabaseProvider).firmRepository.update(
            firm.copyWith(
              name: _nameController.text.trim(),
              legalName: fieldValue(_legalNameController.text),
              gstin: fieldValue(_gstinController.text.toUpperCase()),
              pan: fieldValue(_panController.text.toUpperCase()),
              stateCode: Value(_stateCode),
              addressLine1: fieldValue(_address1Controller.text),
              addressLine2: fieldValue(_address2Controller.text),
              city: fieldValue(_cityController.text),
              pincode: fieldValue(_pincodeController.text),
              phone: fieldValue(_phoneController.text),
              email: fieldValue(_emailController.text),
              invoicePrefix: _invoicePrefixController.text.trim(),
              quotationPrefix: _quotationPrefixController.text.trim(),
              salesOrderPrefix: _salesOrderPrefixController.text.trim(),
              purchasePrefix: _purchasePrefixController.text.trim(),
              numberingStyle: _numberingStyle,
              invoiceSequencePadding: _padding,
              invoiceTerms: fieldValue(_termsController.text),
              invoiceNotes: fieldValue(_notesController.text),
              signatureName: fieldValue(_signatureController.text),
              upiId: fieldValue(_upiController.text),
              bankName: fieldValue(_bankNameController.text),
              bankAccountName: fieldValue(_bankAccountNameController.text),
              bankAccountNumber: fieldValue(_bankAccountNumberController.text),
              bankIfsc: fieldValue(_bankIfscController.text.toUpperCase()),
              bankBranch: fieldValue(_bankBranchController.text),
              showBankOnInvoice: _showBank,
              showQrOnInvoice: _showQr,
              logoPath: _logoPath == null
                  ? const Value.absent()
                  : Value(_logoPath),
            ),
          );
      if (!mounted) return;
      messenger?.showSnackBar(const SnackBar(content: Text('Saved')));
      _dirty = false;
      context.pop();
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not save: $error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _onGstinChanged(String value) {
    _markDirty();
    final gstin = value.trim().toUpperCase();
    if (!Validators.isValidGstin(gstin)) return;
    final stateCode = IndianStates.stateCodeFromGstin(gstin);
    if (stateCode != null && _stateCode == null) {
      setState(() => _stateCode = stateCode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firmAsync = ref.watch(activeFirmProvider);

    return SaveShortcut(
      enabled: !_saving,
      onSave: _save,
      child: UnsavedGuard(
        hasChanges: _hasChanges,
        child: Scaffold(
      appBar: AppBar(
        title: const Text('Firm Profile'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _saving || _firm == null ? null : _save,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.isCompact ? double.infinity : 760,
                ),
                child: _body(firmAsync),
              ),
            );
          },
        ),
      ),
        ),
      ),
    );
  }

  Widget _body(AsyncValue<FirmEntity?> firmAsync) {
    if (_loading || firmAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_firm == null) {
      return const EmptyState(
        icon: Icons.business_center_outlined,
        title: 'No business selected',
        message: 'Choose or create a firm to edit its profile.',
      );
    }
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 36),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          _profileSection(),
          const SizedBox(height: 20),
          _numberingSection(),
          const SizedBox(height: 20),
          _invoiceSection(),
          const SizedBox(height: 20),
          _paymentSection(),
        ],
      ),
    );
  }

  // ---- Sections ----------------------------------------------------------

  /// Invoice logo picker. The logoPath column existed but nothing ever
  /// wrote it — the PDF header had no way to show the firm's logo.
  Widget _logoPicker() {
    final path = _logoPath;
    return Row(
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: path != null && File(path).existsSync()
              ? Image.file(File(path), fit: BoxFit.contain)
              : Icon(Icons.image_outlined,
                  size: 22,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Invoice logo',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(
                path == null
                    ? 'PNG or JPG, shown on every printed invoice'
                    : 'Saved. Appears in the PDF header.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: _saving ? null : _pickLogo,
                    icon: const Icon(Icons.upload_file_rounded, size: 16),
                    label: Text(path == null ? 'Choose file' : 'Change'),
                  ),
                  if (path != null)
                    TextButton.icon(
                      onPressed: _saving ? null : () {
                        _markDirty();
                        setState(() => _logoPath = null);
                      },
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('Remove'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: false,
    );
    final file = result?.files.single;
    if (file == null || !mounted) return;
    if (file.size > 2 * 1024 * 1024) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('Choose an image under 2 MB.'),
      ));
      return;
    }
    try {
      // Copy into the app documents dir so the file outlives the original
      // download/folder it was picked from.
      final dir = await getApplicationDocumentsDirectory();
      final logos = Directory(p.join(dir.path, 'logos'));
      if (!logos.existsSync()) logos.createSync(recursive: true);
      final ext = (file.extension ?? 'png').toLowerCase();
      final dest = p.join(logos.path, 'firm_logo.$ext');
      await File(file.path!).copy(dest);
      _markDirty();
      setState(() => _logoPath = dest);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not copy the logo: $e')),
      );
    }
  }

  Widget _sectionCard({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: title),
        AtriaCard(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ],
    );
  }

  Widget _profileSection() {
    return _sectionCard(
      title: 'Business profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _logoPicker(),
          const SizedBox(height: 16),
          TextFormField(
            controller: _nameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Business name *',
              prefixIcon: Icon(Icons.storefront_outlined),
            ),
            validator: Validators.name,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _legalNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Legal / registered name',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: 12),
          _gstinField(),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _panController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                UpperCaseInputFormatter(),
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: const InputDecoration(
                labelText: 'PAN',
                hintText: 'ABCDE1234F',
                prefixIcon: Icon(Icons.credit_card_outlined),
                counterText: '',
              ),
              maxLength: 10,
              validator: Validators.pan,
            ),
            second: _stateField(),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _address1Controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Address line 1',
              prefixIcon: Icon(Icons.location_on_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _address2Controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Address line 2',
              prefixIcon: Icon(Icons.signpost_outlined),
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _cityController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'City',
                prefixIcon: Icon(Icons.location_city_outlined),
              ),
            ),
            second: TextFormField(
              controller: _pincodeController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                labelText: 'PIN code',
                prefixIcon: Icon(Icons.markunread_mailbox_outlined),
                counterText: '',
              ),
              maxLength: 6,
              validator: Validators.pincode,
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _phoneController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(10),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone',
                hintText: '9876543210',
                prefixText: '+91 ',
                prefixIcon: Icon(Icons.phone_outlined),
                counterText: '',
              ),
              maxLength: 10,
              validator: Validators.phone,
            ),
            second: TextFormField(
              controller: _emailController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'name@business.in',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              validator: Validators.email,
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberingSection() {
    final scheme = Theme.of(context).colorScheme;
    final preview = DocumentNumbering.format(
      prefix: _invoicePrefixController.text.trim().isEmpty
          ? 'INV'
          : _invoicePrefixController.text.trim(),
      sequence: 1,
      style: NumberingStyle.values[_numberingStyle.clamp(0, 2)],
      padding: _padding,
    );

    return _sectionCard(
      title: 'Invoicing',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _FieldRow(
            first: _prefixField(
              controller: _invoicePrefixController,
              label: 'Invoice prefix',
              hint: 'INV',
            ),
            second: _prefixField(
              controller: _quotationPrefixController,
              label: 'Quotation prefix',
              hint: 'QT',
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: _prefixField(
              controller: _salesOrderPrefixController,
              label: 'Sales order prefix',
              hint: 'SO',
            ),
            second: _prefixField(
              controller: _purchasePrefixController,
              label: 'Purchase prefix',
              hint: 'PUR',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _numberingStyle,
            decoration: const InputDecoration(
              labelText: 'Numbering style',
              prefixIcon: Icon(Icons.numbers_rounded),
            ),
            items: [
              for (final style in NumberingStyle.values)
                DropdownMenuItem<int>(
                  value: style.index,
                  child: Text(style.label),
                ),
            ],
            onChanged: (value) {
              _markDirty();
              setState(() => _numberingStyle = value ?? 1);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _padding,
            decoration: const InputDecoration(
              labelText: 'Sequence padding',
              prefixIcon: Icon(Icons.format_list_numbered_rounded),
              helperText: 'Zeroes added before the number',
            ),
            items: [
              for (var pad = 1; pad <= 6; pad++)
                DropdownMenuItem<int>(
                  value: pad,
                  child: Text(
                    '$pad digits',
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
            onChanged: (value) {
              _markDirty();
              setState(() => _padding = value ?? 3);
            },
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius:
                  const BorderRadius.all(Radius.circular(AppRadius.md)),
            ),
            child: Row(
              children: [
                PhosphorIcon(
                  PhosphorIconsRegular.invoice,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Next invoice number',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                  ),
                ),
                Text(
                  preview,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimaryContainer,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _invoiceSection() {
    return _sectionCard(
      title: 'Invoice terms & notes',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            controller: _termsController,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Default terms & conditions',
              hintText: 'Printed at the bottom of every invoice',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _notesController,
            textCapitalization: TextCapitalization.sentences,
            maxLines: 3,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'Default notes',
              hintText: 'e.g. Thank you for your business.',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _signatureController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Authorised signatory',
              hintText: 'Name printed under the signature line',
              prefixIcon: Icon(Icons.draw_outlined),
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentSection() {
    return _sectionCard(
      title: 'Payments on invoice',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showBank,
            onChanged: (value) {
              _markDirty();
              setState(() => _showBank = value);
            },
            title: const Text('Show bank details'),
            subtitle: const Text('Print account details on the invoice'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showQr,
            onChanged: (value) {
              _markDirty();
              setState(() => _showQr = value);
            },
            title: const Text('Show UPI QR code'),
            subtitle: const Text('Customers scan to pay instantly'),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _upiController,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'UPI ID',
              hintText: 'yourname@bank',
              prefixIcon: Icon(Icons.qr_code_2_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Bank name',
              prefixIcon: Icon(Icons.account_balance_outlined),
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _bankAccountNameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Account holder name',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
            ),
            second: TextFormField(
              controller: _bankAccountNumberController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Account number',
                prefixIcon: Icon(Icons.credit_card_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _FieldRow(
            first: TextFormField(
              controller: _bankIfscController,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                UpperCaseInputFormatter(),
                LengthLimitingTextInputFormatter(11),
              ],
              decoration: const InputDecoration(
                labelText: 'IFSC code',
                hintText: 'SBIN0001234',
                prefixIcon: Icon(Icons.code_rounded),
                counterText: '',
              ),
              maxLength: 11,
              validator: Validators.ifsc,
            ),
            second: TextFormField(
              controller: _bankBranchController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Branch',
                prefixIcon: Icon(Icons.store_mall_directory_outlined),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Fields ------------------------------------------------------------

  Widget _gstinField() {
    return ListenableBuilder(
      listenable: _gstinController,
      builder: (context, _) {
        final value = _gstinController.text.trim().toUpperCase();
        final valid = Validators.isValidGstin(value);
        final colors = atriaColors(context);
        final scheme = Theme.of(context).colorScheme;

        return TextFormField(
          controller: _gstinController,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          inputFormatters: [
            UpperCaseInputFormatter(),
            LengthLimitingTextInputFormatter(15),
          ],
          maxLength: 15,
          onChanged: _onGstinChanged,
          validator: Validators.gstin,
          decoration: InputDecoration(
            labelText: 'GSTIN',
            hintText: '29ABCDE1234F1Z5',
            prefixIcon: const Icon(Icons.receipt_long_outlined),
            counterText: '',
            suffixIcon: value.isEmpty
                ? null
                : valid
                    ? Icon(Icons.verified_rounded, color: colors.positive)
                    : Icon(Icons.error_outline_rounded, color: scheme.error),
          ),
        );
      },
    );
  }

  Widget _stateField() {
    return DropdownButtonFormField<String?>(
      initialValue: _stateCode,
      decoration: const InputDecoration(
        labelText: 'State',
        hintText: 'Select state',
        prefixIcon: Icon(Icons.map_outlined),
      ),
      items: [
        for (final state in IndianStates.all)
          DropdownMenuItem<String?>(
            value: state.code,
            child: Text(
              '${state.code} — ${state.name}',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
      onChanged: (value) {
        _markDirty();
        setState(() => _stateCode = value);
      },
    );
  }

  Widget _prefixField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextFormField(
      controller: controller,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.next,
      inputFormatters: [
        UpperCaseInputFormatter(),
        LengthLimitingTextInputFormatter(10),
      ],
      // Rebuild per keystroke so the "Next invoice number" preview tracks
      // the prefix being typed (it used to show the stale stored prefix).
      onChanged: (_) {
        _markDirty();
        setState(() {});
      },
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.tag_rounded),
        counterText: '',
      ),
      maxLength: 10,
    );
  }
}

/// Two fields side by side on wide content areas, stacked on narrow ones.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.first, required this.second});

  final Widget first;
  final Widget second;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: 12),
              second,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: first),
              const SizedBox(width: 12),
              Expanded(child: second),
            ],
          ),
        );
      },
    );
  }
}
