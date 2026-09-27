/// Measurement units used in Indian trade. Vyapar lets you define custom
/// units; we ship the common ones and allow arbitrary user units too.
class Unit {
  final String id;
  final String symbol;
  final String label;

  const Unit({required this.id, required this.symbol, required this.label});

  static const List<Unit> standard = [
    Unit(id: 'pcs', symbol: 'pcs', label: 'Pieces'),
    Unit(id: 'nos', symbol: 'nos', label: 'Numbers'),
    Unit(id: 'kg', symbol: 'kg', label: 'Kilogram'),
    Unit(id: 'g', symbol: 'g', label: 'Gram'),
    Unit(id: 'l', symbol: 'L', label: 'Litre'),
    Unit(id: 'ml', symbol: 'mL', label: 'Millilitre'),
    Unit(id: 'm', symbol: 'm', label: 'Metre'),
    Unit(id: 'cm', symbol: 'cm', label: 'Centimetre'),
    Unit(id: 'ft', symbol: 'ft', label: 'Feet'),
    Unit(id: 'sqft', symbol: 'sq ft', label: 'Square Feet'),
    Unit(id: 'sqm', symbol: 'sq m', label: 'Square Metre'),
    Unit(id: 'box', symbol: 'box', label: 'Box'),
    Unit(id: 'pkt', symbol: 'pkt', label: 'Packet'),
    Unit(id: 'set', symbol: 'set', label: 'Set'),
    Unit(id: 'dozen', symbol: 'dz', label: 'Dozen'),
    Unit(id: 'pair', symbol: 'pair', label: 'Pair'),
    Unit(id: 'roll', symbol: 'roll', label: 'Roll'),
    Unit(id: 'bag', symbol: 'bag', label: 'Bag'),
    Unit(id: 'bottle', symbol: 'btl', label: 'Bottle'),
    Unit(id: 'hour', symbol: 'hr', label: 'Hour'),
    Unit(id: 'day', symbol: 'day', label: 'Day'),
    Unit(id: 'month', symbol: 'mo', label: 'Month'),
    Unit(id: 'service', symbol: 'svc', label: 'Service'),
  ];

  static Unit? byId(String? id) {
    if (id == null) return null;
    for (final u in standard) {
      if (u.id == id) return u;
    }
    return null;
  }

  static String symbolOf(String? id) => byId(id)?.symbol ?? id ?? '';
}
