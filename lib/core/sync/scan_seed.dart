import '../database/app_database.dart';

/// A reviewed scan, carried from the bill-scan screen into the purchase
/// editor as the seed of a NEW bill.
///
/// A class of its own rather than passing the raw [ScannedBill] through: the
/// editor needs the *survived* values (what the person confirmed or corrected
/// on the review screen), plus a supplier-matching rule that needs the party
/// list — which only the editor has when it finishes loading. Everything here
/// remains editable in the editor; this is pre-fill, not a decision.
class ScannedBillSeed {
  const ScannedBillSeed({
    required this.lines,
    this.supplierName,
    this.supplierGstin,
    this.supplierPhone,
    this.supplierAddress,
    this.invoiceNumber,
    this.billDate,
    this.dueDate,
    this.placeOfSupply,
    this.shippingCharge = 0,
    this.otherCharges = 0,
  });

  final String? supplierName;
  final String? supplierGstin;
  final String? supplierPhone;
  final String? supplierAddress;
  final String? invoiceNumber;
  final DateTime? billDate;
  final DateTime? dueDate;

  /// Two-letter state code the review confirmed, or derived from the GSTIN.
  final String? placeOfSupply;

  /// Confirmed lines, in bill order.
  final List<ScannedLineSeed> lines;
  final double shippingCharge;
  final double otherCharges;

  /// Finds the supplier this bill belongs to, GSTIN first (the reliable
  /// identifier two suppliers can share a name but never a GSTIN), then by
  /// case-insensitive name. Null when nothing matches, which the editor
  /// answers by creating the supplier.
  PartyEntity? matchSupplier(List<PartyEntity> suppliers) {
    final gstin = supplierGstin?.trim().toUpperCase();
    if (gstin != null && gstin.isNotEmpty) {
      for (final supplier in suppliers) {
        if (supplier.gstin?.trim().toUpperCase() == gstin) return supplier;
      }
    }
    final name = supplierName?.trim().toLowerCase();
    if (name != null && name.isNotEmpty) {
      for (final supplier in suppliers) {
        if (supplier.name.trim().toLowerCase() == name) return supplier;
      }
    }
    return null;
  }
}

/// One confirmed line.
class ScannedLineSeed {
  const ScannedLineSeed({
    required this.name,
    required this.quantity,
    required this.rate,
    required this.gstRate,
    required this.cessRate,
    this.hsn,
    this.unit = 'pcs',
    this.discountPercent = 0,
  });

  final String name;
  final String? hsn;
  final double quantity;
  final double rate;
  final String unit;
  final double discountPercent;
  final double gstRate;
  final double cessRate;
}
