import 'dart:async';

typedef WatchdogRecovery = Future<void> Function();

class ScanWatchdog {
  ScanWatchdog({
    required this.onRecover,
    this.checkInterval = const Duration(seconds: 5),
    this.stallThreshold = const Duration(seconds: 15),
    this.cooldown = const Duration(seconds: 20),
  });

  final WatchdogRecovery onRecover;
  final Duration checkInterval;
  final Duration stallThreshold;
  final Duration cooldown;

  Timer? _timer;

  bool _enabled = false;
  bool _recovering = false;

  DateTime? _lastSeenAt;
  DateTime? _lastRecoverAt;

  void start() {
    if (_enabled) return;
    _enabled = true;

    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => _tick());
  }

  void stop() {
    _enabled = false;
    _timer?.cancel();
    _timer = null;
    _recovering = false;
  }

  void markSeen() {
    _lastSeenAt = DateTime.now();
  }

  void resetSession() {
    _lastSeenAt = DateTime.now();
  }

  Future<void> _tick() async {
    if (!_enabled) return;
    if (_recovering) return;

    final now = DateTime.now();

    final lastSeen = _lastSeenAt;
    if (lastSeen == null) return;

    final silence = now.difference(lastSeen);
    if (silence < stallThreshold) return;

    final lastRecover = _lastRecoverAt;
    if (lastRecover != null && now.difference(lastRecover) < cooldown) {
      return;
    }

    _recovering = true;
    _lastRecoverAt = now;

    try {
      await onRecover();
      _lastSeenAt = DateTime.now();
    } finally {
      _recovering = false;
    }
  }

  void dispose() {
    stop();
  }
}