/// WhatsApp deep links. India country code (+91) assumed — phone numbers are
/// validated as 10-digit domestic numbers app-wide, so prefixing the digits
/// with the country code is always correct; the links just used to hardcode
/// the "91" in three places.
class WhatsAppLinks {
  WhatsAppLinks._();

  /// chat.whatsapp.com style link for [tenDigitPhone] (digits only, no +91).
  static Uri chat(String tenDigitPhone, {String? message}) {
    final digits = tenDigitPhone.replaceAll(RegExp(r'\D'), '');
    final text = (message == null || message.isEmpty)
        ? ''
        : '?text=${Uri.encodeComponent(message)}';
    return Uri.parse('https://wa.me/91$digits$text');
  }
}
