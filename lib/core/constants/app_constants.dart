/// App-wide constants.
class AppConstants {
  AppConstants._();

  static const String appName = 'Atria';
  static const String appTagline = 'Vyapar, simplified.';
  static const String appVersion = '1.0.0';
  static const String supportEmail = 'hello@atria.app';

  static const String currencySymbol = '₹';
  static const String currencyCode = 'INR';

  /// Invoice numbering default prefix.
  static const String defaultInvoicePrefix = 'INV';
  static const String defaultQuotationPrefix = 'QT';
  static const String defaultSalesOrderPrefix = 'SO';
  static const String defaultPurchasePrefix = 'PUR';
  static const String defaultPaymentInPrefix = 'RCPT';
  static const String defaultPaymentOutPrefix = 'PMT';
  static const String defaultExpensePrefix = 'EXP';

  /// Pagination.
  static const int defaultPageSize = 30;

  /// Low-stock threshold default.
  static const double defaultLowStockQty = 0;

  /// Backup file extension.
  static const String backupFileExt = '.atriabak';

  /// Sync queue batch size.
  static const int syncBatchSize = 200;
}

/// Document/business transaction types used across the app and sync layer.
enum DocType {
  salesInvoice('Sales Invoice'),
  quotation('Quotation'),
  salesOrder('Sales Order'),
  deliveryNote('Delivery Note'),
  purchaseBill('Purchase Bill'),
  purchaseOrder('Purchase Order'),
  paymentIn('Payment In'),
  paymentOut('Payment Out'),
  expense('Expense'),
  income('Other Income'),
  debitNote('Debit Note'),
  creditNote('Credit Note');

  final String label;
  const DocType(this.label);
}
