/// Payment/transaction modes used across receipts, payments, expenses.
class PaymentMode {
  final String id;
  final String label;
  final String group; // cash | bank | upi | cheque | card | other

  const PaymentMode({
    required this.id,
    required this.label,
    required this.group,
  });

  static const PaymentMode cash = PaymentMode(
      id: 'cash', label: 'Cash', group: 'cash');
  static const PaymentMode upi =
      PaymentMode(id: 'upi', label: 'UPI', group: 'upi');
  static const PaymentMode bankTransfer = PaymentMode(
      id: 'bank_transfer', label: 'Bank Transfer (NEFT/RTGS/IMPS)', group: 'bank');
  static const PaymentMode cheque =
      PaymentMode(id: 'cheque', label: 'Cheque', group: 'cheque');
  static const PaymentMode card =
      PaymentMode(id: 'card', label: 'Debit/Credit Card', group: 'card');
  static const PaymentMode other =
      PaymentMode(id: 'other', label: 'Other', group: 'other');

  static const List<PaymentMode> all = [
    cash,
    upi,
    bankTransfer,
    cheque,
    card,
    other,
  ];

  static PaymentMode? byId(String? id) {
    if (id == null) return null;
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }
}

/// Common expense categories (Vyapar / My Bill Book style).
class ExpenseCategory {
  final String id;
  final String label;

  const ExpenseCategory({required this.id, required this.label});

  static const List<ExpenseCategory> all = [
    ExpenseCategory(id: 'rent', label: 'Rent'),
    ExpenseCategory(id: 'salary', label: 'Salaries & Wages'),
    ExpenseCategory(id: 'electricity', label: 'Electricity'),
    ExpenseCategory(id: 'water', label: 'Water'),
    ExpenseCategory(id: 'internet', label: 'Internet & Telephone'),
    ExpenseCategory(id: 'transport', label: 'Transport & Fuel'),
    ExpenseCategory(id: 'marketing', label: 'Marketing & Advertising'),
    ExpenseCategory(id: 'office', label: 'Office Supplies'),
    ExpenseCategory(id: 'maintenance', label: 'Repairs & Maintenance'),
    ExpenseCategory(id: 'bank_charges', label: 'Bank Charges'),
    ExpenseCategory(id: 'professional', label: 'Professional Fees'),
    ExpenseCategory(id: 'tax', label: 'Taxes & Duties'),
    ExpenseCategory(id: 'insurance', label: 'Insurance'),
    ExpenseCategory(id: 'misc', label: 'Miscellaneous'),
  ];

  static ExpenseCategory? byId(String? id) {
    if (id == null) return null;
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// Income categories (other than sales).
class IncomeCategory {
  final String id;
  final String label;

  const IncomeCategory({required this.id, required this.label});

  static const List<IncomeCategory> all = [
    IncomeCategory(id: 'interest', label: 'Interest Received'),
    IncomeCategory(id: 'discount', label: 'Discount Received'),
    IncomeCategory(id: 'commission', label: 'Commission Received'),
    IncomeCategory(id: 'asset_sale', label: 'Sale of Asset'),
    IncomeCategory(id: 'refund', label: 'Refund / Rebate'),
    IncomeCategory(id: 'other', label: 'Other Income'),
  ];

  static IncomeCategory? byId(String? id) {
    if (id == null) return null;
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
