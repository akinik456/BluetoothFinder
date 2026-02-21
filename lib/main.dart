import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const BluetoothFinderApp());
}

class BluetoothFinderApp extends StatelessWidget {
  const BluetoothFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  bool isScanning = false;

  late final AnimationController _sweepCtrl;
  late final AnimationController _pulseCtrl;

  StreamSubscription<List<ScanResult>>? _scanSub;

  // latest scan results
  final Map<String, ScanResult> _latest = {};

  // last seen timestamp (ms)
  final Map<String, int> _lastSeenMs = {};

  // UI ordering (authoritative)
  final List<String> _orderIds = [];

  // expanded (only one)
  String? _expandedId;

  // periodic UI tick so "OUT OF RANGE" updates even if no new packets arrive
  Timer? _tick;

  // Tuning knobs
  static const int staleAfterMs = 2500; // 2.5s -> OUT OF RANGE
  static const int dropAfterMs = 12000; // 12s -> remove from list (while scanning)

  @override
  void initState() {
    super.initState();

    _sweepCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final r in results) {
        final id = r.device.remoteId.str;
        final isNew = !_latest.containsKey(id);

        _latest[id] = r;
        _lastSeenMs[id] = now;

        // If we are in LOCK mode (expanded open), keep list stable:
        // new devices should append to end (not sorted)
        if (_expandedId != null && isNew) {
          _orderIds.add(id);
        }
      }

      // remove ids that no longer exist (safety)
      _orderIds.removeWhere((id) => !_latest.containsKey(id));
      _lastSeenMs.removeWhere((id, _) => !_latest.containsKey(id));

      // ordering policy:
      if (_expandedId == null) {
        // Normal mode: RSSI sort
        final sorted = _latest.values.toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        _orderIds
          ..clear()
          ..addAll(sorted.map((e) => e.device.remoteId.str));
      } else {
        // LOCK mode: keep existing order, only pin expanded on top
        final ex = _expandedId!;
        _orderIds.remove(ex);
        _orderIds.insert(0, ex);
      }

      if (mounted) setState(() {});
    });

    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      if (!isScanning) return;
      // This forces rebuild so stale/out-of-range states can change
      setState(() {});
    });
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _tick?.cancel();
    _sweepCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // ---------- RSSI -> UI helpers ----------

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return const Color(0xFF22C55E); // green
    if (rssi >= -75) return const Color(0xFF06B6D4); // cyan
    if (rssi >= -90) return const Color(0xFFF59E0B); // amber
    return const Color(0xFFEF4444); // red
  }

  double _rssiToFill(int rssi) {
    // map -100..-45 => 0..1 (close = 1)
    final clamped = rssi.clamp(-100, -45);
    return (clamped + 100) / 55.0;
  }

  String _rssiToDistanceLabel(int rssi) {
    // UX label only (not meters)
    if (rssi >= -55) return "VERY CLOSE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -75) return "MEDIUM";
    if (rssi >= -85) return "FAR";
    return "VERY FAR";
  }

  // ---------- Permissions + Scan ----------

  Future<void> _ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();

    if (!scan.isGranted || !connect.isGranted) {
      throw Exception("Bluetooth permission denied");
    }
  }

  Future<void> _startScan() async {
    await _ensurePermissions();

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      throw Exception("Bluetooth is OFF");
    }

    // reset
    _latest.clear();
    _lastSeenMs.clear();
    _orderIds.clear();
    _expandedId = null;

    await FlutterBluePlus.startScan(
      continuousUpdates: true, // RSSI updates continuously
      continuousDivisor: 1, // fastest UI update (more CPU)
      androidScanMode: AndroidScanMode.lowLatency, // aggressive scan
    );
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  Future<void> _toggleScan() async {
    try {
      if (!isScanning) {
        setState(() => isScanning = true);
        _sweepCtrl.repeat();
        _pulseCtrl.repeat();
        await _startScan();
      } else {
        setState(() => isScanning = false);
        _sweepCtrl.stop();
        _pulseCtrl.stop();
        await _stopScan();
        // tiny delay helps Android stack settle before a quick restart
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => isScanning = false);
      _sweepCtrl.stop();
      _pulseCtrl.stop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("$e")),
      );
    }
  }

  // ---------- Ordering mode switches ----------

  void _openOrCloseCard(String id) {
    setState(() {
      if (_expandedId == id) {
        // close -> back to RSSI sort
        _expandedId = null;

        final sorted = _latest.values.toList()
          ..sort((a, b) => b.rssi.compareTo(a.rssi));
        _orderIds
          ..clear()
          ..addAll(sorted.map((e) => e.device.remoteId.str));
      } else {
        // open -> LOCK mode (disable sorting), pin selected to top
        _expandedId = id;

        // If order is empty (first tap happened before any ordering), seed it:
        if (_orderIds.isEmpty) {
          _orderIds.addAll(_latest.keys);
        }

        _orderIds.remove(id);
        _orderIds.insert(0, id);
      }
    });
  }

  bool _isStale(String id, int now) {
    final last = _lastSeenMs[id] ?? 0;
    return (now - last) > staleAfterMs;
  }

  bool _isDead(String id, int now) {
    final last = _lastSeenMs[id] ?? 0;
    return (now - last) > dropAfterMs;
  }

  void _dropDevice(String id) {
    _latest.remove(id);
    _lastSeenMs.remove(id);
    _orderIds.remove(id);
    if (_expandedId == id) _expandedId = null;
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );

    final now = DateTime.now().millisecondsSinceEpoch;

    // build devices list from authoritative ordering
    final devices = <ScanResult>[];
    for (final id in List<String>.from(_orderIds)) {
      final r = _latest[id];
      if (r == null) continue;

      // While scanning: if device hasn't been seen for too long, drop it.
      if (isScanning && _isDead(id, now)) {
        _dropDevice(id);
        continue;
      }

      devices.add(r);
    }

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0B1220),
              Color(0xFF0A1B2A),
              Color(0xFF0B1220),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0xFF35D0FF),
                  width: 1.6,
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x2235D0FF),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Full-screen radar background (scan on)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: isScanning ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 250),
                        child: AnimatedBuilder(
                          animation: Listenable.merge([_sweepCtrl, _pulseCtrl]),
                          builder: (context, _) {
                            return CustomPaint(
                              painter: _FullScreenRadarPainter(
                                sweepT: _sweepCtrl.value,
                                pulseT: _pulseCtrl.value,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Title
                        _GlassPanel(
                          height: 68,
                          child: Center(
                            child: Text(
                              "BluetoothFinder",
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.95),
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),

                        // Toggle
                        _GlassPanel(
                          height: 92,
                          child: Center(
                            child: _ScanToggleButton(
                              isOn: isScanning,
                              onTap: _toggleScan,
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),

                        // List
                        Expanded(
                          child: _GlassPanel(
                            height: double.infinity,
                            child: devices.isEmpty
                                ? const SizedBox()
                                : ListView.builder(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    itemCount: devices.length,
                                    itemBuilder: (context, i) {
                                      final r = devices[i];
                                      final id = r.device.remoteId.str;
                                      final name = (r.device.platformName).trim();
                                      final title = name.isEmpty ? "Unknown" : name;

                                      final isOpen = (_expandedId == id);
                                      final adv = r.advertisementData;

                                      final stale = _isStale(id, now);

                                      // What we DISPLAY if stale
                                      final barFill = stale ? 0.0 : _rssiToFill(r.rssi);
                                      final barColor = stale
                                          ? Colors.white.withOpacity(0.25)
                                          : _rssiColor(r.rssi);
                                      final barLabel = stale ? "OUT OF RANGE" : _rssiToDistanceLabel(r.rssi);
                                      final displayRssi = stale ? -999 : r.rssi;

                                      // also fade the whole card slightly when stale
                                      final cardAlpha = stale ? 0.55 : 1.0;

                                      return Opacity(
                                        opacity: cardAlpha,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 8,
                                          ),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(16),
                                            onTap: () => _openOrCloseCard(id),
                                            child: AnimatedContainer(
                                              duration: const Duration(milliseconds: 180),
                                              curve: Curves.easeOut,
                                              padding: const EdgeInsets.all(14),
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(16),
                                                color: const Color(0xFF0E2436).withOpacity(0.55),
                                                border: Border.all(
                                                  color: isOpen
                                                      ? const Color(0xFF35D0FF).withOpacity(0.90)
                                                      : const Color(0xFF35D0FF).withOpacity(0.30),
                                                  width: isOpen ? 1.6 : 1.2,
                                                ),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: isOpen
                                                        ? const Color(0x2235D0FF)
                                                        : const Color(0x16000000),
                                                    blurRadius: isOpen ? 18 : 10,
                                                    offset: const Offset(0, 10),
                                                  ),
                                                ],
                                              ),
                                              child: Column(
                                                children: [
                                                  // Top row: Name + RSSI
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          title,
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontWeight: FontWeight.w800,
                                                            fontSize: 17,
                                                          ),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 10),
                                                      Text(
                                                        stale ? "—" : "${r.rssi}",
                                                        style: TextStyle(
                                                          color: stale
                                                              ? Colors.white.withOpacity(0.35)
                                                              : _rssiColor(r.rssi),
                                                          fontWeight: FontWeight.w900,
                                                          fontSize: 17,
                                                        ),
                                                      ),
                                                    ],
                                                  ),

                                                  const SizedBox(height: 6),

                                                  // ID row + chevron
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          id,
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: TextStyle(
                                                            color: Colors.white.withOpacity(0.70),
                                                            fontSize: 13.5,
                                                            fontWeight: FontWeight.w600,
                                                          ),
                                                        ),
                                                      ),
                                                      Icon(
                                                        isOpen ? Icons.expand_less : Icons.expand_more,
                                                        color: Colors.white.withOpacity(0.65),
                                                        size: 20,
                                                      ),
                                                    ],
                                                  ),

                                                  // Expanded bar
                                                  AnimatedCrossFade(
                                                    firstChild: const SizedBox(height: 0),
                                                    secondChild: Padding(
                                                      padding: const EdgeInsets.only(top: 12),
                                                      child: Container(
                                                        width: double.infinity,
                                                        padding: const EdgeInsets.all(12),
                                                        decoration: BoxDecoration(
                                                          borderRadius: BorderRadius.circular(12),
                                                          color: const Color(0xFF101B2B).withOpacity(0.65),
                                                          border: Border.all(
                                                            color: const Color(0xFF35D0FF).withOpacity(0.25),
                                                            width: 1,
                                                          ),
                                                        ),
                                                        child: Column(
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          children: [
                                                            _SignalBar(
                                                              fill: barFill,
                                                              color: barColor,
                                                              label: barLabel,
                                                              rssi: displayRssi,
                                                            ),
                                                            const SizedBox(height: 10),
                                                            _kv("Connectable", adv.connectable ? "Yes" : "No"),
                                                            _kv("Tx Power", "${adv.txPowerLevel ?? 'N/A'}"),
                                                            _kv(
                                                              "Service UUIDs",
                                                              adv.serviceUuids.isEmpty ? "—" : adv.serviceUuids.join(", "),
                                                            ),
                                                            _kv(
                                                              "Manufacturer",
                                                              adv.manufacturerData.isEmpty
                                                                  ? "—"
                                                                  : adv.manufacturerData.keys.toList().join(", "),
                                                            ),
                                                            _kv(
                                                              "Last seen",
                                                              "${((_lastSeenMs[id] ?? now) - now).abs() ~/ 1000}s ago",
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                    crossFadeState: isOpen
                                                        ? CrossFadeState.showSecond
                                                        : CrossFadeState.showFirst,
                                                    duration: const Duration(milliseconds: 180),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _kv(String k, String v) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            k,
            style: TextStyle(
              color: Colors.white.withOpacity(0.55),
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: TextStyle(
              color: Colors.white.withOpacity(0.90),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SignalBar extends StatelessWidget {
  final double fill; // 0..1
  final Color color;
  final String label;
  final int rssi;

  const _SignalBar({
    required this.fill,
    required this.color,
    required this.label,
    required this.rssi,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (fill.clamp(0.0, 1.0) * 100).round();

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF0B1220).withOpacity(0.35),
        border: Border.all(
          color: color.withOpacity(0.35),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                rssi == -999 ? "—" : "$rssi dBm",
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 10,
              color: Colors.white.withOpacity(0.08),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fill.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: color,
                      boxShadow: [
                        BoxShadow(
                          color: color.withOpacity(0.35),
                          blurRadius: 12,
                          spreadRadius: 1,
                        )
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            "$pct% signal strength",
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  final double height;
  final Widget child;

  const _GlassPanel({required this.height, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101B2B), Color(0xFF0E2436)],
        ),
        border: Border.all(
          color: const Color(0xFF35D0FF).withOpacity(0.55),
          width: 1.4,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 14,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ScanToggleButton extends StatelessWidget {
  final bool isOn;
  final FutureOr<void> Function() onTap;

  const _ScanToggleButton({required this.isOn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = isOn ? const Color(0xFFEF4444) : const Color(0xFF35D0FF);
    final label = isOn ? "Stop Scan" : "Start Scan";

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => onTap(),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: bg.withOpacity(0.25),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.25),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF071018),
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FullScreenRadarPainter extends CustomPainter {
  final double sweepT; // 0..1
  final double pulseT; // 0..1

  _FullScreenRadarPainter({required this.sweepT, required this.pulseT});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.5, size.height * 0.42);
    final r = math.min(size.width, size.height) * 0.62;

    const base = Color(0xFF35D0FF);

    // “wow” but still background
    final faint = base.withOpacity(0.10);
    final mid = base.withOpacity(0.18);
    final strong = base.withOpacity(0.28);

    final fog = Paint()..color = Colors.black.withOpacity(0.05);
    canvas.drawRect(Offset.zero & size, fog);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = faint;

    for (final k in [0.20, 0.40, 0.60, 0.80, 1.00]) {
      canvas.drawCircle(c, r * k, ringPaint);
    }

    final crossPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = faint;

    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), crossPaint);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), crossPaint);

    final p = (pulseT % 1.0);
    final pulseRadius = r * (0.15 + 0.95 * p);
    final pulseOpacity = (1.0 - p) * 0.18;

    final pulsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = base.withOpacity(pulseOpacity);

    canvas.drawCircle(c, pulseRadius, pulsePaint);

    final startAngle = (sweepT * 2 * math.pi) - math.pi / 2;
    const sweepAngle = math.pi / 3.4;

    final rect = Rect.fromCircle(center: c, radius: r);

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          base.withOpacity(0.00),
          base.withOpacity(0.22),
          base.withOpacity(0.00),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    canvas.drawArc(rect, startAngle, sweepAngle, true, sweepPaint);

    final outerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = mid;
    canvas.drawCircle(c, r, outerPaint);

    final dotPaint = Paint()..color = strong;
    canvas.drawCircle(c, 3.0, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _FullScreenRadarPainter oldDelegate) {
    return oldDelegate.sweepT != sweepT || oldDelegate.pulseT != pulseT;
  }
}