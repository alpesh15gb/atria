import '../database/app_database.dart';
import '../engine/gst_engine.dart';

/// Registration belongs to the business, never to its customer or device.
extension FirmGstRegistration on FirmEntity {
  bool get isGstRegistered => (gstin ?? '').trim().isNotEmpty;
}

TaxLine withoutGst(TaxLine line) =>
    line.copyWith(gstRate: 0, cessRate: 0, taxMode: TaxMode.exclusive);

bool isGstReport(String id) =>
    id.startsWith('gstr') || id == 'gst_rate_report' || id == 'gst_rate';
