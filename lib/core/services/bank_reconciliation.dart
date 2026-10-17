import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:pdfrx/pdfrx.dart';

import '../database/app_database.dart';
import '../database/repositories/repository_extensions.dart';

class BankStatementRow {
  const BankStatementRow(
    this.date,
    this.description,
    this.amount,
    this.reference,
  );
  final DateTime date;
  final String description, reference;

  /// Credit is positive, debit is negative.
  final double amount;
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          '${date.toIso8601String().substring(0, 10)}|${amount.toStringAsFixed(2)}|${reference.trim().isEmpty ? description.trim().toUpperCase() : reference.trim().toUpperCase()}',
        ),
      )
      .toString();
}

String bankNameKey(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\b(m/s|pvt|private|ltd|limited|the)\b'), ' ')
    .replaceAll(RegExp('[^a-z0-9]+'), ' ')
    .trim();

DateTime? bankDate(String value) {
  final iso = DateTime.tryParse(value.trim());
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final m = RegExp(r'^(\d{1,2})[-/ ]([A-Za-z]{3}|\d{1,2})[-/ ](\d{2}|\d{4})$')
      .firstMatch(value.trim());
  if (m == null) return null;
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final month = int.tryParse(m[2]!) ?? months.indexOf(m[2]!.toLowerCase()) + 1;
  var year = int.parse(m[3]!);
  if (year < 100) year += 2000;
  final day = int.parse(m[1]!);
  final result = DateTime(year, month, day);
  return result.month == month && result.day == day ? result : null;
}

/// RFC-4180 rows, including quoted commas/newlines and escaped quotes.
List<List<String>> bankCsvRows(String input) {
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (c == '"') {
      if (quoted && i + 1 < input.length && input[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      row.add(field.toString());
      field = StringBuffer();
    } else if ((c == '\n' || c == '\r') && !quoted) {
      if (c == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      row.add(field.toString());
      rows.add(row);
      row = [];
      field = StringBuffer();
    } else {
      field.write(c);
    }
  }
  if (quoted) throw const FormatException('Unclosed CSV quote.');
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

List<BankStatementRow> parseBankCsv(String csv) {
  final rows = bankCsvRows(csv.replaceFirst('\uFEFF', ''));
  Map<String, int>? columns;
  final result = <BankStatementRow>[];
  for (final row in rows) {
    if (columns == null) {
      final c = <String, int>{};
      for (var i = 0; i < row.length; i++) {
        final h = row[i].toLowerCase().replaceAll(RegExp('[^a-z]'), '');
        if (['date', 'transactiondate', 'txndate', 'valuedate'].contains(h)) {
          c.putIfAbsent('date', () => i);
        }
        if ([
          'description',
          'narration',
          'particulars',
          'transactionremarks',
          'remarks',
        ].contains(h)) {
          c['description'] = i;
        }
        if (h.startsWith('debit') || h.startsWith('withdrawal')) c['debit'] = i;
        if (h.startsWith('credit') || h.startsWith('deposit')) c['credit'] = i;
        if ([
          'reference',
          'refno',
          'referenceno',
          'chequeno',
          'chequerefno',
          'utr',
          'chqrefno',
        ].contains(h)) {
          c['reference'] = i;
        }
      }
      if (c.containsKey('date') &&
          c.containsKey('description') &&
          (c.containsKey('credit') || c.containsKey('debit'))) {
        columns = c;
      }
      continue;
    }
    String get(String key) =>
        columns![key] == null || columns[key]! >= row.length
        ? ''
        : row[columns[key]!].trim();
    double amount(String key) {
      final s = get(key).replaceAll(RegExp(r'[,₹\s]'), '');
      if (s.isEmpty || s == '-') return 0;
      final value = double.tryParse(s);
      if (value == null || !value.isFinite) {
        throw FormatException('Invalid $key amount: ${get(key)}');
      }
      return value;
    }

    final date = bankDate(get('date'));
    if (date == null) {
      if (get('date').isNotEmpty && get('description').isNotEmpty) {
        throw FormatException('Unrecognised bank date: ${get('date')}');
      }
      continue;
    }
    final debit = amount('debit'), credit = amount('credit');
    if (debit < 0 || credit < 0 || debit > 0 && credit > 0) {
      throw const FormatException(
        'Each bank row needs one positive debit or credit.',
      );
    }
    if (debit + credit > 0) {
      result.add(
        BankStatementRow(
          date,
          get('description'),
          credit - debit,
          get('reference'),
        ),
      );
    }
  }
  if (columns == null || result.isEmpty) {
    throw const FormatException(
      'No transactions found. CSV needs Date, Narration/Description, Debit and Credit columns.',
    );
  }
  return result;
}

/// PDF extraction is local. The user maps extracted rows to debit/credit;
/// guessing column direction from PDF text could mark the wrong invoice paid.
Future<String> extractBankPdf(Uint8List bytes) async {
  await pdfrxFlutterInitialize();
  final doc = await PdfDocument.openData(bytes);
  try {
    final text = StringBuffer();
    for (final page in doc.pages) {
      text.writeln((await page.loadStructuredText()).fullText);
    }
    if (text.toString().trim().isEmpty) {
      throw const FormatException(
        'This PDF is scanned or has no text layer. Export CSV from your bank or use OCR first.',
      );
    }
    return text.toString();
  } finally {
    await doc.dispose();
  }
}

class BankCandidate {
  const BankCandidate({
    required this.id,
    required this.number,
    required this.party,
    required this.partyId,
    required this.balance,
    required this.date,
    required this.incoming,
    this.score = 0,
    this.reason = '',
  });
  final String id, number, party;
  final String? partyId;
  final double balance;
  final DateTime date;
  final bool incoming;
  final int score;
  final String reason;
}

class BankReconciler {
  BankReconciler(this.db, this.firmId);
  final AppDatabase db;
  final String firmId;
  Future<List<BankCandidate>> documents() async => [
    for (final d in await db.salesRepositoryFor(firmId).list(limit: 100000))
      if (d.status != 'cancelled' && d.balanceDue > .005)
        BankCandidate(
          id: d.id,
          number: d.number,
          party: d.partyName ?? '',
          partyId: d.partyId,
          balance: d.balanceDue,
          date: d.invoiceDate,
          incoming: true,
        ),
    for (final d in await db.purchaseRepositoryFor(firmId).list(limit: 100000))
      if (d.status != 'cancelled' && d.balanceDue > .005)
        BankCandidate(
          id: d.id,
          number: d.supplierInvoiceNumber ?? d.number,
          party: d.partyName ?? '',
          partyId: d.partyId,
          balance: d.balanceDue,
          date: d.billDate,
          incoming: false,
        ),
  ];
  List<BankCandidate> suggest(
    BankStatementRow row,
    List<BankCandidate> docs, {
    Map<String, String> aliases = const {},
  }) {
    final description = bankNameKey(row.description);
    final ranked = <BankCandidate>[];
    for (final d in docs.where((d) => d.incoming == (row.amount > 0))) {
      var score = 0;
      final reasons = <String>[];
      final name = bankNameKey(d.party);
      if (name.length >= 4 && description.contains(name)) {
        score += 50;
        reasons.add('party name');
      } else if (name
          .split(' ')
          .any((w) => w.length >= 5 && description.split(' ').contains(w))) {
        score += 30;
        reasons.add('name fragment');
      }
      if (aliases.entries.any(
        (a) =>
            a.value == d.partyId &&
            RegExp('(^| )${RegExp.escape(a.key)}( |\$)').hasMatch(description),
      )) {
        score += 60;
        reasons.add('confirmed alias');
      }
      if (d.number.length >= 3 &&
          '${row.reference} ${row.description}'.toLowerCase().contains(
            d.number.toLowerCase(),
          )) {
        score += 70;
        reasons.add('invoice reference');
      }
      if ((d.balance - row.amount.abs()).abs() < .01) {
        score += 25;
        reasons.add('exact amount');
      }
      if (row.date.difference(d.date).inDays >= 0 &&
          row.date.difference(d.date).inDays <= 90) {
        score += 5;
      }
      ranked.add(
        BankCandidate(
          id: d.id,
          number: d.number,
          party: d.party,
          partyId: d.partyId,
          balance: d.balance,
          date: d.date,
          incoming: d.incoming,
          score: score,
          reason: reasons.join(', '),
        ),
      );
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }

  /// Atomic and idempotent within this database. Revalidate balances at commit.
  Future<int> confirm(
    Map<BankStatementRow, BankCandidate> selection,
    String accountId,
  ) async {
    return db.transaction(() async {
      var count = 0;
      for (final entry in selection.entries) {
        final row = entry.key, candidate = entry.value;
        final ref = 'BANK:$accountId:${row.fingerprint}';
        final existing =
            await (db.select(db.payments)..where(
                  (p) => p.firmId.equals(firmId) & p.reference.equals(ref),
                ))
                .get();
        if (existing.isNotEmpty) continue;
        final samePayment =
            await (db.select(db.payments)..where(
                  (p) =>
                      p.firmId.equals(firmId) &
                      p.linkedInvoiceId.equals(candidate.id) &
                      p.bankAccountId.equals(accountId) &
                      p.isDeleted.equals(false) &
                      p.date.isBiggerOrEqualValue(row.date) &
                      p.date.isSmallerThanValue(
                        row.date.add(const Duration(days: 1)),
                      ),
                ))
                .get();
        if (samePayment.any(
          (p) => (p.amount - row.amount.abs()).abs() < .005,
        )) {
          throw StateError(
            'A payment with the same account, document, date and amount is already recorded. Review it before importing again.',
          );
        }
        if (candidate.incoming != (row.amount > 0)) {
          throw StateError('Payment direction does not match the document.');
        }
        final sales = db.salesRepositoryFor(firmId),
            purchases = db.purchaseRepositoryFor(firmId);
        final balance = candidate.incoming
            ? (await sales.getById(candidate.id))?.balanceDue
            : (await purchases.getById(candidate.id))?.balanceDue;
        if (balance == null || row.amount.abs() > balance + .005) {
          throw StateError(
            '${candidate.number} has changed or the payment exceeds its balance. Refresh the preview.',
          );
        }
        await db
            .paymentRepositoryFor(firmId)
            .create(
              paymentId:
                  'pay_bank_${sha256.convert(utf8.encode('$firmId|$ref'))}',
              type: candidate.incoming ? 'payment_in' : 'payment_out',
              number: 'BR-${row.fingerprint.substring(0, 12)}',
              partyId: candidate.partyId,
              partyName: candidate.party,
              amount: row.amount.abs(),
              date: row.date,
              mode: 'bank_transfer',
              reference: ref,
              bankAccountId: accountId,
              linkedInvoiceId: candidate.id,
              linkedInvoiceNumber: candidate.number,
              notes: 'Bank reconciliation: ${row.description}',
              onLinked: (id, amount) => candidate.incoming
                  ? sales.applyPayment(
                      invoiceId: id,
                      amount: amount,
                      date: row.date,
                    )
                  : purchases.applyPayment(
                      billId: id,
                      amount: amount,
                      date: row.date,
                    ),
            );
        count++;
      }
      return count;
    });
  }
}
