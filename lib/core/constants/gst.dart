/// Standard GST rates in India and commonly used HSN/SAC codes.
class GstRate {
  final double rate; // 0, 0.25, 3, 5, 12, 18, 28
  final String label;

  const GstRate._(this.rate, this.label);

  static const GstRate zero = GstRate._(0, '0%');
  static const GstRate exempt = GstRate._(0, 'Exempt');
  static const GstRate quarter = GstRate._(0.25, '0.25%');
  static const GstRate three = GstRate._(3, '3%');
  static const GstRate five = GstRate._(5, '5%');
  static const GstRate twelve = GstRate._(12, '12%');
  static const GstRate eighteen = GstRate._(18, '18%');
  static const GstRate twentyEight = GstRate._(28, '28%');

  static const List<GstRate> standard = [
    zero,
    quarter,
    three,
    five,
    twelve,
    eighteen,
    twentyEight,
  ];

  static GstRate? fromDouble(double? value) {
    if (value == null) return null;
    // Compare in hundredths: raw double equality returned null for rates
    // that arrived through real arithmetic (18.000000000000004 from a
    // percentage computation), silently dropping them to "other".
    final cents = (value * 100).round();
    for (final r in standard) {
      if ((r.rate * 100).round() == cents) return r;
    }
    return null;
  }
}

/// Frequently used HSN (goods) and SAC (services) codes for quick selection.
class HsnCode {
  final String code;
  final String description;
  final double gstRate;

  const HsnCode(this.code, this.description, this.gstRate);
}

class HsnCodes {
  HsnCodes._();

  static const List<HsnCode> common = [
    // Goods
    HsnCode('0101', 'Live horses, asses, mules, hinnies', 0),
    HsnCode('0201', 'Meat of bovine animals, fresh or chilled', 0),
    HsnCode('0301', 'Live fish', 0),
    HsnCode('0401', 'Milk and cream, not concentrated', 0),
    HsnCode('0701', 'Potatoes, fresh or chilled', 0),
    HsnCode('0801', 'Coconuts, Brazil nuts and cashew nuts', 0),
    HsnCode('0901', 'Coffee, whether or not roasted', 5),
    HsnCode('1001', 'Wheat and meslin', 0),
    HsnCode('1006', 'Rice', 0),
    HsnCode('1101', 'Wheat or meslin flour', 0),
    HsnCode('1207', 'Other oil seeds and oleaginous fruits', 0),
    HsnCode('1511', 'Palm oil and its fractions', 5),
    HsnCode('1701', 'Cane or beet sugar and solid sucrose', 5),
    HsnCode('1806', 'Chocolate and other food preparations of cocoa', 18),
    HsnCode('1905', 'Bread, pastry, cakes, biscuits', 18),
    HsnCode('2101', 'Extracts, essences of coffee, tea or mat', 18),
    HsnCode('2201', 'Waters, incl. natural or artificial mineral waters', 18),
    HsnCode('2202', 'Beverages containing added sugar', 28),
    HsnCode('2523', 'Portland cement, aluminous cement', 18),
    HsnCode('3004', 'Pharmaceutical products, packaged for retail sale', 12),
    HsnCode('3208', 'Paints and varnishes', 18),
    HsnCode('3303', 'Perfumes and toilet waters', 28),
    HsnCode('3304', 'Beauty or make-up preparations', 28),
    HsnCode('3401', 'Soap; organic surface-active products', 18),
    HsnCode('3923', 'Articles for the conveyance or packing of plastics', 18),
    HsnCode('3926', 'Other articles of plastics', 18),
    HsnCode('4011', 'New pneumatic tyres of rubber', 28),
    HsnCode('4202', 'Trunks, suitcases, vanity cases, handbags', 28),
    HsnCode('4303', 'Articles of apparel, of furskin', 12),
    HsnCode('4802', 'Uncoated paper, in rolls or sheets', 12),
    HsnCode('4818', 'Toilet paper, paper towels, napkins', 12),
    HsnCode('4820', 'Registers, account books, note books', 18),
    HsnCode('6109', 'T-shirts, singlets and other vests, knitted', 5),
    HsnCode('6203', 'Men\'s or boys\' suits, ensembles, jackets', 12),
    HsnCode('6204', 'Women\'s or girls\' suits, ensembles', 12),
    HsnCode('6403', 'Footwear with uppers of leather', 18),
    HsnCode('7009', 'Glass mirrors', 18),
    HsnCode('7308', 'Structures of iron or steel', 18),
    HsnCode('7318', 'Screws, bolts, nuts, washers of iron or steel', 18),
    HsnCode('7321', 'Stoves, ranges, cookers of iron or steel', 18),
    HsnCode('7409', 'Plates, sheets and strip, of copper', 18),
    HsnCode('8413', 'Pumps for liquids, liquid elevators', 18),
    HsnCode('8414', 'Air or vacuum pumps, compressors', 18),
    HsnCode('8418', 'Refrigerators, freezers', 18),
    HsnCode('8421', 'Centrifuges; filtering or purifying machinery', 18),
    HsnCode('8428', 'Other lifting, handling, loading machinery', 18),
    HsnCode('8431', 'Parts suitable for use with machinery', 18),
    HsnCode('8443', 'Printing machinery; printers, copiers', 18),
    HsnCode('8461', 'Machine tools for turning, drilling, milling', 18),
    HsnCode('8471', 'Automatic data processing machines (computers)', 18),
    HsnCode('8473', 'Parts and accessories of typewriters/DP machines', 18),
    HsnCode('8501', 'Electric motors and generators', 18),
    HsnCode('8504', 'Electrical transformers, static converters', 18),
    HsnCode('8508', 'Vacuum cleaners', 28),
    HsnCode('8516', 'Electric water, space, soil heaters', 18),
    HsnCode('8517', 'Telephone sets, smartphones; routers', 18),
    HsnCode('8523', 'Discs, tapes, solid-state storage (USB/SSD)', 18),
    HsnCode('8528', 'Monitors and projectors, television', 18),
    HsnCode('8531', 'Electric signalling, safety equipment', 18),
    HsnCode('8536', 'Electrical apparatus for switching circuits', 18),
    HsnCode('8542', 'Electronic integrated circuits', 18),
    HsnCode('8543', 'Electrical machines with individual functions', 18),
    HsnCode('8708', 'Parts and accessories of motor vehicles', 28),
    HsnCode('8714', 'Parts and accessories of cycles', 28),
    HsnCode('9001', 'Optical fibres, lenses, prisms', 18),
    HsnCode('9018', 'Instruments used in medical science', 12),
    HsnCode('9025', 'Thermometers, pyrometers, barometers', 18),
    HsnCode('9031', 'Measuring or checking instruments', 18),
    HsnCode('9401', 'Seats (other than of motor vehicles)', 18),
    HsnCode('9403', 'Other furniture and parts thereof', 18),
    HsnCode('9405', 'Lamps and lighting fittings', 18),
    HsnCode('9619', 'Sanitary towels, tampons, napkins', 12),
    // Services (SAC)
    HsnCode('998311', 'Licensing services for the right to use software', 18),
    HsnCode('998313', 'IT software installation and implementation', 18),
    HsnCode('998314', 'IT software support, maintenance', 18),
    HsnCode('998315', 'Application service provision (SaaS)', 18),
    HsnCode('998321', 'Web-hosting services', 18),
    HsnCode('998322', 'Web-page design and hosting services', 18),
    HsnCode('998323', 'Network and data processing services', 18),
    HsnCode('998361', 'Advertising services', 18),
    HsnCode('998362', 'Sale of advertising space/time', 18),
    HsnCode('998365', 'Direct marketing services', 18),
    HsnCode('998386', 'Transport of goods by road (GTA)', 5),
    HsnCode('998387', 'Transport support services', 18),
    HsnCode('998391', 'Storage and warehousing services', 18),
    HsnCode('9984', 'Telecommunications, broadcasting', 18),
    HsnCode('9985', 'Financial and insurance services', 18),
    HsnCode('9986', 'Real estate services', 18),
    HsnCode('9987', 'Legal, accounting, bookkeeping services', 18),
    HsnCode('9988', 'Business and management consultancy', 18),
    HsnCode('9989', 'Architectural, engineering services', 18),
    HsnCode('9973', 'Leasing or rental services', 18),
    HsnCode('9963', 'Accommodation, food and beverage services', 5),
    HsnCode('9964', 'Passenger transport services', 5),
    HsnCode('9965', 'Goods transport agency services', 5),
    HsnCode('9966', 'Railway transport services', 5),
    HsnCode('9967', 'Transport of goods by air', 5),
    HsnCode('9971', 'Construction services', 18),
    HsnCode('9981', 'Support services to businesses', 18),
    HsnCode('9997', 'Other professional, technical services', 18),
    HsnCode('9998', 'Other amusement, recreation services', 18),
  ];

  static HsnCode? findByCode(String? code) {
    if (code == null || code.trim().isEmpty) return null;
    final c = code.trim().toUpperCase();
    for (final h in common) {
      if (h.code == c) return h;
    }
    return null;
  }

  static List<HsnCode> search(String query, {int limit = 12}) {
    if (query.trim().isEmpty) return const [];
    final q = query.trim().toLowerCase();
    final results = <HsnCode>[];
    for (final h in common) {
      if (h.code.contains(q) || h.description.toLowerCase().contains(q)) {
        results.add(h);
        if (results.length >= limit) break;
      }
    }
    return results;
  }
}
