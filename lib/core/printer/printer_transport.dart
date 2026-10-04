import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'label_encoder.dart';
import 'printer_profile.dart';

/// A way of getting printer commands to a printer.
///
/// The two implementations are genuinely different problems — a TCP socket is
/// a byte pipe, a Windows print queue needs the spooler API — so this is an
/// interface rather than one function with a branch, and the branch lives in
/// [forProfile] alone.
abstract class PrinterConnection {
  PrinterConnection(this.profile);

  final PrinterProfile profile;

  /// Sends one print job.
  ///
  /// Throws [LabelException] with a message written for the operator: a
  /// printer that is switched off, unplugged or on another subnet must not
  /// surface as a socket error string. Nothing else may escape — every caller
  /// is a button's `onPressed`, and an exception there is a red screen, not an
  /// answer.
  Future<void> send(Uint8List bytes);

  /// Checks the printer is reachable, without printing anything.
  ///
  /// Used by the settings screen so an operator can find out the address is
  /// wrong before they waste a label finding out.
  Future<String> probe();

  static PrinterConnection forProfile(PrinterProfile profile) =>
      switch (profile.transport) {
        PrinterTransport.network => NetworkPrinterConnection(profile),
        PrinterTransport.usb => WindowsSpoolConnection(profile),
      };

  /// Installed Windows print queues, for the settings picker.
  ///
  /// Asked of the spooler rather than read from the registry, because the
  /// registry stores ports (USB001, IP_192.168.1.50) while the operator knows
  /// the names Windows shows them. Returns an empty list on any failure —
  /// the caller falls back to a text field, so a missing listing degrades to
  /// typing the name rather than blocking setup.
  static Future<List<String>> installedPrinterNames() async {
    if (!Platform.isWindows) return const [];
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Get-Printer | Select-Object -ExpandProperty Name',
        ],
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return const [];
      return [
        for (final line in '${result.stdout}'.split(RegExp(r'\r?\n')))
          if (line.trim().isNotEmpty) line.trim(),
      ];
    } on Object {
      return const [];
    }
  }

  /// The reason [transport] cannot be used on this device, in the operator's
  /// words — or null when it can.
  ///
  /// Delegates to the one message the settings screens use, so a USB profile
  /// opened on a phone says the same thing wherever the operator meets it. See
  /// [PrinterTransport.isSupportedHere].
  static String? unsupportedHere(PrinterTransport transport) =>
      transport.isSupportedHere
          ? null
          : PrinterProfile.unsupportedTransportMessage;
}

/// Raw TCP to the printer's own port.
///
/// This is the transport that works everywhere — Windows, Android, Linux — with
/// no native code and no driver, which is why 9100 is the port every network
/// label printer listens on.
class NetworkPrinterConnection extends PrinterConnection {
  NetworkPrinterConnection(super.profile);

  static const Duration _connectTimeout = Duration(seconds: 4);

  /// How long the printer may take to swallow the whole job.
  ///
  /// Long enough for a 100×100 mm bitmap, short enough that a printer which
  /// has stopped reading is reported rather than waited on forever.
  static const Duration _drainTimeout = Duration(seconds: 20);

  @override
  Future<void> send(Uint8List bytes) async {
    final host = profile.host.trim();
    if (host.isEmpty) {
      throw const LabelException(
        'This printer has no address. Open the printer settings and enter its '
        'IP address.',
      );
    }
    if (bytes.isEmpty) {
      throw const LabelException('There is nothing to print.');
    }
    final port = profile.port;
    if (port <= 0 || port > 65535) {
      throw LabelException(
        'Port $port is not a port this printer can be reached on. Enter the '
        'printer\'s raw-print port — 9100 on almost every network label '
        'printer.',
      );
    }

    final socket = await _connect(host, port);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      socket.add(bytes);
      // `flush()` is NOT enough, and neither is a pause.
      //
      // `flush()` only means "Dart's buffer reached the kernel socket
      // buffer", and `destroy()` — which is what the old teardown used — is
      // explicitly *not* a graceful close: it discards whatever the kernel has
      // not yet put on the wire. A 100×100 mm label is a bitmap of hundreds of
      // kilobytes, so the job was still in flight when the socket was torn
      // down. The printer then got a clipped label, nothing at all, or a
      // literal tail of the command text.
      //
      // Closing the sink and awaiting `done` is the documented way to know
      // every byte has been handed to the OS. Beyond that there is nothing to
      // wait for: a thermal printer has no application-level acknowledgement,
      // and `done` completing is the closest thing to one that exists.
      await socket.close();
      await socket.done.timeout(_drainTimeout);
    } on TimeoutException {
      throw LabelException(
        'The printer at $host:$port answered but stopped taking data after '
        '${_drainTimeout.inSeconds} seconds, so the label was cut short. Turn '
        'the printer off and on, then print again.',
      );
    } on SocketException catch (error) {
      throw LabelException(
        'Lost the connection to $host:$port part-way through the job '
        '(${error.osError?.message ?? error.message}), so the label was not '
        'printed in full.',
      );
    } finally {
      // Harmless once the socket is closed; it is what stops a half-written
      // job when the drain above throws.
      socket.destroy();
    }
  }

  @override
  Future<String> probe() async {
    final host = profile.host.trim();
    if (host.isEmpty) {
      throw const LabelException('This printer has no address.');
    }
    final port = profile.port;
    if (port <= 0 || port > 65535) {
      throw LabelException(
        'Port $port is not a port a printer can be reached on. Enter the raw-'
        'print port — 9100 on almost every network label printer.',
      );
    }
    final socket = await _connect(host, port);
    // Nothing to write: reaching the port is the whole answer.
    socket.destroy();
    return 'Reachable at $host:$port.';
  }

  /// Opens the connection, turning every way it can fail into an answer.
  ///
  /// `Socket.connect` does not only throw [SocketException]: the `timeout:`
  /// argument raises [TimeoutException] when a firewall silently DROPs the SYN,
  /// and a malformed host raises [ArgumentError]. All three used to escape —
  /// and a `TimeoutException` raised out of a `VoidCallback` is an unhandled
  /// zone error on a phone, i.e. a red screen where the operator asked a
  /// reasonable question.
  Future<Socket> _connect(String host, int port) async {
    try {
      return await Socket.connect(host, port, timeout: _connectTimeout);
    } on SocketException catch (error) {
      throw LabelException(
        'Could not reach $host:$port (${error.osError?.message ?? error.message}). '
        'Check the printer is switched on, that this machine is on the same '
        'network, and that the address is the printer\'s own.',
      );
    } on TimeoutException {
      throw LabelException(
        'Timed out connecting to $host:$port. Network label printers usually '
        'listen on port 9100 — check the printer settings are set to "Raw", '
        'not "LPR" or "IPP".',
      );
    } on LabelException {
      rethrow;
    } on Object catch (error) {
      throw LabelException(
        'Could not reach $host:$port ($error). Check the address and port in '
        'the printer settings.',
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Windows print queue (winspool.drv)
// ---------------------------------------------------------------------------

/// Sends raw bytes to a printer installed in Windows.
///
/// A USB label printer is reached through the queue the vendor's driver
/// installed, and the spooler is told the datatype is `RAW` — meaning "pass
/// these bytes through untouched". Anything else makes Windows run the job
/// through the driver as if it were GDI, and the printer spells out the TSPL
/// or ZPL commands as text.
///
/// The spooler API is reached through `dart:ffi` rather than by shelling out,
/// because there is no CLI that can write raw bytes to a queue:
/// `print` mangles them and `copy /b` to a share needs the printer to be shared
/// and the share to exist.
///
/// Every call into the spooler runs on a **worker isolate**. `WritePrinter`
/// blocks until the spooler accepts the job, and a stalled driver, an offline
/// queue or a paused job blocks it for as long as the operator leaves it — on
/// the UI isolate that froze the entire app: no frame, no spinner, no way out.
class WindowsSpoolConnection extends PrinterConnection {
  WindowsSpoolConnection(super.profile);

  @override
  Future<void> send(Uint8List bytes) async {
    final queue = profile.queueName.trim();
    if (!profile.transport.isSupportedHere) {
      throw LabelException(PrinterConnection.unsupportedHere(profile.transport)!);
    }
    if (queue.isEmpty) {
      throw const LabelException(
        'No installed printer was chosen. Open the printer settings and pick '
        'one from the list.',
      );
    }
    if (bytes.isEmpty) {
      throw const LabelException('There is nothing to print.');
    }

    final _SpoolResult result;
    try {
      // The whole FFI sequence — OpenPrinterW, StartDocPrinterW, WritePrinter,
      // EndDocPrinter — runs on a worker isolate, so a spooler that blocks
      // cannot block the UI. The worker is told only a String and a Uint8List,
      // both copied across, so nothing holding a native handle is ever shared,
      // and it answers with a plain record rather than an exception: a
      // [LabelException] would have to be reconstructed over here, and the one
      // thing `DynamicLibrary.open` can raise (ArgumentError, no such DLL) is
      // not something worth letting cross a boundary.
      result = await _SpoolWorker.spool(queue, bytes);
    } on LabelException {
      rethrow;
    } on Object catch (error) {
      throw LabelException(
        'Could not reach the Windows print spooler ($error). Printing to an '
        'installed printer needs a working Windows print queue — or use the '
        'printer\'s network address.',
      );
    }
    if (!result.ok) {
      throw LabelException(result.message);
    }
  }

  @override
  Future<String> probe() async {
    final queue = profile.queueName.trim();
    if (!profile.transport.isSupportedHere) {
      throw LabelException(PrinterConnection.unsupportedHere(profile.transport)!);
    }
    if (queue.isEmpty) {
      throw const LabelException('No installed printer was chosen.');
    }
    List<String> names;
    try {
      names = await PrinterConnection.installedPrinterNames();
    } on Object catch (error) {
      throw LabelException(
        'Could not list the installed printers on this computer ($error).',
      );
    }
    if (names.isEmpty) {
      // The listing needs PowerShell; failing to list is not evidence the
      // printer is missing, so this is reported as unknown rather than absent.
      return 'Could not list the installed printers to check "$queue".';
    }
    final match = names.where(
      (name) => name.toLowerCase() == queue.toLowerCase(),
    );
    if (match.isEmpty) {
      throw LabelException(
        'Windows has no printer called "$queue". Installed printers are: '
        '${names.join(', ')}.',
      );
    }
    return '"${match.first}" is installed.';
  }
}

// ---------------------------------------------------------------------------
// The worker
// ---------------------------------------------------------------------------

/// What the worker isolate reports back.
///
/// A record of primitives, so it is copied across the boundary as-is. `ok` and
/// `errorCode` are there for callers and tests; [message] is what the operator
/// reads, and it is already written for them.
typedef _SpoolResult = ({bool ok, int errorCode, String message});

/// A spooler call that failed, with the error code read *at that moment*.
///
/// Private to this file and never thrown across an isolate boundary — the
/// worker catches it and folds it into a [_SpoolResult].
class _SpoolerFailure implements Exception {
  const _SpoolerFailure(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => message;
}

/// How long the operator waits before being told the spooler is stuck.
///
/// `WritePrinter` is a blocking native call, so nothing on this side can
/// interrupt it. The timeout exists to stop the *UI* waiting forever, which is
/// what turned a wedged printer into a frozen application — not to rescue the
/// worker, which stays stuck and is replaced (see [_SpoolWorker]).
const Duration _spoolTimeout = Duration(seconds: 20);

/// What the worker answers when it was told to give up waiting.
///
/// `errorCode` is 0 because there is no Windows error to report: nothing
/// failed, the queue simply never answered.
const _SpoolResult _spoolTimedOut = (
  ok: false,
  errorCode: 0,
  message: 'Windows did not accept the label within 20 seconds. The print '
      'queue is most likely paused, out of paper, or showing an error dialog '
      'on the computer. Clear it there, or print this label through the '
      'printer\'s network address.',
);

/// One job, handed to the worker. Plain data only — this object is copied
/// across the isolate boundary.
class _SpoolRequest {
  const _SpoolRequest(this.queue, this.bytes, this.replyTo);

  final String queue;
  final Uint8List bytes;
  final SendPort replyTo;
}

/// The isolate that owns the spooler bindings — one for the life of the
/// process, not one per job.
///
/// `Isolate.run` would have been the two-line version of B1, and it does stop
/// the UI blocking. But a spawned isolate gets its own copy of every top-level,
/// so it would `LoadLibrary` `winspool.drv` and `kernel32.dll` again for
/// *every label* — the refcount leak B3 is about, back through the front door.
/// One isolate means one `LoadLibrary`, once.
///
/// The cost of a long-lived worker is the job the spooler refuses to finish: it
/// stays blocked in `WritePrinter` and can never answer again. So a timeout
/// retires the worker and the next job spawns a fresh one. The stuck isolate is
/// deliberately **not** killed — a blocked native call gives the VM no safepoint
/// to kill at, and a kill that waited for one would freeze the UI all over
/// again. It is abandoned: a little memory and one loader refcount, in exchange
/// for never hanging the app.
class _SpoolWorker {
  _SpoolWorker._(this._commands);

  static _SpoolWorker? _current;

  /// Serialises jobs across the whole app.
  ///
  /// The spooler is one queue per printer and a job is not atomic with respect
  /// to the next: two labels written at once would interleave into one corrupt
  /// job. Chaining here also means a queued job is only handed to the worker
  /// once its turn comes — which is what lets a retired worker be noticed
  /// before the next job reaches it.
  static Future<void> _gate = Future<void>.value();

  /// Spools one job on a worker isolate and reports what happened.
  static Future<_SpoolResult> spool(String queue, Uint8List bytes) {
    final completer = Completer<_SpoolResult>();
    _gate = _gate.then(
      (_) => _run(queue, bytes, completer),
      // A gate that had gone bad would silently stop every *future* print from
      // running at all, which is a far worse failure than this one ever was —
      // so whatever went wrong, the next job still gets an answer.
      onError: (Object error) => _answer(
        completer,
        (
          ok: false,
          errorCode: 0,
          message: 'The print spooler worker stopped unexpectedly ($error).',
        ),
      ),
    );
    return completer.future;
  }

  /// One job's turn. Never throws and never leaves [completer] unanswered.
  static Future<void> _run(
    String queue,
    Uint8List bytes,
    Completer<_SpoolResult> completer,
  ) async {
    _SpoolResult result;
    try {
      // The worker is looked up *here*, not when the job was queued, so that a
      // worker retired by the previous job's timeout is already replaced.
      result = await (_current ??= _spawn()).run(queue, bytes);
    } on Object catch (error) {
      // The isolate could not even be spawned, or the message port died.
      // Answered rather than thrown, so the next queued job still runs.
      result = (
        ok: false,
        errorCode: 0,
        message: 'The print spooler worker stopped unexpectedly ($error).',
      );
    }
    _answer(completer, result);
  }

  static void _answer(Completer<_SpoolResult> completer, _SpoolResult result) {
    if (completer.isCompleted) return;
    completer.complete(result);
  }

  /// Starts a worker.
  ///
  /// The [Isolate] handle is deliberately not kept: nothing may do anything
  /// with it (see [_SpoolWorker] on why a wedged worker is abandoned rather
  /// than killed), and the isolate stays alive on its own for as long as it is
  /// blocked in the spooler. The port is what the jobs are sent through.
  static _SpoolWorker _spawn() {
    final commands = ReceivePort();
    // The spawn error is deliberately ignored: a `Future<Isolate>` that fails
    // would otherwise become an unhandled async error. A worker that never
    // starts shows up as a job that times out, which is an answer.
    Isolate.spawn(_spoolWorkerMain, commands.sendPort).ignore();
    return _SpoolWorker._(commands);
  }

  final ReceivePort _commands;

  Future<_SpoolResult> run(String queue, Uint8List bytes) {
    final completer = Completer<_SpoolResult>();
    final reply = ReceivePort();
    Timer? timer;
    void finish(_SpoolResult result) {
      if (completer.isCompleted) return;
      timer?.cancel();
      reply.close();
      completer.complete(result);
    }

    timer = Timer(_spoolTimeout, () {
      finish(_spoolTimedOut);
      // Retire: this isolate is inside a native call it will never leave, so
      // the next job needs one that is not.
      if (identical(_current, this)) _current = null;
    });
    _commands.sendPort.send(_SpoolRequest(queue, bytes, reply.sendPort));
    reply.listen(
      (Object? message) {
        if (message is _SpoolResult) finish(message);
      },
      onError: (Object _) => finish(
        (
          ok: false,
          errorCode: 0,
          message: 'The print spooler worker stopped unexpectedly.',
        ),
      ),
    );
    return completer.future;
  }
}

/// The worker's receive port.
///
/// At library scope rather than a local in the entry point because a port with
/// no strong reference can be collected, and the worker would then stop
/// answering mid-session. Dart initialises a top-level `final` lazily, so on
/// Android — where no worker is ever spawned — this opens nothing at all.
ReceivePort? _workerCommands;

/// The worker isolate's entry point.
///
/// Everything the FFI bindings need is resolved here, once, on the thread that
/// will be stuck if the spooler is:
///
/// * `_getLastError` **first**, while nothing has gone wrong. Binding it is a
///   `LoadLibrary` plus a `GetProcAddress`, and *both* of those overwrite the
///   calling thread's last error — so a binding resolved after a failed
///   `OpenPrinterW` reports whatever the DLL loader left behind instead of the
///   spooler's own error, which is how every failure used to read "no error".
/// * `_spooler` next, which is the one `LoadLibrary` of `winspool.drv` this
///   process ever does.
///
/// Both are then passed down rather than re-read, so [_spoolJob] cannot
/// accidentally resolve one in the middle of a job.
void _spoolWorkerMain(SendPort commands) {
  final lastError = _getLastError;
  final spooler = _spooler;
  // `??=` rather than a plain assignment: a second call in the same isolate
  // would otherwise attach a *second* handler to the port, and every message
  // would spool the label twice.
  _workerCommands ??= ReceivePort();
  _workerCommands!.listen((dynamic message) {
    if (message is! _SpoolRequest) return;
    message.replyTo.send(_spoolJob(spooler, lastError, message));
  });
}

/// Spools one job. Runs on a worker isolate; nothing here may touch the UI.
///
/// The whole point of the split is that the four blocking calls below are
/// allowed to take as long as the spooler needs. Returning a value instead of
/// throwing keeps every exception — including the ones the loader raises —
/// inside this isolate.
_SpoolResult _spoolJob(
  _Spooler spooler,
  int Function() lastError,
  _SpoolRequest request,
) {
  final queue = request.queue;
  final bytes = request.bytes;

  final printerName = queue.toNativeUtf16();
  final docName = 'Apex Books label'.toNativeUtf16();
  final datatype = 'RAW'.toNativeUtf16();
  final handle = calloc<IntPtr>();
  // DOC_INFO_1W is { pDocName, pOutputFile, pDatatype } — three pointers.
  // Level 1 is the only level whose datatype is honoured for raw jobs.
  final docInfo = calloc<Pointer<Utf16>>(3);
  final buffer = calloc<Uint8>(bytes.length);
  final written = calloc<Uint32>();
  var pageStarted = false;
  var docStarted = false;

  try {
    // Read the error *immediately*, as the next statement after each failing
    // call. Anything else — building a string first, allocating — gives the
    // runtime a chance to call another Win32 API and overwrite it.
    if (spooler.openPrinter(printerName, handle) == 0) {
      final code = lastError();
      throw _SpoolerFailure(
        code,
        'Windows could not open the printer "$queue" '
        '(${spoolErrorText(code)}). Check the name in Windows Settings → '
        'Bluetooth & devices → Printers & scanners.',
      );
    }

    docInfo[0] = docName;
    docInfo[1] = nullptr;
    docInfo[2] = datatype;

    if (spooler.startDocPrinter(handle.value, docInfo.cast<Uint8>()) == 0) {
      final code = lastError();
      throw _SpoolerFailure(
        code,
        'Windows refused the print job for "$queue" (${spoolErrorText(code)}).',
      );
    }
    docStarted = true;

    if (spooler.startPagePrinter(handle.value) == 0) {
      final code = lastError();
      throw _SpoolerFailure(
        code,
        'Windows could not start a page for "$queue" '
        '(${spoolErrorText(code)}).',
      );
    }
    pageStarted = true;

    buffer.asTypedList(bytes.length).setAll(0, bytes);
    if (spooler.writePrinter(
          handle.value,
          buffer,
          bytes.length,
          written,
        ) ==
        0) {
      final code = lastError();
      throw _SpoolerFailure(
        code,
        'Windows could not write the label to "$queue" '
        '(${spoolErrorText(code)}).',
      );
    }
    if (written.value != bytes.length) {
      // A short write means the spooler dropped part of the job; the printer
      // would print half a label, which looks like a hardware fault rather
      // than a failed job.
      throw _SpoolerFailure(
        0,
        'Only ${written.value} of ${bytes.length} bytes reached "$queue" — the '
        'label was not printed. Try again, or print through the printer\'s '
        'network address.',
      );
    }

    return const (ok: true, errorCode: 0, message: '');
  } on _SpoolerFailure catch (failure) {
    return (ok: false, errorCode: failure.code, message: failure.message);
  } on Object catch (error) {
    // A missing `winspool.drv`, an allocation failure — anything the FFI layer
    // raises. Reported as a print failure rather than an unhandled error, for
    // the same reason the result is a value and not a thrown exception.
    return (
      ok: false,
      errorCode: 0,
      message: 'Windows could not spool the label to "$queue" ($error).',
    );
  } finally {
    if (pageStarted) spooler.endPagePrinter(handle.value);
    if (docStarted) spooler.endDocPrinter(handle.value);
    if (handle.value != 0) spooler.closePrinter(handle.value);
    calloc
      ..free(printerName)
      ..free(docName)
      ..free(datatype)
      ..free(handle)
      ..free(docInfo)
      ..free(buffer)
      ..free(written);
  }
}

/// `GetLastError`, bound once per isolate.
///
/// `LoadLibrary` and `GetProcAddress` both overwrite the thread's last error,
/// so this may only be resolved *before* the first failing spooler call —
/// [_spoolWorkerMain] forces it by touching it first, before it touches
/// anything else. Dart initialises a top-level `final` lazily, so on a platform
/// with no `kernel32.dll` (Android) nothing is opened at all: the binding only
/// exists if a Windows job is attempted.
final int Function() _getLastError = DynamicLibrary.open('kernel32.dll')
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');

/// `winspool.drv` and its entry points, bound once per isolate.
///
/// A fresh binding per job used to `LoadLibrary` both DLLs again every label —
/// the loader refcount grew with every print and nothing ever called
/// `FreeLibrary`. One long-lived instance per isolate fixes that; `dart:ffi`
/// has no `FreeLibrary`, and a module that is still in use cannot be unloaded
/// safely anyway.
final _Spooler _spooler = _Spooler();

/// The spooler's error code in words.
///
/// The numeric code is kept alongside the meaning, because the common ones
/// (5 = access denied, 1801 = the queue name is wrong) are searchable and a
/// bare error number with no context is not.
String spoolErrorText(int code) => switch (code) {
      0 => 'no error',
      2 => 'the printer could not be found',
      5 => 'access denied — try running Apex Books as an administrator',
      87 => 'the printer name is not valid',
      1801 => 'the printer name is not recognised by Windows',
      1909 => 'the printer is not enabled right now',
      3002 => 'the spooler refused the job',
      _ => 'unrecognised spooler error',
    };

/// The seven `winspool.drv` entry points a raw job needs.
///
/// Bound once per instance, in the constructor, rather than on first call: a
/// `late final` field would run `GetProcAddress` the first time each function
/// is reached, which is a `GetLastError`-clobbering call sitting in the middle
/// of the sequence.
class _Spooler {
  _Spooler() : _library = DynamicLibrary.open('winspool.drv') {
    _openPrinterNative = _library.lookupFunction<
        Int32 Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>),
        int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)>(
      'OpenPrinterW',
    );

    // `lookupFunction<Native, Dart>`: the first type is the C signature, the
    // second the Dart one it is bridged to. Handles (`HANDLE`/`DWORD`) are
    // `IntPtr`/`Uint32` on the C side and plain `int` on the Dart side —
    // writing the FFI types in both is the classic mistake here, and the
    // analyzer rejects it rather than letting it fail at runtime.
    _startDocPrinterNative = _library.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Uint8>),
        int Function(int, int, Pointer<Uint8>)>(
      'StartDocPrinterW',
    );

    _startPagePrinterNative =
        _library.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'StartPagePrinter',
    );

    _writePrinterNative = _library.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)>(
      'WritePrinter',
    );

    _endPagePrinterNative =
        _library.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'EndPagePrinter',
    );

    _endDocPrinterNative =
        _library.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'EndDocPrinter',
    );

    _closePrinterNative =
        _library.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'ClosePrinter',
    );
  }

  final DynamicLibrary _library;

  // `late final` *assigned in the constructor*, not `late final x = ...`: the
  // `= ...` form is lazy and would run `GetProcAddress` at the moment each
  // function is first reached — in the middle of the job.
  late final int Function(Pointer<Utf16>, Pointer<IntPtr>, Pointer<Void>)
      _openPrinterNative;
  late final int Function(int, int, Pointer<Uint8>) _startDocPrinterNative;
  late final int Function(int) _startPagePrinterNative;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>)
      _writePrinterNative;
  late final int Function(int) _endPagePrinterNative;
  late final int Function(int) _endDocPrinterNative;
  late final int Function(int) _closePrinterNative;

  int openPrinter(Pointer<Utf16> name, Pointer<IntPtr> handle) =>
      _openPrinterNative(name, handle, nullptr);

  int startDocPrinter(int handle, Pointer<Uint8> info) =>
      _startDocPrinterNative(handle, 1, info);

  int startPagePrinter(int handle) => _startPagePrinterNative(handle);

  int writePrinter(
    int handle,
    Pointer<Uint8> data,
    int length,
    Pointer<Uint32> written,
  ) =>
      _writePrinterNative(handle, data, length, written);

  int endPagePrinter(int handle) => _endPagePrinterNative(handle);

  int endDocPrinter(int handle) => _endDocPrinterNative(handle);

  int closePrinter(int handle) => _closePrinterNative(handle);
}
