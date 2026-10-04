import 'dart:convert';
import 'dart:io';

/// What a shop printer is, and how to talk to it.
///
/// Two axes decide everything downstream:
///
/// * [PrinterBrand] picks the command language. TSC printers speak TSPL/TSPL2;
///   Zebra printers speak ZPL II. They are not dialects of each other — a TSPL
///   `BARCODE` command sent to a Zebra prints as literal text — so the brand is
///   a property of the printer, never something the app guesses per label.
/// * [PrinterTransport] picks the wire. A network printer is raw bytes to TCP
///   9100; a USB printer installed with its vendor driver is a Windows print
///   queue that accepts a `RAW` datatype.
///
/// Everything else is geometry the operator can get wrong and correct without
/// touching code: dots per inch, the physical label size, the die-cut gap, and
/// a small calibration offset for printers that sit a millimetre off.

/// The command language a printer understands.
enum PrinterBrand {
  /// TSC — TSPL / TSPL2 (`SIZE`, `TEXT`, `BARCODE`, `PRINT`).
  tsc('TSC', 'TSPL'),

  /// Zebra — ZPL II (`^XA`, `^FO`, `^BC`, `^XZ`).
  zebra('Zebra', 'ZPL II');

  const PrinterBrand(this.label, this.language);

  /// Shown in the picker, e.g. "TSC".
  final String label;

  /// The language name, e.g. "TSPL".
  final String language;

  static PrinterBrand parse(String? value) => values.firstWhere(
        (brand) => brand.name == (value ?? '').toLowerCase(),
        orElse: () => PrinterBrand.tsc,
      );
}

/// What a printer is for.
///
/// The command language follows from this, which is why it is a profile field
/// rather than something the app guesses: a TSC TTP-244 on the counter prints
/// *labels* (TSPL, die-cut, dots) while the receipt printer next to the till
/// prints *receipts* (ESC/POS, a continuous roll, columns of text). Sending one
/// the other's job prints a page of command text, and no amount of retrying
/// fixes it.
///
/// Defaults to [label] for a stored profile that predates this field — every
/// printer configured before receipts existed was a label printer.
enum PrinterKind {
  label('Barcode labels', 'TSPL / ZPL'),
  receipt('Customer receipts', 'ESC/POS');

  // Not `label`: the enum has a value called `label`, and a field with the same
  // name as a static member of its own class is a compile error in Dart.
  const PrinterKind(this.title, this.language);

  final String title;
  final String language;

  static PrinterKind parse(String? value) => values.firstWhere(
        (kind) => kind.name == (value ?? '').toLowerCase(),
        orElse: () => PrinterKind.label,
      );
}

/// How Atria reaches the printer.
enum PrinterTransport {
  /// Raw TCP to the printer's own port — 9100 on virtually every network
  /// printer, and the only path that works on Android without a plugin.
  network('Network (IP)'),

  /// The Windows print queue the vendor driver installed. Raw bytes are
  /// spooled straight through, which is what makes USB work without a driver
  /// round-trip through a PDF.
  ///
  /// **Windows-only.** The name says "USB", but what is actually being used is
  /// `winspool.drv` — a Windows print queue that exists because a Windows
  /// driver created it. Android has no such queue: there is nothing for
  /// `OpenPrinterW` to open, and a USB printer there needs an OTG/permission
  /// plugin the app does not ship. So this transport must never be *offered*
  /// off Windows, and a stored profile that names it must be reported as
  /// unusable rather than silently retargeted — see [isSupportedHere].
  usb('USB / installed printer');

  const PrinterTransport(this.label);

  final String label;

  /// Whether Atria can reach a printer over this transport on the device it is
  /// currently running on.
  ///
  /// One predicate, in one place, so every entry point that could hand a
  /// profile to a printer asks the same question: the settings picker (which
  /// must not offer [usb] on a phone), the printer list and its test buttons,
  /// and the registry fallbacks behind `defaultPrinterProvider`, which decides
  /// which printer a POS print button uses. A profile saved on a desktop and
  /// restored on a phone keeps `transport == usb`, and without this check the
  /// print buttons would hand it to a spooler that is not there.
  bool get isSupportedHere => switch (this) {
        usb => Platform.isWindows,
        network => true,
      };

  /// The transports to offer for a *new* printer on this device.
  ///
  /// A stored [usb] profile is deliberately **not** folded into this list — it
  /// is migrated to [network] by the editor with an explanation, so the queue
  /// name it held is never lost silently.
  static List<PrinterTransport> get availableHere =>
      [for (final transport in values) if (transport.isSupportedHere) transport];

  static PrinterTransport parse(String? value) => values.firstWhere(
        (transport) => transport.name == (value ?? '').toLowerCase(),
        orElse: () => PrinterTransport.network,
      );
}

/// One configured printer, as the operator set it up in Settings.
class PrinterProfile {
  const PrinterProfile({
    required this.id,
    required this.name,
    this.kind = PrinterKind.label,
    this.brand = PrinterBrand.tsc,
    this.transport = PrinterTransport.network,
    this.host = '',
    this.port = defaultPort,
    this.queueName = '',
    this.dpi = 203,
    this.labelWidthMm = 50,
    this.labelHeightMm = 25,
    this.gapMm = 2,
    this.darkness = 8,
    this.speed = 4,
    this.copies = 1,
    this.offsetXMm = 0,
    this.offsetYMm = 0,
    this.paperWidthMm = 58,
    this.cutPaper = true,
    this.openDrawer = false,
  });

  /// 9100 is the raw-print port on essentially every networked label printer.
  /// 515 (LPD) and 631 (IPP) exist but are not plain byte pipes.
  static const int defaultPort = 9100;

  final String id;

  /// What the operator calls it, e.g. "Counter TSC".
  final String name;

  /// Labels or receipts. Decides the command language and the setup fields the
  /// settings screen shows.
  final PrinterKind kind;

  final PrinterBrand brand;
  final PrinterTransport transport;

  /// Network transport: the printer's IP or hostname.
  final String host;
  final int port;

  /// USB transport: the exact Windows printer queue name, e.g.
  /// "TSC TTP-244 Pro".
  final String queueName;

  /// Print head resolution. 203 dpi is 8 dots/mm and the common case; 300 dpi
  /// is 11.81 dots/mm and gets a head that needs it a finer image.
  final int dpi;

  final double labelWidthMm;
  final double labelHeightMm;

  /// The die-cut gap between labels, or 0 for continuous stock.
  final double gapMm;

  /// TSPL `DENSITY`, 0–15. ZPL's `~SD` runs 0–30, so it is doubled on the way
  /// out rather than making the operator learn two scales.
  final int darkness;

  /// Inches per second, TSPL `SPEED` 1–6.
  final int speed;

  /// Default number of copies for one label.
  final int copies;

  /// Calibration nudge. TSPL coordinates are dots from the top-left of the
  /// label, and a printer whose gap sensor is slightly off prints everything
  /// shifted; this moves the whole label without editing the layout.
  final double offsetXMm;
  final double offsetYMm;

  /// Receipt rolls come in two widths, and the width decides how many
  /// characters fit on a line — 32 on a 58 mm roll, 48 on an 80 mm one.
  final int paperWidthMm;

  /// Whether to cut the paper after a receipt. Off for a printer with a tear
  /// bar, and off while an operator is calibrating.
  final bool cutPaper;

  /// Whether a receipt should kick the cash drawer. The drawer hangs off the
  /// printer, so this is the only way a cash sale can open it.
  final bool openDrawer;

  /// Dots per millimetre for this print head — the conversion every encoder
  /// needs, because TSPL `SIZE` is in millimetres while every coordinate is in
  /// dots.
  ///
  /// Taken from the printer's own convention rather than from `dpi / 25.4`:
  /// TSPL *defines* a 203 dpi head as 8 dots/mm and a 300 dpi head as
  /// 11.8 dots/mm, and interprets `SIZE` with those figures. Deriving 7.992
  /// would lay every coordinate out about 0.1% short of where the firmware
  /// looks for it — invisible on a short line, and a millimetre out by the
  /// bottom of the label.
  double get dotsPerMm => switch (dpi) {
        300 => 11.8,
        _ => 8,
      };

  int get labelWidthDots => (labelWidthMm * dotsPerMm).round();
  int get labelHeightDots => (labelHeightMm * dotsPerMm).round();

  /// Whether this profile can actually be sent to.
  bool get isUsable {
    if (transport == PrinterTransport.network) {
      return host.trim().isNotEmpty && port > 0 && port < 65536;
    }
    return queueName.trim().isNotEmpty;
  }

  /// Whether this profile can be sent to **on this device**.
  ///
  /// [isUsable] says the profile is complete; this says it is complete *and*
  /// reachable from here. A `usb` profile restored from a desktop onto a phone
  /// is complete and unusable, and only this getter tells the two apart.
  bool get isUsableHere => isUsable && transport.isSupportedHere;

  /// Why [isUsableHere] is false, in words the settings screen can show.
  ///
  /// Checked in a fixed order — incomplete before unreachable — so a profile
  /// that is missing both its address and its platform says the actionable
  /// thing. Every message names the next action, because this is the text an
  /// operator reads instead of a printer error.
  String? get problem {
    if (isUsableHere) return null;
    if (transport == PrinterTransport.network) {
      if (host.trim().isEmpty) return 'No printer address was set.';
      return 'Port $port is not a usable port.';
    }
    if (queueName.trim().isEmpty) return 'No installed printer was chosen.';
    return PrinterProfile.unsupportedTransportMessage;
  }

  /// What to tell an operator whose printer was configured on a computer and is
  /// now being opened on a phone.
  ///
  /// Named rather than inlined so the settings list, the editor and the
  /// registry all say the same thing: the queue name is not wrong, it is
  /// *unreachable*, and the fix is to address the printer by IP.
  static const String unsupportedTransportMessage =
      'This printer was set up on a computer, where it prints through a '
      'Windows print queue. This device cannot reach one — edit the printer '
      'and enter its IP address ("Network (IP)") instead.';

  /// A one-line summary for list rows.
  String get describe {
    final target = transport == PrinterTransport.network
        ? '${host.trim().isEmpty ? 'no address' : host.trim()}:$port'
        : (queueName.trim().isEmpty ? 'no printer chosen' : queueName.trim());
    if (kind == PrinterKind.receipt) {
      return 'Receipts · ESC/POS · $target · $paperWidthMm mm roll'
          '${cutPaper ? ' · cuts' : ''}${openDrawer ? ' · opens drawer' : ''}';
    }
    return '${kind.title} · ${brand.label} · ${brand.language} · $target · '
        '${_trimMm(labelWidthMm)}x${_trimMm(labelHeightMm)} mm · $dpi dpi';
  }

  static String _trimMm(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : value.toString();

  /// What kind of printer this is, for the settings list.
  String get kindLabel => kind.title;

  /// Whether this profile can print the document the caller has in hand.
  ///
  /// Said out loud rather than left to fail at the printer: a shop that has only
  /// set up a label printer and taps "Print receipt" needs to be told which one
  /// to add, not shown a command-language error.
  bool canPrint(PrinterKind wanted) => kind == wanted;

  PrinterProfile copyWith({
    String? id,
    String? name,
    PrinterKind? kind,
    PrinterBrand? brand,
    PrinterTransport? transport,
    String? host,
    int? port,
    String? queueName,
    int? dpi,
    double? labelWidthMm,
    double? labelHeightMm,
    double? gapMm,
    int? darkness,
    int? speed,
    int? copies,
    double? offsetXMm,
    double? offsetYMm,
    int? paperWidthMm,
    bool? cutPaper,
    bool? openDrawer,
  }) =>
      PrinterProfile(
        id: id ?? this.id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        brand: brand ?? this.brand,
        transport: transport ?? this.transport,
        host: host ?? this.host,
        port: port ?? this.port,
        queueName: queueName ?? this.queueName,
        dpi: dpi ?? this.dpi,
        labelWidthMm: labelWidthMm ?? this.labelWidthMm,
        labelHeightMm: labelHeightMm ?? this.labelHeightMm,
        gapMm: gapMm ?? this.gapMm,
        darkness: darkness ?? this.darkness,
        speed: speed ?? this.speed,
        copies: copies ?? this.copies,
        offsetXMm: offsetXMm ?? this.offsetXMm,
        offsetYMm: offsetYMm ?? this.offsetYMm,
        paperWidthMm: paperWidthMm ?? this.paperWidthMm,
        cutPaper: cutPaper ?? this.cutPaper,
        openDrawer: openDrawer ?? this.openDrawer,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'brand': brand.name,
        'transport': transport.name,
        'host': host,
        'port': port,
        'queueName': queueName,
        'dpi': dpi,
        'labelWidthMm': labelWidthMm,
        'labelHeightMm': labelHeightMm,
        'gapMm': gapMm,
        'darkness': darkness,
        'speed': speed,
        'copies': copies,
        'offsetXMm': offsetXMm,
        'offsetYMm': offsetYMm,
        'paperWidthMm': paperWidthMm,
        'cutPaper': cutPaper,
        'openDrawer': openDrawer,
      };

  /// Reads a profile back, clamping anything a hand-edited settings row could
  /// have put out of range.
  ///
  /// The values are *clamped rather than rejected*: a printer configured with
  /// an impossible darkness should still print, if heavily, because refusing to
  /// open Settings would leave the operator unable to fix it.
  static PrinterProfile fromJson(Map<String, Object?> json) {
    final dpi = _int(json['dpi'], 203);
    return PrinterProfile(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? 'Printer',
      kind: PrinterKind.parse(json['kind'] as String?),
      brand: PrinterBrand.parse(json['brand'] as String?),
      transport: PrinterTransport.parse(json['transport'] as String?),
      host: (json['host'] as String?) ?? '',
      port: _int(json['port'], defaultPort).clamp(1, 65535),
      queueName: (json['queueName'] as String?) ?? '',
      // 203 or 300 only: an arbitrary dpi would silently mis-scale every
      // coordinate, which looks like a broken printer rather than a bad setting.
      dpi: dpi == 300 ? 300 : 203,
      labelWidthMm: _double(json['labelWidthMm'], 50).clamp(10, 220),
      labelHeightMm: _double(json['labelHeightMm'], 25).clamp(5, 300),
      gapMm: _double(json['gapMm'], 2).clamp(0, 10),
      darkness: _int(json['darkness'], 8).clamp(0, 15),
      speed: _int(json['speed'], 4).clamp(1, 6),
      copies: _int(json['copies'], 1).clamp(1, 50),
      offsetXMm: _double(json['offsetXMm'], 0).clamp(-20, 20),
      offsetYMm: _double(json['offsetYMm'], 0).clamp(-20, 20),
      // 58 or 80 only: a stored 76 (which some 3-inch rolls claim to be) would
      // silently pick the 80 mm column count and print totals past the edge of
      // the paper.
      paperWidthMm: _int(json['paperWidthMm'], 58) >= 80 ? 80 : 58,
      cutPaper: _bool(json['cutPaper'], true),
      openDrawer: _bool(json['openDrawer'], false),
    );
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse('${value ?? ''}') ?? fallback;
  }

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse('${value ?? ''}') ?? fallback;
  }

  static bool _bool(Object? value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return fallback;
  }

  /// The listener-side defaults offered when the operator adds a printer.
  ///
  /// 50×25 mm is the die-cut label a TSC TTP-244 or Zebra GK420 ships with, and
  /// the size most Indian SMBs buy for retail barcode stickers.
  static const PrinterProfile blank = PrinterProfile(
    id: '',
    name: 'New printer',
  );

  /// Sensible label sizes offered as presets, so a first setup does not need a
  /// ruler. Values are millimetres.
  static const List<(String, double, double)> sizePresets = [
    ('50 × 25 mm (standard retail)', 50, 25),
    ('38 × 25 mm (small retail)', 38, 25),
    ('50 × 40 mm (with HSN)', 50, 40),
    ('75 × 50 mm (shelf label)', 75, 50),
    ('100 × 50 mm (2-up pricing)', 100, 50),
  ];

  /// Parses the settings blob. A malformed row yields an empty list rather
  /// than an exception: a corrupt pref must not make Settings unopenable.
  ///
  /// Every empty branch returns a **growable** list. Returning `const []` here
  /// is what made adding the very first printer throw "Cannot add to an
  /// unmodifiable list" inside [PrinterRegistry.upsert] — and, because the same
  /// value came back from [all], it also made removing the last one fail.
  static List<PrinterProfile> parseList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <PrinterProfile>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <PrinterProfile>[];
      return [
        for (final entry in decoded)
          if (entry is Map)
            PrinterProfile.fromJson(entry.cast<String, Object?>()),
      ];
    } on FormatException {
      return <PrinterProfile>[];
    }
  }

  static String encodeList(List<PrinterProfile> profiles) => jsonEncode(
        [for (final profile in profiles) profile.toJson()],
      );
}
