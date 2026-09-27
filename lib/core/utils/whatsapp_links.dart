/// WhatsApp deep links. India country code (+91) assumed — phone numbers are
/// validated as 10-digit domestic numbers app-wide, so prefixing the digits
/// with the country code is always correct; the links just used to hardcode
/// the "91" in three places.
class WhatsAppLinks {
  WhatsAppLinks._();

  /// Normalizes any entered form (10 digits, +91-prefixed, 0-prefixed
  /// landline style) to the bare 10-digit domestic number.
  static String normalize(String input) {
    var digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    } else if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return digits;
  }

  /// chat.whatsapp.com style link for [phone] in any common Indian format.
  static Uri chat(String phone, {String? message}) {
    final digits = normalize(phone);
    final text = (message == null || message.isEmpty)
        ? ''
        : '?text=${Uri.encodeComponent(message)}';
    return Uri.parse('https://wa.me/91$digits$text');
  }
}
