import 'package:flutter/material.dart';

import '../../shared/widgets/status_chip.dart';

/// One lifecycle for every document the sales side produces.
///
/// This exists because the vocabulary was previously written down twice —
/// `StatusChip.doc` and a private `_statusText` / `_statusKindFor` pair in the
/// sales list — and the two had already drifted: `converted` fell through to a
/// grey chip in one and a blue badge in the other. A new status added to one
/// map was invisible in the other, and the drift only surfaced on screen.
///
/// **The vocabulary is scoped by document type, and deliberately so.** An
/// invoice is not "accepted" — that word means nothing for a bill you have
/// issued and expect to be paid. It is a quotation word, and putting it in a
/// shared list only invites it to be shown on a document where it means
/// nothing. So each doc type gets its own set of states, and [of] resolves
/// against that set rather than against every state ever defined.
enum DocumentStatus {
  /// Written but not issued. The only state that is genuinely a draft —
  /// every saved invoice is 'confirmed'.
  draft('Draft'),

  /// Issued and awaiting whatever comes next. What an invoice is.
  confirmed('Confirmed'),

  /// Handed over.
  delivered('Delivered'),

  /// A quotation or order that has gone out and is awaiting a reply.
  sent('Sent'),

  /// A quotation the customer took. The one outcome worth a report.
  accepted('Accepted'),

  /// A quotation the customer turned down. An outcome, not an error.
  rejected('Rejected'),

  /// Past its valid-till. Computed, never stored — see [isExpired].
  expired('Expired'),

  /// Voided. Money stops chasing it.
  cancelled('Cancelled'),

  /// **Legacy.** Pre-v9 rows where conversion overwrote `status` outright.
  ///
  /// Kept, and deliberately not migrated: the whole reason v9 added
  /// `convertedToInvoiceId` is that the old flag never recorded *which*
  /// invoice the document became. There is nothing to back-fill it from, so
  /// rewriting those rows to `accepted` would re-enable the convert action on
  /// documents that have genuinely already been invoiced — a quotation that
  /// could be converted a second time is worse than one that reads oddly.
  /// They display as "Converted" and cannot be converted again, exactly as
  /// they behaved before.
  convertedLegacy('Converted');

  const DocumentStatus(this.label);

  /// The word shown to the operator.
  final String label;

  /// What a pre-v9 converted row stores in `status`.
  ///
  /// A constant rather than [convertedLegacy.name], which is
  /// `'convertedLegacy'` — the enum value was renamed to say what it is, and
  /// reading the old column through `.name` silently matches nothing. That
  /// failure is invisible: every check returns false and the row just carries
  /// on behaving as if it had never been converted.
  static const legacyConvertedValue = 'converted';

  /// The states a document of [docType] can actually be in.
  ///
  /// Invoices are money owed, so a lifecycle of "accepted" would be nonsense
  /// on them. Quotations and orders are offers awaiting an answer, which is
  /// where the interesting states live.
  static Set<DocumentStatus> forDocType(String docType) => switch (docType) {
    // `confirmed` is in here because it is the *stored default* for every
    // saved document, whatever its type — the editor writes it
    // unconditionally. A quotation that arrives carrying it is a freshly
    // issued offer awaiting an answer, not something in an unknown state,
    // so excluding it would leave a quotation with no legal moves at all.
    'quotation' || 'sales_order' => {
      DocumentStatus.draft,
      DocumentStatus.confirmed,
      DocumentStatus.sent,
      DocumentStatus.accepted,
      DocumentStatus.rejected,
      DocumentStatus.expired,
      DocumentStatus.cancelled,
      DocumentStatus.convertedLegacy,
    },
    _ => {
      DocumentStatus.draft,
      DocumentStatus.confirmed,
      DocumentStatus.delivered,
      DocumentStatus.cancelled,
    },
  };

  /// Resolves a stored string to a state valid for [docType].
  ///
  /// Never throws and never returns null: a status this build has never heard
  /// of, or one that is real but meaningless for this document type, both fall
  /// back to [confirmed]. A document must always be able to name itself — a
  /// chip that throws on an unexpected value takes the whole list down with it.
  static DocumentStatus of(String? raw, String docType) {
    if (raw == legacyConvertedValue) return DocumentStatus.convertedLegacy;
    for (final status in forDocType(docType)) {
      if (status.name == raw) return status;
    }
    return DocumentStatus.confirmed;
  }

  /// Whether the document's valid-till has passed.
  ///
  /// Derived, not stored, because the editor already has a "Valid till" field
  /// and a second copy in a column is one more thing that can disagree with it.
  /// A quotation nobody answered simply stops being an open offer at some
  /// point, and nothing has to be written for that to be true.
  static bool isExpired({
    required String status,
    required String docType,
    required DateTime? validTill,
    DateTime? now,
  }) {
    // Only offers expire. An invoice's due date passing makes it overdue, not
    // expired — the document itself is unchanged, the money is late.
    if (docType != 'quotation' && docType != 'sales_order') return false;
    if (status == DocumentStatus.legacyConvertedValue) return false;
    if (status == DocumentStatus.accepted.name) return false;
    if (status == DocumentStatus.rejected.name) return false;
    if (status == DocumentStatus.cancelled.name) return false;
    final till = validTill;
    if (till == null) return false;
    // End of the named day, not its start: a quotation valid "till" the 10th
    // is valid on the 10th.
    final endOfDay = DateTime(till.year, till.month, till.day, 23, 59, 59);
    return endOfDay.isBefore(now ?? DateTime.now());
  }

  /// The chip colour.
  ///
  /// `accepted` and `confirmed` share the green of "this is going well" but
  /// not the same label, so a reader can tell an answered quotation from an
  /// issued invoice at a glance.
  ChipKind get kind => switch (this) {
    DocumentStatus.draft => ChipKind.neutral,
    DocumentStatus.confirmed => ChipKind.success,
    DocumentStatus.delivered => ChipKind.info,
    DocumentStatus.sent => ChipKind.info,
    DocumentStatus.accepted => ChipKind.success,
    DocumentStatus.rejected => ChipKind.neutral,
    DocumentStatus.expired => ChipKind.warning,
    DocumentStatus.cancelled => ChipKind.danger,
    DocumentStatus.convertedLegacy => ChipKind.info,
  };

  /// The chip for this state.
  Widget chip() => StatusChip(label: label, kind: kind);

  /// The states an operator may move a document *into* from [from].
  ///
  /// Returning them as a list rather than letting the UI hardcode buttons is
  /// what keeps a quotation's actions in step with its vocabulary.
  List<DocumentStatus> transitionsFrom(DocumentStatus from, String docType) {
    final allowed = forDocType(docType);
    List<DocumentStatus> candidates;
    switch (from) {
      case DocumentStatus.convertedLegacy:
        // Already invoiced. Nothing moves it — the one state with no exits.
        return const [];
      case DocumentStatus.draft:
        candidates = const [DocumentStatus.sent, DocumentStatus.cancelled];
      case DocumentStatus.sent:
        candidates = const [
          DocumentStatus.accepted,
          DocumentStatus.rejected,
          DocumentStatus.cancelled,
        ];
      // An answered quotation is a record of what was agreed. Cancelling it
      // would be inventing a fifth answer.
      case DocumentStatus.accepted:
      case DocumentStatus.rejected:
        candidates = const [];
      // Expiry is derived, so it is never a target — but a lapsed offer can
      // still be withdrawn, and a fresh quote is a new document.
      case DocumentStatus.expired:
        candidates = const [DocumentStatus.cancelled];
      case DocumentStatus.confirmed:
        // The same stored value means different things. On an invoice it is
        // simply "issued" and only cancellation follows. On a quotation it is
        // the default a fresh offer is saved with, so it is *open* — and an
        // open offer can be sent, or answered outright.
        candidates = forDocType(docType).contains(DocumentStatus.sent)
            ? const [
                DocumentStatus.sent,
                DocumentStatus.accepted,
                DocumentStatus.rejected,
                DocumentStatus.cancelled,
              ]
            : const [DocumentStatus.cancelled];
      case DocumentStatus.delivered:
      case DocumentStatus.cancelled:
        candidates = const [DocumentStatus.cancelled];
    }
    return candidates.where(allowed.contains).toList();
  }
}
