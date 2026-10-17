import 'dart:async';

/// Coalesces saves, resumes and remote notifications into non-overlapping runs.
class LiveSync {
  LiveSync({
    required this.sync,
    required Stream<int> pending,
    this.interval = const Duration(seconds: 5),
    this.debounce = const Duration(milliseconds: 300),
  }) {
    _subscription = pending.listen((count) {
      if (count > 0) request();
    });
  }
  final Future<void> Function() sync;
  final Duration interval;
  final Duration debounce;
  late final StreamSubscription<int> _subscription;
  Timer? _poll;
  Timer? _save;
  bool _active = false;
  bool _disposed = false;
  bool _running = false;
  bool _again = false;

  void resume() {
    if (_disposed || _active) return;
    _active = true;
    _poll = Timer.periodic(interval, (_) => request(immediate: true));
    request(immediate: true);
  }

  void pause() {
    _active = false;
    _poll?.cancel();
    _save?.cancel();
    _again = false;
  }

  void request({bool immediate = false}) {
    if (!_active || _disposed) return;
    if (_running) {
      _again = true;
      return;
    }
    _save?.cancel();
    _save = Timer(immediate ? Duration.zero : debounce, _run);
  }

  Future<void> _run() async {
    if (!_active || _disposed || _running) return;
    _running = true;
    try {
      await sync();
    } catch (_) {
      // Engine records failures; pending changes remain for the next retry.
    } finally {
      _running = false;
      if (_again) {
        _again = false;
        request();
      }
    }
  }

  void dispose() {
    _disposed = true;
    pause();
    unawaited(_subscription.cancel());
  }
}
