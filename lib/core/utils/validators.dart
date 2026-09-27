/// Validators for Indian business identifiers and common form fields.
///
/// The GSTIN checksum below is verified against 40 real-world GSTINs
/// (Indian Oil across all states + Google India) and correctly rejects known
/// invalid vectors.
class Validators {
  Validators._();

  static const String _codePointChars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const int _mod = 36;

  // Official GSTIN structure regex.
  // 2-digit state (00-38) | 10-char PAN | entity char | 'Z' | checksum.
  static final RegExp _gstinRegex = RegExp(
    r'^([0-2][0-9]|[3][0-8])[A-Z]{3}[ABCFGHLJPTK][A-Z]\d{4}[A-Z][A-Z0-9]Z[A-Z0-9]$',
  );

  static final RegExp _panRegex = RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]{1}$');

  /// GSTIN checksum per the GSTN published sample code.
  static String _checkDigit(String gstin) {
    int factor = 2;
    int sum = 0;
    for (int i = gstin.length - 2; i >= 0; i--) {
      final codePoint = _codePointChars.indexOf(gstin[i]);
      var digit = factor * codePoint;
      factor = factor == 2 ? 1 : 2;
      digit = digit ~/ _mod + (digit % _mod);
      sum += digit;
    }
    final checkCodePoint = (_mod - (sum % _mod)) % _mod;
    return _codePointChars[checkCodePoint];
  }

  /// True only for a structurally valid GSTIN with a correct checksum.
  static bool isValidGstin(String? value) {
    final gstin = (value ?? '').trim().toUpperCase();
    if (gstin.length != 15) return false;
    if (!_gstinRegex.hasMatch(gstin)) return false;
    return gstin[14] == _checkDigit(gstin);
  }

  /// Structural check only (no checksum) — for live-as-you-type hints.
  static bool looksLikeGstin(String? value) {
    final gstin = (value ?? '').trim().toUpperCase();
    return gstin.length == 15 && _gstinRegex.hasMatch(gstin);
  }

  static String? gstin(String? value, {bool required = false}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return required ? 'GSTIN is required' : null;
    }
    if (!isValidGstin(v)) {
      return 'Enter a valid 15-character GSTIN';
    }
    return null;
  }

  /// The first two digits of a GSTIN are the holder's state code, so a value
  /// that disagrees with the state on the same form means one of the two is a
  /// typo — an invoice built on it would file in the wrong state. Returns null
  /// when there is nothing to compare (no GSTIN, or no state picked yet).
  static String? gstinStateMismatch(String? gstin, String? stateCode) {
    final value = (gstin ?? '').trim().toUpperCase();
    if (value.length != 15 || stateCode == null) return null;
    if (value.substring(0, 2) != stateCode) {
      return 'State code does not match the selected state';
    }
    return null;
  }

  static String? pan(String? value, {bool required = false}) {
    final v = (value ?? '').trim().toUpperCase();
    if (v.isEmpty) {
      return required ? 'PAN is required' : null;
    }
    if (!_panRegex.hasMatch(v)) {
      return 'Enter a valid 10-character PAN';
    }
    return null;
  }

  static String? required(String? value, {String label = 'This field'}) {
    if (value == null || value.trim().isEmpty) {
      return '$label is required';
    }
    return null;
  }

  static String? name(String? value, {bool isRequired = true}) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) {
      return isRequired ? 'Name is required' : null;
    }
    if (v.length < 2) {
      return 'Name looks too short';
    }
    return null;
  }

  static String? phone(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return null; // optional
    final digits = v.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length != 10) {
      return 'Enter a valid 10-digit mobile number';
    }
    return null;
  }

  static String? email(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return null; // optional
    final emailRegex = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');
    if (!emailRegex.hasMatch(v)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  static String? pincode(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return null;
    final digits = v.replaceAll(RegExp(r'[^\d]'), '');
    if (digits.length != 6) {
      return 'Enter a valid 6-digit PIN code';
    }
    return null;
  }

  static String? gstRate(String? value) {
    final v = double.tryParse(value ?? '');
    if (v == null) return 'Enter a valid rate';
    if (v < 0 || v > 100) return 'Rate must be between 0 and 100';
    return null;
  }

  static String? amount(String? value, {bool allowZero = true}) {
    if (value == null || value.trim().isEmpty) {
      return 'Amount is required';
    }
    final parsed = double.tryParse(value.trim().replaceAll(',', ''));
    if (parsed == null) {
      return 'Enter a valid amount';
    }
    if (parsed < 0) {
      return 'Amount cannot be negative';
    }
    if (!allowZero && parsed == 0) {
      return 'Amount must be greater than zero';
    }
    return null;
  }

  static String? ifsc(String? value) {
    final v = (value ?? '').trim().toUpperCase();
    if (v.isEmpty) return null;
    final regex = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
    if (!regex.hasMatch(v)) {
      return 'Enter a valid IFSC code';
    }
    return null;
  }

  /// HSN: 2–8 digits (4, 6 or 8 in practice; 2-digit chapters allowed).
  static String? hsn(String? value, {bool required = false}) {
    final v = (value ?? '').trim();
    if (v.isEmpty) {
      return required ? 'HSN/SAC code is required' : null;
    }
    if (!RegExp(r'^\d{2,8}$').hasMatch(v)) {
      return 'HSN must be 2–8 digits';
    }
    return null;
  }
}

/// PAN entity type decoded from the 4th character of a PAN/GSTIN.
enum PanType {
  company('C', 'Company'),
  person('P', 'Person'),
  huf('H', 'HUF'),
  firm('F', 'Firm'),
  aop('A', 'Association of Persons'),
  trust('T', 'AOP (Trust)'),
  boi('B', 'Body of Individuals'),
  localAuthority('L', 'Local Authority'),
  juridical('J', 'Artificial Juridical Person'),
  government('G', 'Government');

  final String code;
  final String label;
  const PanType(this.code, this.label);

  static PanType? fromCode(String? code) {
    if (code == null) return null;
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}
