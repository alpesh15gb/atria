import 'package:uuid/uuid.dart';

/// ID generation. Uses time-ordered UUIDs so locally created records sort
/// naturally and remain collision-free across devices before sync.
class IdUtils {
  IdUtils._();

  static const _uuid = Uuid();

  static String newId() => _uuid.v7();

  static String newCode(String prefix) {
    final now = DateTime.now();
    final ms = now.millisecondsSinceEpoch;
    // Base-36 of the millisecond timestamp gives a short, sortable, unique
    // suffix for a financial year.
    return '$prefix${ms.toRadixString(36).toUpperCase()}';
  }
}
