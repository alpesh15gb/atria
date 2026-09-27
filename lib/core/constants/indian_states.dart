/// Indian states and UTs with the GSTIN state code (first two digits of GSTIN).
class IndianState {
  final String code; // TIN / GSTIN state code
  final String name;

  const IndianState({required this.code, required this.name});
}

class IndianStates {
  IndianStates._();

  static const List<IndianState> all = [
    IndianState(code: '01', name: 'Jammu and Kashmir'),
    IndianState(code: '02', name: 'Himachal Pradesh'),
    IndianState(code: '03', name: 'Punjab'),
    IndianState(code: '04', name: 'Chandigarh'),
    IndianState(code: '05', name: 'Uttarakhand'),
    IndianState(code: '06', name: 'Haryana'),
    IndianState(code: '07', name: 'Delhi'),
    IndianState(code: '08', name: 'Rajasthan'),
    IndianState(code: '09', name: 'Uttar Pradesh'),
    IndianState(code: '10', name: 'Bihar'),
    IndianState(code: '11', name: 'Sikkim'),
    IndianState(code: '12', name: 'Arunachal Pradesh'),
    IndianState(code: '13', name: 'Nagaland'),
    IndianState(code: '14', name: 'Manipur'),
    IndianState(code: '15', name: 'Mizoram'),
    IndianState(code: '16', name: 'Tripura'),
    IndianState(code: '17', name: 'Meghalaya'),
    IndianState(code: '18', name: 'Assam'),
    IndianState(code: '19', name: 'West Bengal'),
    IndianState(code: '20', name: 'Jharkhand'),
    IndianState(code: '21', name: 'Odisha'),
    IndianState(code: '22', name: 'Chhattisgarh'),
    IndianState(code: '23', name: 'Madhya Pradesh'),
    IndianState(code: '24', name: 'Gujarat'),
    IndianState(code: '25', name: 'Daman and Diu'),
    IndianState(code: '26', name: 'Dadra and Nagar Haveli and Daman and Diu'),
    IndianState(code: '27', name: 'Maharashtra'),
    IndianState(code: '28', name: 'Andhra Pradesh (Old)'),
    IndianState(code: '29', name: 'Karnataka'),
    IndianState(code: '30', name: 'Goa'),
    IndianState(code: '31', name: 'Lakshadweep'),
    IndianState(code: '32', name: 'Kerala'),
    IndianState(code: '33', name: 'Tamil Nadu'),
    IndianState(code: '34', name: 'Puducherry'),
    IndianState(code: '35', name: 'Andaman and Nicobar Islands'),
    IndianState(code: '36', name: 'Telangana'),
    IndianState(code: '37', name: 'Andhra Pradesh'),
    IndianState(code: '38', name: 'Ladakh'),
    IndianState(code: '97', name: 'Other Territory'),
  ];

  /// States treated as Union Territories for CGST/UTGST split.
  static const Set<String> unionTerritoryCodes = {
    '04', // Chandigarh
    '26', // DNH & DD
    '31', // Lakshadweep
    '35', // A&N Islands
    '06', // Haryana? No — Haryana is a state. Kept list to actual UTs below.
  };

  /// Actual UTs that attract CGST + UTGST (instead of CGST + SGST).
  static const Set<String> utgstStates = {
    '04', // Chandigarh
    '26', // Dadra and Nagar Haveli and Daman and Diu
    '31', // Lakshadweep
    '35', // Andaman and Nicobar Islands
  };

  static IndianState? byCode(String? code) {
    if (code == null) return null;
    for (final s in all) {
      if (s.code == code) return s;
    }
    return null;
  }

  static IndianState? byName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final n = name.trim().toLowerCase();
    for (final s in all) {
      if (s.name.toLowerCase() == n) return s;
    }
    return null;
  }

  /// Extracts the 2-digit state code from the first two characters of a GSTIN.
  static String? stateCodeFromGstin(String? gstin) {
    if (gstin == null || gstin.trim().length < 2) return null;
    final c = gstin.trim().substring(0, 2);
    return byCode(c) != null ? c : null;
  }
}
