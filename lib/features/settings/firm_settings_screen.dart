import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' show PdfColor;
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/api/server_client.dart';
import '../../core/constants/indian_states.dart';
import '../../core/database/app_database.dart';
import '../../core/database/repositories/repository_extensions.dart';
import '../../core/engine/document_numbering.dart';
import '../../core/services/pdf_template_style.dart';
import '../../core/state/providers.dart';
import '../../core/responsive/platform_ui.dart';
import '../../shared/widgets/mobile_template_picker.dart';
import '../../shared/widgets/editor_shell.dart';
import '../../core/theme/app_radius.dart';
import '../../core/theme/app_sizes.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/validators.dart';
import '../../shared/widgets/atria_field_icon.dart';
import '../../shared/widgets/common_widgets.dart';
import '../../shared/widgets/save_shortcut.dart';
import '../../shared/widgets/unsaved_guard.dart';

/// Edits the currently active firm: business profile plus invoicing
/// configuration (prefixes, numbering, payment details).
class FirmSettingsScreen extends ConsumerStatefulWidget {
  const FirmSettingsScreen({super.key, this.section});

  /// Mobile section deep links use the same controllers and save transaction.
  final String? section;

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
  /// A removal is in flight. Separate from [_saving] because the two do
  /// different things to the same form, and only one of them can navigate away.
  bool _removing = false;

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

  /// Which printed-document layout this firm uses. Resolved through
  /// [PdfTemplateStyle.resolve] rather than stored verbatim, so a column
  /// written by a newer build — or by a restored backup — cannot put the form
  /// into a state where nothing is selected.
  late PdfTemplateStyle _template;

  String? _logoPath;
  /// A logo file that is on disk but will not be referenced once the current
  /// form is saved — replaced by a different file, or removed. Deleted only
  /// after the save succeeds, so backing out of the screen never leaves the
  /// firm pointing at a file that has been eaten. See [_deleteLogoFile].
  String? _staleLogoPath;
  /// Whether [_logoPath] still resolves to a file, resolved when the path
  /// changes rather than inside `build`.
  ///
  /// It used to be `File(path).existsSync()` evaluated during `build`, so every
  /// character typed in a prefix field (the numbering preview rebuilds the
  /// whole screen) paid for a synchronous disk stat on the UI isolate.
  bool _logoOnDisk = false;

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
    _refreshLogoPresence();
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
    _template = PdfTemplateStyle.resolve(firm.pdfTemplate);
    _logoPath = firm.logoPath;
    _staleLogoPath = null;
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
      // A cleared box must CLEAR the column.
      //
      // Drift's generated `copyWith` reads `Value.absent()` as "leave this
      // column alone, keep the old value", and `firmRepository.update` writes
      // the result with `db.update(...).replace(...)`. So mapping empty input to
      // absent (which is what this used to do) made every optional field
      // impossible to clear: empty the GSTIN, press Save, see "Saved", go back
      // to the invoice — and the old GSTIN is still printed on it, with no way
      // anywhere in the app to remove it.
      //
      // Every column fed through here is nullable in `tables/firms.dart`
      // (legalName, gstin, pan, addressLine1/2, city, pincode, phone, email,
      // logoPath, invoiceTerms, invoiceNotes, signatureName, upiId, bankName,
      // bankAccountName, bankAccountNumber, bankIfsc, bankBranch), so `null`
      // is a legal write and is exactly what "the box was cleared" means. The
      // NOT-nullable columns (`name`, the four prefixes) are passed below as
      // plain strings and deliberately never come through this helper.
      Value<String?> fieldValue(String value) {
        final trimmed = value.trim();
        return trimmed.isEmpty ? const Value<String?>(null) : Value(trimmed);
      }

      await ref.read(appDatabaseProvider).firmRepository.update(
            firm.copyWith(
              name: _nameController.text.trim(),
              legalName: fieldValue(_legalNameController.text),
              gstin: fieldValue(_gstinController.text.toUpperCase()),
              pan: fieldValue(_panController.text.toUpperCase()),
              // Always written, so clearing the State dropdown really clears the
              // column. Same reasoning as the fields above.
              stateCode: Value<String?>(_stateCode),
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
              pdfTemplate: _template.id,
              // The same absent-vs-null trap, with a visible symptom: absent left
              // the stored path in place, so "Remove" never removed the logo and
              // the deleted logo went on printing in the PDF header.
              logoPath: _logoPath == null
                  ? const Value<String?>(null)
                  : Value(_logoPath),
            ),
          );
      // The firm no longer points at the replaced file, so it is now safe to
      // take it off the disk.
      final stale = _staleLogoPath;
      _staleLogoPath = null;
      if (stale != null) await _deleteLogoFile(stale);
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
        title: Text(Theme.of(context).platform.isMobileUi ? switch (widget.section) { 'templates' => 'Templates', 'bank' => 'Bank Details', 'signature' => 'Signature', 'documents' => 'Document Settings', _ => 'Company Details' } : 'Firm Profile'),
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
          if (!Theme.of(context).platform.isMobileUi) Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton.icon(
              onPressed: _saving || _firm == null ? null : _save,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      // Full width: the profile was centred in a 760px column, which left
      // two-thirds of a desktop window as dead grey margin around a form the
      // user is actively editing. The fields group themselves into two-up
      // rows via _FieldRow, so the width is used, not stretched.
      body: SafeArea(child: _body(firmAsync)),
      bottomNavigationBar: Theme.of(context).platform.isMobileUi ? EditorBottomBar(onSave: _save, saving: _saving, saveLabel: 'Save changes') : null,
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
    if (Theme.of(context).platform.isMobileUi && widget.section == 'templates') {
      return Form(key: _formKey, child: MobileTemplatePicker(firm: _firm!, selected: _template, onChanged: (style) { _markDirty(); setState(() => _template = style); }));
    }
    if (Theme.of(context).platform.isMobileUi && widget.section != null) {
      return Form(key: _formKey, child: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.section == 'documents') ...[_numberingSection(), const SizedBox(height: 20), _invoiceSection()],
        if (widget.section == 'bank') _paymentSection(),
        if (widget.section == 'signature') _sectionCard(title: 'Authorised signatory', child: TextFormField(controller: _signatureController, decoration: const InputDecoration(labelText: 'Signature name', hintText: 'Name printed on your documents'))),
      ]));
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
          _templateSection(),
          const SizedBox(height: 20),
          _paymentSection(),
          const SizedBox(height: 20),
          _dangerSection(),
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
          // Reads the cached answer rather than stat-ing the disk: this widget is
          // rebuilt on every keystroke of the numbering preview below.
          child: path != null && _logoOnDisk
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
                      onPressed: _saving
                          ? null
                          : () {
                              _markDirty();
                              // The file itself goes only once the save lands —
                              // see [_staleLogoPath].
                              setState(() {
                                _staleLogoPath ??= _logoPath;
                                _logoPath = null;
                                _logoOnDisk = false;
                              });
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

  /// Resolves whether the current [_logoPath] is a file, off the build path.
  ///
  /// Called when the path changes, never while laying out — a synchronous stat
  /// in `build` turned every keystroke anywhere on this screen into a disk
  /// round trip on the UI isolate.
  Future<void> _refreshLogoPresence() async {
    final path = _logoPath;
    if (path == null) {
      if (mounted && _logoOnDisk) setState(() => _logoOnDisk = false);
      return;
    }
    var exists = false;
    try {
      exists = await File(path).exists();
    } on Object {
      exists = false; // unreadable path: show the placeholder, not a crash
    }
    // A different path may have been chosen while the stat was in flight.
    if (!mounted || _logoPath != path || _logoOnDisk == exists) return;
    setState(() => _logoOnDisk = exists);
  }

  /// Deletes a logo file the firm no longer points at.
  ///
  /// Restricted to the app's own `logos` folder on purpose: `logoPath` can
  /// arrive from a restored backup holding any path at all, and a stray delete
  /// there would be the app eating the user's own files.
  Future<void> _deleteLogoFile(String path) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (!p.equals(p.dirname(path), p.join(dir.path, 'logos'))) return;
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on Object {
      // A leftover image is harmless; failing the save over it would not be.
    }
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
      final previous = _logoPath;
      await File(file.path!).copy(dest);
      _markDirty();
      setState(() {
        // A different extension means a different basename, and the old file
        // would sit in the logos folder for ever with nothing pointing at it.
        // Cleared on save, not here: if the user walks away, the firm still
        // needs its existing logo.
        if (previous != null && !p.equals(previous, dest)) {
          _staleLogoPath = previous;
        }
        _logoPath = dest;
        // Just copied, so no need to stat it.
        _logoOnDisk = true;
      });
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
              prefixIcon: AtriaFieldIcon(Icons.storefront_outlined),
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
              prefixIcon: AtriaFieldIcon(Icons.badge_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.credit_card_outlined),
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
              prefixIcon: AtriaFieldIcon(Icons.location_on_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _address2Controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Address line 2',
              prefixIcon: AtriaFieldIcon(Icons.signpost_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.location_city_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.markunread_mailbox_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.phone_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.mail_outline_rounded),
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
            iconSize: AppIconSize.md,
            initialValue: _numberingStyle,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Numbering style',
              prefixIcon: AtriaFieldIcon(Icons.numbers_rounded),
            ),
            items: [
              for (final style in NumberingStyle.values)
                DropdownMenuItem<int>(
                  value: style.index,
                  child: Text(
                    style.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              _markDirty();
              setState(() => _numberingStyle = value ?? 1);
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            iconSize: AppIconSize.md,
            initialValue: _padding,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Sequence padding',
              prefixIcon: AtriaFieldIcon(Icons.format_list_numbered_rounded),
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
              prefixIcon: AtriaFieldIcon(Icons.draw_outlined),
            ),
          ),
        ],
      ),
    );
  }

  /// Layout picker for printed documents.
  ///
  /// Per firm, not per document, on purpose: printed material is filed and
  /// handed to customers, so a shop picks one look and keeps it.
  Widget _templateSection() {
    final scheme = Theme.of(context).colorScheme;
    return _sectionCard(
      title: 'Printed document layout',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A rendered swatch rather than a name, because "Minimal" and
          // "Classic" describe nothing you can picture from a list.
          for (final style in PdfTemplateStyle.all) ...[
            _TemplateOption(
              style: style,
              selected: style.id == _template.id,
              onTap: () {
                _markDirty();
                setState(() => _template = style);
              },
            ),
            if (style != PdfTemplateStyle.all.last) const SizedBox(height: 10),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.lock_outline_rounded,
                  size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'Applies to every invoice, quotation and receipt printed from '
                  'this firm.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
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
              prefixIcon: AtriaFieldIcon(Icons.qr_code_2_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _bankNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Bank name',
              prefixIcon: AtriaFieldIcon(Icons.account_balance_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.person_outline_rounded),
              ),
            ),
            second: TextFormField(
              controller: _bankAccountNumberController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Account number',
                prefixIcon: AtriaFieldIcon(Icons.credit_card_outlined),
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
                prefixIcon: AtriaFieldIcon(Icons.code_rounded),
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
                prefixIcon: AtriaFieldIcon(Icons.store_mall_directory_outlined),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Danger zone -------------------------------------------------------

  Widget _dangerSection() {
    final scheme = Theme.of(context).colorScheme;
    return _sectionCard(
      title: 'Danger zone',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PhosphorIcon(
                PhosphorIconsRegular.warningOctagon,
                size: AppIconSize.md,
                color: scheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Removing this business deletes its invoices, purchases, '
                  'payments, expenses, parties and items. There is no recycle '
                  'bin behind this, on the device or on the server.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.5,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  (_removing || _firm == null || _saving) ? null : _removeBusiness,
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
              ),
              icon: _removing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined,
                      size: AppIconSize.md),
              label: Text(_removing ? 'Removing…' : 'Remove this business'),
            ),
          ),
        ],
      ),
    );
  }

  /// Asks where the removal should stop, then whether the person meant it, then
  /// does it.
  ///
  /// Two questions rather than one because they are genuinely different: the
  /// first is *how far* the business should stop existing, the second is
  /// whether this was deliberate. Neither is a good place to infer the other.
  Future<void> _removeBusiness() async {
    final firm = _firm;
    if (firm == null) return;

    // Read the session up front so the sheet can say *why* the server option
    // is unavailable, instead of offering it and failing afterwards.
    final account = await _signedInLabel();
    if (!mounted) return;

    final eraseRemote = await _askRemovalScope(
      firmName: firm.name,
      account: account,
    );
    // null means the sheet was dismissed. Dismissing is not consent to delete
    // anything, and must not be read as "local only".
    if (eraseRemote == null || !mounted) return;

    final confirmed = await _confirmRemoval(firm, eraseRemote: eraseRemote);
    if (confirmed != true || !mounted) return;

    await _performRemoval(firm, eraseRemote: eraseRemote);
  }

  /// "Only on this device" or "here and on the server".
  Future<bool?> _askRemovalScope({
    required String firmName,
    required String? account,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final text = Theme.of(sheetContext).textTheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  'Remove "$firmName"',
                  style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Choose how far the removal should go.',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              ListTile(
                leading: PhosphorIcon(
                  PhosphorIconsRegular.laptop,
                  color: scheme.primary,
                ),
                title: const Text('Only on this device'),
                subtitle: const Text(
                  'The books disappear from here. Anything already synced to '
                  'Apex Books stays on the server, and comes back if you sign this '
                  'account in again.',
                ),
                onTap: () => Navigator.of(sheetContext).pop(false),
              ),
              ListTile(
                enabled: account != null,
                leading: PhosphorIcon(
                  PhosphorIconsRegular.cloudSlash,
                  color: account != null
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
                title: const Text('Here and on the Apex Books server'),
                subtitle: Text(
                  account == null
                      ? 'Sign in to Apex Books on this device first: without a '
                          'session the server has no way to know this is your '
                          'business.'
                      : 'Erases it from $account and from every other device '
                          'signed in to it, permanently.',
                ),
                onTap: account == null
                    ? null
                    : () => Navigator.of(sheetContext).pop(true),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// Types-the-name confirmation. Stronger than the recycle bin's "PURGE"
  /// because the blast radius is a whole set of books, not one document.
  Future<bool?> _confirmRemoval(
    FirmEntity firm, {
    required bool eraseRemote,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        var typed = '';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: Text('Remove "${firm.name}" for good?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eraseRemote
                      ? 'Every invoice, purchase, payment, expense, party and '
                          'item in this business will be destroyed on this '
                          'device and erased from Apex Books\'s servers. This cannot '
                          'be undone, and no backup is taken for you.'
                      : 'Every invoice, purchase, payment, expense, party and '
                          'item in this business will be destroyed on this '
                          'device. This cannot be undone, and no backup is '
                          'taken for you.',
                ),
                const SizedBox(height: 12),
                Text(
                  'Type ${firm.name} to confirm.',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                TextField(
                  autofocus: true,
                  onChanged: (value) =>
                      setDialogState(() => typed = value.trim()),
                  decoration: InputDecoration(hintText: firm.name),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  foregroundColor: Theme.of(dialogContext).colorScheme.error,
                ),
                onPressed: typed == firm.name
                    ? () => Navigator.of(dialogContext).pop(true)
                    : null,
                child: const Text('Remove forever'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _performRemoval(
    FirmEntity firm, {
    required bool eraseRemote,
  }) async {
    setState(() => _removing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final db = ref.read(appDatabaseProvider);
    try {
      // Server first, deliberately. The dialog said the business would be
      // erased there, so deleting locally first and then failing to reach the
      // server would leave a device claiming a deletion that did not happen.
      // Failing before anything is touched is the one outcome the person can
      // act on.
      if (eraseRemote) {
        // Through the auth controller, not the settings row: an access token
        // that has merely expired is renewed here, so "signed in yesterday"
        // does not read as "signed out" in the one flow that must not.
        //
        // `resolveAccessToken` rather than `accessToken`, because a null token
        // means two different things here. Being offline used to produce "this
        // device is no longer signed in to Apex Books, so nothing was removed" —
        // which blames the account for a network problem and is thrown BEFORE
        // the local purge runs, so a shop that merely lost signal could not
        // delete its own business from the device.
        final session = await ref
            .read(authControllerProvider.notifier)
            .resolveAccessToken();
        final accessToken = session.accessToken;
        if (accessToken == null) {
          if (session.temporarilyUnavailable) {
            throw const ServerRequestException(
              'Could not reach Apex Books, so nothing was removed from the server '
              'or from this device. Check your connection and try again — the '
              'business was left untouched.',
              signedOut: false,
            );
          }
          throw const ServerRequestException(
            'This device is no longer signed in to Apex Books, so nothing was '
            'removed from the server or from this device.',
            signedOut: true,
          );
        }
        await ref.read(serverClientProvider).eraseFirm(
              firmId: firm.id,
              accessToken: accessToken,
            );
      }

      await db.firmRepository.purge(firm.id);
      await _repointActiveFirm(db, firm.id);

      if (!mounted) return;
      // Cleared before navigating, or the UnsavedGuard around this form would
      // still consider the (now deleted) business as having unsaved edits.
      _dirty = false;
      messenger?.showSnackBar(SnackBar(
        content: Text(eraseRemote
            ? '"${firm.name}" was removed from this device and from Apex Books'
            : '"${firm.name}" was removed from this device'),
      ));
      context.go('/dashboard');
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not remove the business: $error')),
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  /// The signed-in address, or null when this device has no usable session.
  ///
  /// A renewal is attempted first, because the removal sheet's whole point is
  /// to tell the user which account the server-side erase would apply to, and
  /// an expired access token does not change that answer.
  Future<String?> _signedInLabel() async {
    final controller = ref.read(authControllerProvider.notifier);
    // `needsSignIn` rather than "the token was null": a session that merely
    // could not be renewed is still signed in, and this label decides whether
    // the server-side erase option is offered. Collapsing the two made the
    // option grey out on a train, and told the person to sign in when they
    // already had.
    final session = await controller.resolveAccessToken();
    if (session.needsSignIn) return null;
    final email = ref.read(authControllerProvider).email;
    return email.trim().isEmpty ? 'your Apex Books account' : email;
  }

  /// Moves the app off the business that was just removed.
  ///
  /// Through [ActiveFirmController.clear] rather than `select(null)` when
  /// nothing is left, because select deliberately does not persist a null: the
  /// removed id would stay in settings and the next launch would try to open
  /// books that no longer exist. With nothing left, the router's redirect then
  /// sends the user to firm setup on its own.
  Future<void> _repointActiveFirm(AppDatabase db, String removedId) async {
    final remaining = await db.firmRepository.all();
    if (remaining.isEmpty) {
      await ref.read(activeFirmIdProvider.notifier).clear();
      return;
    }
    // Keep the existing default if there is one, so "which business opens on
    // launch" does not silently change just because this one was deleted.
    final next = remaining.firstWhere(
      (firm) => firm.isDefault,
      orElse: () => remaining.first,
    );
    await ref.read(activeFirmIdProvider.notifier).select(next.id);
    if (!next.isDefault) {
      await db.firmRepository.setDefault(next.id);
    }
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
            prefixIcon: const AtriaFieldIcon(Icons.receipt_long_outlined),
            counterText: '',
            suffixIcon: value.isEmpty
                ? null
                : valid
                    ? Icon(
                        Icons.verified_rounded,
                        size: AppIconSize.md,
                        color: colors.positive,
                      )
                    : Icon(
                        Icons.error_outline_rounded,
                        size: AppIconSize.md,
                        color: scheme.error,
                      ),
          ),
        );
      },
    );
  }

  Widget _stateField() {
    return DropdownButtonFormField<String?>(
      iconSize: AppIconSize.md,
      initialValue: _stateCode,
      // A DropdownButton sizes itself to its WIDEST item, so with the full
      // '29 — Karnataka' list this field asked for 330px inside a 249px slot
      // and painted the "BOTTOM OVERFLOWED / RIGHT OVERFLOWED" stripes over the
      // Business details card. `isExpanded` makes the field take the width it
      // is given and the long names ellipsis inside it.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'State',
        hintText: 'Select state',
        prefixIcon: AtriaFieldIcon(Icons.map_outlined),
      ),
      items: [
        for (final state in IndianStates.all)
          DropdownMenuItem<String?>(
            value: state.code,
            child: Text(
              '${state.code} — ${state.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
      // This is a plain rebuild — nothing on this path touches the disk any
      // more, which is why the logo's existence check is cached rather than
      // stat-ed here.
      onChanged: (_) {
        _markDirty();
        setState(() {});
      },
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const AtriaFieldIcon(Icons.tag_rounded),
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

/// One [PdfTemplateStyle] in the picker: a miniature of the page it prints,
/// the name, and one line explaining who it suits.
///
/// The swatch exists because "Classic" and "Minimal" describe nothing you can
/// picture from a list — the difference between them is entirely visual.
class _TemplateOption extends StatelessWidget {
  const _TemplateOption({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  final PdfTemplateStyle style;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.45)
                : scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TemplateSwatch(style: style),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            style.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle_rounded,
                              size: 18, color: scheme.primary),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      style.description,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A 44×58 miniature of what the layout actually prints: the header band (or
/// the classic gradient), the items heading strip, three body rows with zebra
/// shading where the template uses it, and the accent band behind the total.
///
/// Every colour is read off the style that will render the real PDF, so the
/// swatch cannot drift away from the output the way a hand-picked icon would.
class _TemplateSwatch extends StatelessWidget {
  const _TemplateSwatch({required this.style});

  final PdfTemplateStyle style;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Container(
      width: 44,
      height: 58,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: style.line.toFlutter()),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: a solid band where the template uses one, the classic
          // gradient otherwise. Both are what the PDF prints.
          Container(
            height: 13,
            decoration: BoxDecoration(
              color: style.usesHeaderBand
                  ? style.brand.toFlutter()
                  : null,
              gradient: style.usesHeaderBand
                  ? null
                  : LinearGradient(
                      colors: [
                        style.brand.toFlutter(),
                        style.brandDeep.toFlutter(),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Container(height: 3, color: style.brand.toFlutter()),
          ),
          const SizedBox(height: 3),
          for (var i = 0; i < 3; i++)
            Container(
              height: 4,
              margin: const EdgeInsets.only(bottom: 3, left: 3, right: 3),
              decoration: BoxDecoration(
                color: (style.usesZebraRows && i.isOdd)
                    ? style.tint.toFlutter()
                    : null,
                border: i.isEven
                    ? Border(
                        bottom: BorderSide(
                            color: style.line.toFlutter(), width: 0.5),
                      )
                    : null,
              ),
            ),
          const Spacer(),
          Container(height: 8, color: style.accentBand.toFlutter()),
          Container(height: 5, color: style.footerBand.toFlutter()),
        ],
      ),
    );
  }
}

extension on PdfColor {
  /// [PdfColor] is the PDF library's own type and does not implement Flutter's
  /// `Color`, so the swatch cannot hand it straight to a `BoxDecoration`.
  Color toFlutter() => Color.fromARGB(
        (alpha * 255).round(),
        (red * 255).round(),
        (green * 255).round(),
        (blue * 255).round(),
      );
}
