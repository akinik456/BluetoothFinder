import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// Global mute across Find Mode pages
ValueNotifier<bool> globalMute = ValueNotifier(false);
final Map<String, int> calibratedMaxById = {};

void main() {
  runApp(const FindLostGadgetApp());
}

class BeepGuard {
  static int gen = 0;
  static bool enabled = true;

  static AudioPlayer? activePlayer;

  static void register(AudioPlayer p) {
    activePlayer = p;
  }

  static void killNow() {
    enabled = false;
    gen++;
    // Çalanı da anında kes
    try { activePlayer?.stop(); } catch (_) {}
    try { activePlayer?.seek(Duration.zero); } catch (_) {}
  }

  static void arm() {
    enabled = true;
    gen++;
  }
}
// ===================== SAVED DEVICES (PERSISTENT) =====================

class SavedDevice {
  final String id;
  final String? name;
  final int savedAtMs;

  const SavedDevice({
    required this.id,
    required this.savedAtMs,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'savedAtMs': savedAtMs,
      };

  static SavedDevice fromJson(Map<String, dynamic> j) {
    return SavedDevice(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] as String?)?.toString(),
      savedAtMs: (j['savedAtMs'] is int)
          ? (j['savedAtMs'] as int)
          : int.tryParse('${j['savedAtMs']}') ?? 0,
    );
  }
}

class SavedStore {
  static const String _key = 'bluetoothfinder_saved_devices_v1';

  static Future<Map<String, SavedDevice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};

      final out = <String, SavedDevice>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item as Map);
        final d = SavedDevice.fromJson(m);
        if (d.id.isNotEmpty) out[d.id] = d;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<String, SavedDevice> map) async {
    final prefs = await SharedPreferences.getInstance();
    final list = map.values
        .map((d) => d.toJson())
        .toList(growable: false);

    await prefs.setString(_key, jsonEncode(list));
  }
}
class FindLostGadgetApp extends StatelessWidget {
  const FindLostGadgetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Find Lost Gadget",
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

// ===================== HOME =====================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
// === Auto Calibration Limits ===
double _minRssi = -100;     // zayıf sinyal tabanı
double _calMaxRssi = -45;   // kalibre edilmiş en güçlü sinyal
  bool isScanning = false;

  late final AnimationController _sweepCtrl;
  late final AnimationController _pulseCtrl;

  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  Timer? _tick;

  final Map<String, ScanResult> _latest = {};
  final Map<String, int> _lastSeenMs = {};

  // RSSI smoothing (EMA)
  final Map<String, double> _rssiEma = {};

  // Ordering
  final List<String> _orderIds = [];
  String? _expandedId;

  // Stability thresholds
  static const int staleAfterMs = 5000;
  static const int dropAfterMs = 30000;
  
  Map<String, SavedDevice> _saved = {};  

    final Set<String> _seenThisSession = <String>{};
	
	Timer? _watchdog;
	int _lastPacketMs = 0; // en son scanResults callback geldiği an
	bool _restartBusy = false;
	bool _scanToggleBusy = false;

@override
  void initState() {
    super.initState();
	WidgetsBinding.instance.addObserver(this);
    _seenThisSession.clear();
    _sweepCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

    // Keep UI in sync with the plugin's real scan state
    _isScanningSub = FlutterBluePlus.isScanning.listen((v) {
      if (!mounted) return;
      setState(() => isScanning = v);
      if (v) {
        if (!_sweepCtrl.isAnimating) _sweepCtrl.repeat();
        if (!_pulseCtrl.isAnimating) _pulseCtrl.repeat();
      } else {
        if (_sweepCtrl.isAnimating) _sweepCtrl.stop();
        if (_pulseCtrl.isAnimating) _pulseCtrl.stop();
      }
    });

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
		final now=DateTime.now().millisecondsSinceEpoch;
      _lastPacketMs = now;
	  
      for (final r in results) {
        final id = r.device.remoteId.str;


        _seenThisSession.add(id);
        _latest[id] = r;
        _lastSeenMs[id] = now;

        // --- EMA smoothing ---
        const double alpha = 0.25; // 0.15 smoother, 0.33 faster
        final raw = r.rssi.toDouble();
        final prev = _rssiEma[id];
        _rssiEma[id] = (prev == null) ? raw : (alpha * raw) + ((1 - alpha) * prev);
      }
	  
	  

      // housekeeping
      _orderIds.removeWhere((id) => !_latest.containsKey(id));
      _lastSeenMs.removeWhere((id, _) => !_latest.containsKey(id));
      _rssiEma.removeWhere((id, _) => !_latest.containsKey(id));

      // sorting policy:
      // If a card is open, pin it to top and disable sorting (keep the rest stable)
      if (_expandedId == null) {
        final entries = _latest.entries.toList();
                entries.sort((a, b) {
          final aSaved = _saved.containsKey(a.key);
          final bSaved = _saved.containsKey(b.key);
          if (aSaved != bSaved) return aSaved ? -1 : 1;

          final ar = (_rssiEma[a.key]?.round()) ?? a.value.rssi;
          final br = (_rssiEma[b.key]?.round()) ?? b.value.rssi;
          return br.compareTo(ar);
        });
        _orderIds
          ..clear()
          ..addAll(entries.map((e) => e.key));
      } else {
        final ex = _expandedId!;
        if (_orderIds.isEmpty) _orderIds.addAll(_latest.keys);
        _orderIds.remove(ex);
        _orderIds.insert(0, ex);
      }

      if (mounted) setState(() {});
    });

    _tick = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      if (!isScanning) return;
      setState(() {});
    });
	
  unawaited(_loadSaved());	
  }
  Future<void> _loadSaved() async {
    final loaded = await SavedStore.load();
    if (!mounted) return;
    setState(() => _saved = loaded);
  }  
  

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanningSub?.cancel();
    _tick?.cancel();
    _sweepCtrl.dispose();
    _pulseCtrl.dispose();
	WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // -------- logic helpers --------

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
    _rssiEma.remove(id);
    _orderIds.remove(id);
    if (_expandedId == id) _expandedId = null;
  }
Future<void> _stopEverythingFromLifecycle() async {
  // UI'ı anında OFF yap
  if (mounted && isScanning) {
    setState(() => isScanning = false);
  }

  // Tarama gerçekten dursun
  try {
    await FlutterBluePlus.stopScan();
	debugPrint("stop called2");
  } catch (_) {}
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  // Home basıldı -> paused
  // Tuş kilidi / geçiş anı -> inactive
  if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
    unawaited(_stopEverythingFromLifecycle());
    return;
  }

  if (state == AppLifecycleState.resumed) {
    // Geri gelince OFF kalsın (garanti)
    if (mounted && isScanning) setState(() => isScanning = false);
  }
}
  Color _rssiColor(int rssi) {
    if (rssi >= -60) return const Color(0xFF22C55E);
    if (rssi >= -75) return const Color(0xFF06B6D4);
    if (rssi >= -90) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }


  double _rssiToFill(int rssi) {
    final minRssi = _minRssi;
    var maxRssi = _calMaxRssi;
    if (maxRssi <= minRssi + 1) maxRssi = minRssi + 1;

    final clamped = rssi.clamp(minRssi, maxRssi);
    return (clamped - minRssi) / (maxRssi - minRssi);
  }

  String _rssiToDistanceLabel(int rssi) {
    if (rssi >= -55) return "VERY CLOSE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -75) return "MEDIUM";
    if (rssi >= -85) return "FAR";
    return "VERY FAR";
  }

  

void _toggleExpanded(String id) {
  setState(() {
    _expandedId = (_expandedId == id) ? null : id;
  });
}

Widget _buildDeviceCard(String id, ScanResult? r, int now) {
  final saved = _saved[id];
  final isSaved = saved != null;

  final seenThisSession = _seenThisSession.contains(id);

  final hasEverBeenSeen = _lastSeenMs.containsKey(id);
  final stale = hasEverBeenSeen ? _isDead(id, now) : false;

  final smooth = _rssiEma[id];
  final smoothRssi = (smooth == null) ? r?.rssi : smooth.round();

  final String title = (() {
    final n = r?.device.platformName.trim();
    if (n != null && n.isNotEmpty) return n;
    final sn = saved?.name?.trim();
    if (sn != null && sn.isNotEmpty) return sn;
    return "Unknown";
  })();

  final Color accent = (smoothRssi == null)
      ? Colors.white.withValues(alpha: 0.35)
      : _rssiColor(smoothRssi);

  final String distanceLabel = isSaved && !seenThisSession
      ? "NOT SEEN THIS SESSION"
      : (stale
          ? "OUT OF RANGE"
          : (smoothRssi == null ? "—" : _rssiToDistanceLabel(smoothRssi)));

  final double barFill = (smoothRssi == null) ? 0.0 : _rssiToFill(smoothRssi);

  final int? lastSeenMs = _lastSeenMs[id];
  var lastSeenSeconds =
      (lastSeenMs == null) ? 9999 : ((now - lastSeenMs) / 1000).round();
  if (lastSeenSeconds < 0) lastSeenSeconds = 0;

  final adv = r?.advertisementData;

  final details = (_expandedId == id)
      ? _DeviceDetails(
          connectable: adv?.connectable ?? false,
          txPower: adv?.txPowerLevel,
          uuids: adv?.serviceUuids ?? const [],
          manufacturerIds: adv?.manufacturerData.keys.toList() ?? const [],
          lastSeenSeconds: lastSeenSeconds,
          isSaved: isSaved,
          onToggleSaved: () => _toggleSaved(id: id, name: title),
        )
      : null;

  return _DeviceCardPlayful(
    title: title,
    id: id,
    accent: accent,
    stale: stale,
    rssi: smoothRssi,
    distanceLabel: distanceLabel,
    barFill: barFill,
    isOpen: _expandedId == id,
    onTap: () => _toggleExpanded(id),
    onLongPress: () {
      if (r == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("NOT SEEN THIS SESSION")),
        );
        return;
      }
      _enterFindMode(r);
    },
    details: details,
    isSaved: isSaved,
    onToggleSaved: () => _toggleSaved(id: id, name: title),
  );
}

// -------- permissions + scanning --------

  Future<void> _ensurePermissions() async {
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();

    // Some Android stacks still require location for BLE discovery
    await Permission.locationWhenInUse.request();

    if (!scan.isGranted || !connect.isGranted) {
      throw Exception("Bluetooth permission denied");
    }
  }
  
  bool _scanWanted = false;

  Future<void> _startScan() async {
  debugPrint("WDT: started");
  _scanWanted = true;
  BeepGuard.arm();
    await _ensurePermissions();

    // Ensure Bluetooth is ON (Android can prompt via system dialog)
    if (Platform.isAndroid) {
      final st = FlutterBluePlus.adapterStateNow;
      if (st != BluetoothAdapterState.on) {
        try {
          await FlutterBluePlus.turnOn();
        } catch (_) {
          // ignore; we'll verify state below
        }

        // wait a bit for adapter to fully turn on
        try {
          await FlutterBluePlus.adapterState
              .where((s) => s == BluetoothAdapterState.on)
              .first
              .timeout(const Duration(seconds: 8));
        } on TimeoutException {
          throw Exception("Bluetooth is OFF");
        }
      }
    } else {
      // iOS cannot programmatically enable Bluetooth; just verify state
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception("Bluetooth is OFF");
      }
    }

    _latest.clear();
    _lastSeenMs.clear();
    _rssiEma.clear();
    _orderIds.clear();
    _expandedId = null;
	try{
    await FlutterBluePlus.startScan(
      continuousUpdates: true,
      continuousDivisor: 1,
      androidScanMode: AndroidScanMode.lowLatency,
    );
	}catch(e){
	debugPrint("startscan error:$e");
	return;
	}
	
	// WATCHDOG START
_watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      debugPrint("WDT: tick");
      if (!_scanWanted) return;

      final now = DateTime.now().millisecondsSinceEpoch;

      if (_lastPacketMs == 0 || (now - _lastPacketMs) > 12000) {
        _lastPacketMs = now; // cooldown to avoid spam
        _restartScanSoft("watchdog_no_packets");
      }
    });

  }

  Future<void> _stopScan() async {
  debugPrint("stop called");
  _scanWanted = false;
  BeepGuard.killNow();
    await FlutterBluePlus.stopScan();
  _watchdog?.cancel();
  _watchdog = null;	
  }

  Future<void> _toggleScan() async {
  if (_scanToggleBusy) return;
  _scanToggleBusy = true;
  try {
    if (!isScanning) {
      await _startScan();
    } else {
      await _stopScan();
      debugPrint("stop called3");
    }
  } catch (e) {
    if (!mounted) return;
    // In case plugin state didn't update yet, force UI to idle.
    setState(() => isScanning = false);
    if (_sweepCtrl.isAnimating) _sweepCtrl.stop();
    if (_pulseCtrl.isAnimating) _pulseCtrl.stop();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e")));
  } finally {
    _scanToggleBusy = false;
  }
}

Future<void> _restartScanSoft(String reason) async {
	debugPrint("WATCHDOG HIT : $reason");
  if (_restartBusy) return;
  _restartBusy = true;
  try {
  // Kullanıcı stop’a bastıysa geri açma
  if (!_scanWanted) return;

  // Log istersen:
  // debugPrint("scan restart: $reason");

  try {
    await FlutterBluePlus.stopScan();
	debugPrint("stop called4");
  } catch (e) {debugPrint("startScan error: $e");}

  await Future.delayed(const Duration(milliseconds: 800));

  
  if(!_scanWanted) return;

  // ⚠️ BURAYA mevcut _startScan içinde kullandığın startScan çağrısını birebir yapıştıracağız.
  // Şimdilik en basit hali:
  try {
    await FlutterBluePlus.startScan(continuousUpdates: true,
  continuousDivisor: 1,
  androidScanMode: AndroidScanMode.lowLatency,);
	debugPrint("start called");
    _lastPacketMs = DateTime.now().millisecondsSinceEpoch;
  } catch (e) {debugPrint("startScan error: $e");}
  } finally {
    _restartBusy = false;
  }
}

void _enterFindMode(ScanResult r) {
    if (!isScanning) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Start Scan first")));
      return;
    }

    final id = r.device.remoteId.str;
    final name = (r.device.platformName).trim();
    final title = name.isEmpty ? "Unknown" : name;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FindModePage(
          deviceId: id,
          deviceName: title,
        ),
      ),
    );
  }

  void _toggleDetails(String id) {
    setState(() {
      if (_expandedId == id) {
        _expandedId = null;

        // restore sorted order by smoothed rssi
        final entries = _latest.entries.toList();
        entries.sort((a, b) {
          final ar = (_rssiEma[a.key]?.round()) ?? a.value.rssi;
          final br = (_rssiEma[b.key]?.round()) ?? b.value.rssi;
          return br.compareTo(ar);
        });
        _orderIds
          ..clear()
          ..addAll(entries.map((e) => e.key));
      } else {
        _expandedId = id;
        if (_orderIds.isEmpty) _orderIds.addAll(_latest.keys);
        _orderIds.remove(id);
        _orderIds.insert(0, id);
      }
    });
  }
    bool _isSaved(String id) => _saved.containsKey(id);

    Future<void> _toggleSaved({required String id, required String? name}) async {
    final next = Map<String, SavedDevice>.from(_saved);

    final wasSaved = next.containsKey(id);
    if (wasSaved) {
      next.remove(id);
    } else {
      next[id] = SavedDevice(
        id: id,
        name: (name ?? '').trim().isEmpty ? null : name!.trim(),
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }

    // Haptic: subtle, consistent
    HapticFeedback.heavyImpact();

    setState(() => _saved = next);
    await SavedStore.save(next);
  }
  // -------- UI --------

  @override
  Widget build(BuildContext context) {
	final now=DateTime.now().millisecondsSinceEpoch;
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );

    final visibleIds = <String>{
  ..._orderIds,
  ..._saved.keys,
}.toList();
final visibleResults = <String, ScanResult?>{};
for (final id in visibleIds) {
  final r = _latest[id];

  if (isScanning && _isDead(id, now) && !_saved.containsKey(id)) {
    _dropDevice(id);
    continue;
  }

  // r null olabilir (scan görmedi), ama saved ise yine de listede kalacak
  if (r != null || _saved.containsKey(id)) {
    visibleResults[id] = r;
  }
}

	final sortedIds = visibleResults.keys.toList()
	 ..sort((a, b) {
		final aSaved = _saved.containsKey(a);
		final bSaved = _saved.containsKey(b);

		// 1️⃣ Saved üstte
		if (aSaved != bSaved) {
		return aSaved ? -1 : 1;
		}

		// 2️⃣ RSSI varsa güçlü olan üste
		final aRssi = visibleResults[a]?.rssi ?? -999;
		final bRssi = visibleResults[b]?.rssi ?? -999;

		return bRssi.compareTo(aRssi);
	});
	
	final savedIds = sortedIds.where((id) => _saved.containsKey(id)).toList();
	final nearbyIds = sortedIds.where((id) => !_saved.containsKey(id)).toList();	
	
    return Scaffold(
      body: Stack(
        children: [
          // Background
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF081018),
                    Color(0xFF081A24),
                    Color(0xFF070E14),
                  ],
                ),
              ),
            ),
          ),

          // Ambient radar background while scanning
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

          SafeArea(
            child: Column(
              children: [
                // Header (playful)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: _HeaderPlayful(
                    isScanning: isScanning,
                    deviceCount: visibleResults.length,
                  ),
                ),

                // Big primary scan button panel
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _ScanPanelPlayful(
                    isScanning: isScanning,
                    onToggle: _toggleScan,
                  ),
                ),
				const SizedBox(height: 6),

Padding(
  padding: const EdgeInsets.symmetric(horizontal: 16),
  child: Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Text(
        "Tap for details",
        maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        "•",
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.35),
        ),
      ),
      const SizedBox(width: 8),
      Text(
        "Hold to find",
        maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
        ),
      ),
    ],
  ),
),


	
  const SizedBox(height: 6),
// Device list
Expanded(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: visibleResults.isEmpty
        ? _EmptyStatePlayful(isScanning: isScanning)
        : ListView(
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            children: [
              if (savedIds.isNotEmpty) ...[
                const _SectionHeader(title: "SAVED"),
                for (final id in savedIds)
                  _buildDeviceCard(id, visibleResults[id], now),
              ],
              if (nearbyIds.isNotEmpty) ...[
                const _SectionHeader(title: "NEARBY"),
                for (final id in nearbyIds)
                  _buildDeviceCard(id, visibleResults[id], now),
              ],
            ],
          ),
  ),
),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
          color: Colors.white70,
        ),
      ),
    );
  }
}

// ===================== FIND MODE =====================

class FindModePage extends StatefulWidget {
  final String deviceId;
  final String deviceName;

  const FindModePage({
    super.key,
    required this.deviceId,
    required this.deviceName,
  });

  @override
  State<FindModePage> createState() => _FindModePageState();
}

class _FindModePageState extends State<FindModePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // RSSI smoothing in find mode too
  double? _ema;
  int? _rssi;

  int _lastSeenMs = 0;
  int _lastPulseMs = 0;

  StreamSubscription<List<ScanResult>>? _sub;
  Timer? _tick;

  late final AnimationController _sweepCtrl;
  late final AnimationController _pulseCtrl;

  late final AudioPlayer _player;
  bool _audioReady = false;

  static const int staleAfterMs = 3500;

  // ===== Auto-calibration =====
  static const int _minRssi = -85; // left side label (far reference)
  final int _calWindowMs = 2000; // 2s calibration window
  final int _calMarginDb = 6; // headroom above peak
  int _calStartMs = 0;
  
  int _calPeakRssi = -999; // best (highest) rssi observed
  int _calMaxRssi = -45; // dynamic right side label (near reference)
  bool _calibrating = true;

int _beepGen = 0; // kill-switch jenerasyonu
bool _beepEnabled = true;

  @override
  void initState() {
    super.initState();
WidgetsBinding.instance.addObserver(this);
	final now=DateTime.now().millisecondsSinceEpoch;
    // Restore best-so-far calibration if present
    final cached = calibratedMaxById[widget.deviceId];
    if (cached != null) {
      _calMaxRssi = cached;
      _calibrating = false;
    } else {
      // First entry: run a short calibration window to avoid a noisy first sample
      _calStartMs = now;
      _calPeakRssi = -999;
      _calibrating = true;
    }

    _sweepCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 1700))..repeat();
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 2300))..repeat();

    _player = AudioPlayer();
	BeepGuard.register(_player);
    _player.setReleaseMode(ReleaseMode.stop);
    _player.setVolume(1.0);

    _player.setSource(AssetSource('beep.wav')).then((_) {
      _audioReady = true;
    });
Future<void> _hardStopFindMode() async {
BeepGuard.killNow();
try { await _player.stop(); } catch (_) {}
try { await _player.seek(Duration.zero); } catch (_) {}

  // 1) Beep üretimini durdur (tick)
  _tick?.cancel();
  _tick = null;

  // 2) Scan sonuçlarını dinlemeyi kes (sub)
  await _sub?.cancel();
  _sub = null;

  // 3) Çalan sesi anında kes
  try { await _player.stop(); } catch (_) {}

  // 4) BLE scan'i durdur (Home zaten durduruyor ama garanti olsun)
  try { await FlutterBluePlus.stopScan(); } catch (_) {}
debugPrint("stop called5");
  // 5) UI/State'i sessize al (stale/son beep kalmasın)
  _ema = null;
  _rssi = null;
  _lastSeenMs = 0;
  _lastPulseMs = 0;

  if (mounted) setState(() {});
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
BeepGuard.killNow();
  if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
    unawaited(_hardStopFindMode());
    return;
  }

  if (state == AppLifecycleState.resumed) {
    // Geri gelince de OFF/sessiz kalsın -> hiçbir şey başlatmıyoruz.
  }
}

    _sub = FlutterBluePlus.scanResults.listen((results) {
	final now=DateTime.now().millisecondsSinceEpoch;
		_lastPacketMs=now;
      for (final r in results) {
        if (r.device.remoteId.str != widget.deviceId) continue;

        // EMA smoothing
        const double alpha = 0.25;
        final raw = r.rssi.toDouble();
        _ema = (_ema == null) ? raw : (alpha * raw) + ((1 - alpha) * _ema!);

        _rssi = _ema!.round();
        _lastSeenMs = now;

        // --- Auto calibration update (best-so-far) ---
        if (_rssi != null) {
          if (_calibrating) {
            if (_rssi! > _calPeakRssi) _calPeakRssi = _rssi!;

            final candidate = (_calPeakRssi + _calMarginDb).clamp(-45, -30);
            if (candidate > _calMaxRssi) _calMaxRssi = candidate;

            if (now - _calStartMs >= _calWindowMs) {
              _calibrating = false;
              _persistCalibrationIfBetter();
            }
          } else {
            // After initial window: keep upgrading if we ever see a better (closer) RSSI.
            final candidate = (_rssi! + _calMarginDb).clamp(-45, -30);
            if (candidate > _calMaxRssi) {
              _calMaxRssi = candidate;
              _persistCalibrationIfBetter();
            }
          }
        }

        break;
      }

      if (mounted) setState(() {});
    });
	
	
    _tick = Timer.periodic(const Duration(milliseconds: 60), (_) async {
	final now=DateTime.now().millisecondsSinceEpoch;
      if (!mounted) return;
      final hasSeen = _lastSeenMs != 0;
      final ageMs = hasSeen ? (now - _lastSeenMs) : 999999;
      final stale = ageMs > staleAfterMs;

      // If not seeing device -> SILENCE (invalidate RSSI)
      if (!hasSeen || stale || _rssi == null) {
        _rssi = null;
        return;
      }

      // Logarithmic mapping in [_minRssi .. _calMaxRssi]
      final progress = _rssiToLogProgress(_rssi!);
      final intervalMs = _progressToIntervalMs(progress);
      final volume = _progressToVolume(progress);

      if (now - _lastPulseMs >= intervalMs) {
        _lastPulseMs = now;

        final int g = BeepGuard.gen;


print("BEEP TRY enabled=${BeepGuard.enabled} gen=${BeepGuard.gen} ready=$_audioReady mute=${globalMute.value}");
if (!BeepGuard.enabled || globalMute.value || !_audioReady) return;

// Home/kilit tam arada geldiyse düşür
if (!BeepGuard.enabled || g != BeepGuard.gen) return;

await _player.setVolume(volume);

if (!BeepGuard.enabled || g != BeepGuard.gen) return;
await _player.stop();

if (!BeepGuard.enabled || g != BeepGuard.gen) return;
await _player.play(
    AssetSource('beep.wav'),
    volume: volume,
  );


      }
    });
  }

  void _persistCalibrationIfBetter() {
    final prev = calibratedMaxById[widget.deviceId];
    if (prev == null || _calMaxRssi > prev) {
      calibratedMaxById[widget.deviceId] = _calMaxRssi;
    }
  }


  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _player.dispose();
    _sweepCtrl.dispose();
    _pulseCtrl.dispose();
	WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // --- mapping helpers (log) ---

  double _clamp01(double x) => x < 0 ? 0 : (x > 1 ? 1 : x);

  /// RSSI -> progress (0..1) using dynamic max RSSI from calibration
  double _rssiToLogProgress(int rssi) {
    final minRssi = _minRssi;
    final maxRssi = _calMaxRssi; // dynamic near reference

    final x = _clamp01((rssi - minRssi) / (maxRssi - minRssi));

    const double k = 9.0; // bigger => more kick near close range
    return math.log(1 + k * x) / math.log(1 + k);
  }

  int _progressToIntervalMs(double p) {
    const int far = 1100;
    const int near = 90;
    return (far - (far - near) * p).round();
  }

  double _progressToVolume(double p) {
    const double vMin = 0.15;
    const double vMax = 1.0;
    return (vMin + (vMax - vMin) * p).clamp(0.0, 1.0);
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return const Color(0xFF22C55E);
    if (rssi >= -75) return const Color(0xFF06B6D4);
    if (rssi >= -90) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }


  double _rssiToFillFind(int rssi) {
    final minRssi = _minRssi;
    var maxRssi = _calMaxRssi;
    if (maxRssi <= minRssi + 1) maxRssi = minRssi + 1;

    final clamped = rssi.clamp(minRssi, maxRssi);
    return (clamped - minRssi) / (maxRssi - minRssi);
  }

  String _rssiToDistanceLabel(int rssi) {
    if (rssi >= -55) return "VERY CLOSE";
    if (rssi >= -65) return "CLOSE";
    if (rssi >= -75) return "MEDIUM";
    if (rssi >= -85) return "FAR";
    return "VERY FAR";
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
	final now=DateTime.now().millisecondsSinceEpoch;
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    final hasSeen = _lastSeenMs != 0;
    final ageMs = hasSeen ? (now - _lastSeenMs) : 999999;
    final stale = ageMs > staleAfterMs;

    final show = (!stale && _rssi != null);
    final rssi = _rssi ?? -999;

    final fill = show ? _rssiToFillFind(rssi) : 0.0;
    final color = show ? _rssiColor(rssi) : Colors.white.withValues(alpha: 0.18);
    final label = show ? _rssiToDistanceLabel(rssi) : "OUT OF RANGE";

    return Scaffold(
      body: Stack(
        children: [
          // playful background
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF081018), Color(0xFF071B2A), Color(0xFF070E14)],
                ),
              ),
            ),
          ),

          // Ambient radar
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_sweepCtrl, _pulseCtrl]),
                builder: (_, __) {
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

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      _IconPill(
                        icon: Icons.arrow_back,
                        onTap: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.deviceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18.5,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ValueListenableBuilder<bool>(
                        valueListenable: globalMute,
                        builder: (context, muted, _) {
                          return _IconPill(
                            icon: muted ? Icons.volume_off : Icons.volume_up,
                            onTap: () {
                              globalMute.value = !muted;
                              if (globalMute.value) {
                                _player.stop();
                              }
                              setState(() {});
                            },
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Main playful card
                  _PlayCard(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.92),
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ),
                            if (_calibrating)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: Colors.white.withValues(alpha: 0.06),
								  
                                ),
                                child: Text(
                                  "Calibrating…",
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          show ? "$rssi dBm" : "—",
                          style: TextStyle(
                            color: color,
                            fontSize: 48,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 14),

                        // ===== Test labels: min/max around bar =====
                        Row(
                          children: [
                            Text(
                              "$_minRssi",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              "$_calMaxRssi",
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),

                        // Classic bar (left -> right)
                        Container(
                          width: 320,
                          height: 18,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              width: 320 * fill,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(999),
                                color: color,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 12),
                        Text(
                          show ? "Last seen: ${(ageMs / 1000).toStringAsFixed(1)}s" : "Waiting for signal…",
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  ValueListenableBuilder<bool>(
                    valueListenable: globalMute,
                    builder: (_, muted, __) {
                      return Text(
                        muted
                            ? "Muted"
                            : "Beep gets faster & louder as you get closer",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== PLAYFUL UI COMPONENTS =====================

class _HeaderPlayful extends StatelessWidget {
  final bool isScanning;
  final int deviceCount;

  const _HeaderPlayful({
    required this.isScanning,
    required this.deviceCount,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = isScanning
        ? "Scanning • $deviceCount device${deviceCount == 1 ? "" : "s"}"
        : "Start scan to discover devices";

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF35D0FF).withValues(alpha: 0.18),
            const Color(0xFFB46BFF).withValues(alpha: 0.12),
            const Color(0xFF22C55E).withValues(alpha: 0.08),
          ],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 22, offset: Offset(0, 14)),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF35D0FF).withValues(alpha: 0.95),
                  const Color(0xFFB46BFF).withValues(alpha: 0.95),
                ],
              ),
            ),
            child: const Icon(Icons.radar, color: Color(0xFF071018)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
			  
                const Text(
                  "Find Lost Gadget",
                  style: TextStyle(
                    color: const Color(0xFF4FD1FF),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
				
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: globalMute,
            builder: (_, muted, __) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Colors.black.withValues(alpha: 0.25),
                ),
                child: Row(
                  children: [
                    Icon(
                      muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white.withValues(alpha: 0.82),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      muted ? "Muted" : "Sound",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontSize: 12.2,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _ScanPanelPlayful extends StatelessWidget {
  final bool isScanning;
  final FutureOr<void> Function() onToggle;

  const _ScanPanelPlayful({
    required this.isScanning,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final label = isScanning ? "Stop Scan" : "Start Scan";

    final grad = isScanning
        ? const LinearGradient(
            colors: [Color(0xFFEF4444), Color(0xFFF97316)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF35D0FF), Color(0xFFB46BFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withValues(alpha: 0.05),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 22, offset: Offset(0, 14)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isScanning ? "Tap to stop scanning" : "Tap to start scanning",
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () => onToggle(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: grad,
              ),
              child: Row(
                children: [
                  Icon(
                    isScanning ? Icons.stop_circle : Icons.play_circle,
                    color: const Color(0xFF071018),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Color(0xFF071018),
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyStatePlayful extends StatelessWidget {
  final bool isScanning;

  const _EmptyStatePlayful({required this.isScanning});

  @override
  Widget build(BuildContext context) {
    final text = isScanning ? "Searching nearby…" : "Start scan to see devices";

    return Container(
      decoration: BoxDecoration(
  borderRadius: BorderRadius.circular(22),
  color: Colors.white.withValues(alpha: 0.04),
  border: Border.all(
    color: Colors.white.withValues(alpha: 0.06),
  ),
  boxShadow: [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.25),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ],
),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.55),
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}




class _DeviceCardPlayful extends StatelessWidget {
  final String title;
  final String id;
  final Color accent;
  final bool stale;
  final int? rssi;
  final String distanceLabel;
  final double barFill;
  final bool isOpen;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final Widget? details;
  final bool isSaved;
  final VoidCallback onToggleSaved;
  
  const _DeviceCardPlayful({
    required this.title,
    required this.id,
    required this.accent,
    required this.stale,
    required this.rssi,
    required this.distanceLabel,
    required this.barFill,
    required this.isOpen,
    required this.onTap,
    required this.onLongPress,
    required this.details,
	required this.isSaved,
	required this.onToggleSaved,
	
  });

  @override
  Widget build(BuildContext context) {
    // bar width adapted to screen
	final barWidth = math.max(0.0, MediaQuery.of(context).size.width - 32 - 28);
   
   final r = BorderRadius.circular(22);

return _PressableScale(
  borderRadius: r,
  onTap: onTap,
  onLongPress: onLongPress,
  child: AnimatedContainer(
  duration: const Duration(milliseconds: 180),
  curve: Curves.easeOut,
  padding: const EdgeInsets.all(14),
  decoration: BoxDecoration(
  borderRadius: BorderRadius.circular(18),
  color: Colors.white.withValues(alpha: stale ? 0.05 : 0.08),
  border: Border(
    left: BorderSide(
      width: 3,
      color: isSaved ? const Color(0xFFFFD166) : Colors.transparent,
    ),
  ),
),
        child: Column(
          children: [
            Row(
              children: [
                  Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: accent.withValues(alpha: stale ? 0.14 : 0.22),
						boxShadow: [
  BoxShadow(
    color: accent.withValues(alpha: stale ? 0.10 : 0.22),
    blurRadius: stale ? 10 : 16,
    spreadRadius: stale ? 0 : 1,
  ),
],
                      ),
                      child: Icon(
                        Icons.bluetooth,
                        color: Colors.white.withValues(alpha: stale ? 0.35 : 0.85),
                        size: 20,
                      ),
                    ),
                    if (isSaved)
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                          child: const Icon(
                            Icons.star,
                            size: 14,
                            color: Color(0xFFFFD166),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: stale ? 0.65 : 0.95),
                          fontSize: 16.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        id,
  maxLines: 1,
  overflow: TextOverflow.ellipsis,
  style: TextStyle(
    fontSize: 11,
    letterSpacing: 0.4,
    color: Colors.white.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),

                // Quick-save (bookmark) button: DOES NOT open details
				  SizedBox(
                  width: 40,
                  height: 40,
                  child: IconButton(
                    onPressed: onToggleSaved,
                    tooltip: isSaved ? 'Saved' : 'Save',
                    padding: EdgeInsets.zero,
                    splashRadius: 22,
                    icon: Icon(
                      isSaved ? Icons.bookmark : Icons.bookmark_border,
                      size: 20,
                      color: isSaved
                          ? const Color(0xFFFFD166)
                          : Colors.white.withValues(alpha: stale ? 0.35 : 0.75),
                    ),
                  ),
                ),

                const SizedBox(width: 6),
                SizedBox(
                  width: 70,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                    Text(
                      rssi == null ? "—" : "$rssi",
                      style: TextStyle(
                        color: stale ? Colors.white.withValues(alpha: 0.35) : accent,
                        fontSize: 16.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      distanceLabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
				),
              ],
            ),
            const SizedBox(height: 12),

            // playful bar
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 10,
                color: Colors.white.withValues(alpha: 0.06),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AnimatedContainer(
  duration: const Duration(milliseconds: 220),
  curve: Curves.easeOutCubic,
  width: barWidth * barFill,
  height: 8,
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(999),
    color: accent.withValues(alpha: stale ? 0.25 : 0.85),
  ),
),
                ),
              ),
            ),

            AnimatedCrossFade(
              firstChild: const SizedBox(height: 0),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: details ?? const SizedBox.shrink(),
              ),
              crossFadeState: isOpen ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
            ),
          ],
        ),
      
	  ),
    );
  }
}



class _DeviceDetails extends StatelessWidget {
  final bool connectable;
  final int? txPower;
  final List<Guid> uuids;
  final List<int> manufacturerIds;
  final int lastSeenSeconds;
  final bool isSaved;
  final VoidCallback onToggleSaved;
  
  const _DeviceDetails({
    required this.connectable,
    required this.txPower,
    required this.uuids,
    required this.manufacturerIds,
    required this.lastSeenSeconds,
	required this.isSaved,
    required this.onToggleSaved,
  });

  @override
  Widget build(BuildContext context) {
    Widget kv(String k, String v) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            SizedBox(
              width: 115,
              child: Text(
                k,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Expanded(
              child: Text(
                v,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: 12.6,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.black.withValues(alpha: 0.20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          kv("Connectable", connectable ? "Yes" : "No"),
          kv("Tx Power", "${txPower ?? 'N/A'}"),
          kv("Service UUIDs", uuids.isEmpty ? "—" : uuids.join(", ")),
          kv("Manufacturer", manufacturerIds.isEmpty ? "—" : manufacturerIds.join(", ")),
          kv("Last seen", "${lastSeenSeconds}s ago"),
		  const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onToggleSaved,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.white.withValues(alpha: 0.06),
              ),
              child: Row(
                children: [
                  Icon(
                    isSaved ? Icons.star : Icons.star_border,
                    size: 18,
                    color: isSaved ? const Color(0xFFFFD166) : Colors.white.withValues(alpha: 0.75),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isSaved ? "Saved (tap to remove)" : "Save this device",
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12.8,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "Tap: Find Mode • Long-press: pin & details",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.42),
              fontSize: 11.3,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayCard extends StatelessWidget {
  final Widget child;

  const _PlayCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.07),
            Colors.white.withValues(alpha: 0.03),
          ],
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 16)),
        ],
      ),
      child: child,
    );
  }
}

class _IconPill extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _IconPill({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: Colors.white.withValues(alpha: 0.06),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}

class _PressableScale extends StatefulWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _PressableScale({
    required this.child,
    required this.borderRadius,
    this.onTap,
	this.onLongPress,
  });

  @override
  State<_PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<_PressableScale> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.985 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: widget.onTap,
		  onLongPress: widget.onLongPress,
          onTapDown: (_) => _setPressed(true),
          onTapCancel: () => _setPressed(false),
          onTapUp: (_) => _setPressed(false),
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return Colors.white.withValues(alpha: 0.06);
            }
            if (states.contains(WidgetState.hovered)) {
              return Colors.white.withValues(alpha: 0.03);
            }
            return null;
          }),
          child: widget.child,
        ),
      ),
    );
  }
}

// ===================== RADAR PAINTER (MINIMAL) =====================
// As requested:
// - No static rings
// - No crosshair
// - No outer circle
// - Pulse ring stays
// - Sweep stays VERY faint (alpha 0.05)

class _FullScreenRadarPainter extends CustomPainter {
  final double sweepT; // 0..1
  final double pulseT; // 0..1

  _FullScreenRadarPainter({required this.sweepT, required this.pulseT});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width * 0.5, size.height * 0.42);
    final r = math.min(size.width, size.height) * 0.62;

    const base = Color(0xFF35D0FF);

    // subtle fog
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.05),
    );

    // pulse ring (moving circle)
    final p = (pulseT % 1.0);
    final pulseRadius = r * (0.15 + 0.95 * p);
    final pulseOpacity = (1.0 - p) * 0.18;

    final pulsePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = base.withValues(alpha: pulseOpacity);

    canvas.drawCircle(c, pulseRadius, pulsePaint);

    // sweep sector (very faint)
    final startAngle = (sweepT * 2 * math.pi) - math.pi / 2;
    const sweepAngle = math.pi / 3.4;

    final rect = Rect.fromCircle(center: c, radius: r);

    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          base.withValues(alpha: 0.00),
          base.withValues(alpha: 0.05),
          base.withValues(alpha: 0.00),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect)
      ..style = PaintingStyle.fill;

    canvas.drawArc(rect, startAngle, sweepAngle, true, sweepPaint);

    // center dot
    final dotPaint = Paint()..color = base.withValues(alpha: 0.22);
    canvas.drawCircle(c, 3.0, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _FullScreenRadarPainter oldDelegate) {
    return oldDelegate.sweepT != sweepT || oldDelegate.pulseT != pulseT;
  }
}
