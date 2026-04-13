import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bluetoothfinder/core/scan_watchdog.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../core/app_settings.dart';
import '../services/storage_service.dart';
import '../models/device_model.dart';
import '../widgets/radar_painter.dart';
import '../widgets/custom_components.dart';
import '../services/audio_service.dart';
import '../services/trial_service.dart';
import '../services/revenue_cat_service.dart';

import 'find_mode_page.dart';

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
  late final ScanWatchdog _watchdog;

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
  
  bool _isExpired = false;
  
  Map<String, SavedDevice> _saved = {};  

  final Set<String> _seenThisSession = <String>{};

@override
  void initState() {
    super.initState();
	_checkStatus();
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
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final r in results) {
        final id = r.device.remoteId.str;


        _seenThisSession.add(id);
        _latest[id] = r;
        _lastSeenMs[id] = now;
		_watchdog.markSeen();

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
  
  // Play Store kuralı: Açılışta bilgilendirip izin iste
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissions();
    });
	_watchdog = ScanWatchdog(
  onRecover: () async {
    print("WATCHDOG: recovery start");
    await _stopScan();
    await Future.delayed(const Duration(milliseconds: 800));
    await _startScan();
    print("WATCHDOG: recovery done");
  },
);
  }
  
  Future<void> _checkStatus() async {
  // Veri gelene kadar bekler (await)
  final expired = await TrialService.isExpired(); 
  
  if (mounted) { // Widget hala ekrandaysa güncelle
    setState(() {
      _isExpired = expired;
		if(_isExpired) _toggleScan();
    });
  }
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
	_watchdog.dispose();
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
      ? DeviceDetails(
          connectable: adv?.connectable ?? false,
          txPower: adv?.txPowerLevel,
          uuids: adv?.serviceUuids ?? const [],
          manufacturerIds: adv?.manufacturerData.keys.toList() ?? const [],
          lastSeenSeconds: lastSeenSeconds,
          isSaved: isSaved,
          onToggleSaved: () => _toggleSaved(id: id, name: title),
        )
      : null;

  return DeviceCardPlayful(
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
  
Future<void> _requestPermissions() async {
  // 1. ADIM: Önce mevcut duruma bak (Bu işlem kullanıcıya diyalog göstermez)
  var bluetoothStatus = await Permission.bluetoothScan.status;
  var locationStatus = await Permission.location.status;

  // 2. ADIM: Eğer her iki izin de zaten verilmişse (granted), fonksiyonu burada bitir
  if (bluetoothStatus.isGranted && locationStatus.isGranted) {
    print("İzinler zaten tam, diyalog tetiklenmiyor.");
    return; 
  }

  // 3. ADIM: Eğer izinler eksikse, o meşhur bilgilendirme diyaloğunu göster
  if (!mounted) return;

    // 1. Önce kullanıcıya "Neden" istediğimizi açıklıyoruz
    bool? proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A), // Senin koyu teman
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Permissions Required", style: TextStyle(color: Colors.white)),
        content: const Text(
          "To scan for nearby Bluetooth devices and estimate their distance, "
        "this app requires Bluetooth and Location permissions. "
        "\n\nNote: Your location data is never collected or shared.",
        style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("GRANT PERMISSIONS", style: TextStyle(color: Color(0xFF35D0FF))),
          ),
        ],
      ),
    );

    if (proceed != true) return;

    // 2. Şimdi gerçek sistem izinlerini istiyoruz
    // Android 9-11 için Location, Android 12+ için Scan ve Connect gerekir.
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    // 3. İzin verildiyse taramayı başlat
    if (statuses[Permission.bluetoothScan]?.isGranted ?? false) {
      _startScan();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Taramayı başlatmak için izinleri onaylamalısınız.")),
        );
      }
    }
  }  

  Future<void> _startScan() async {
  _watchdog.resetSession();
_watchdog.start();
  BeepGuard.arm();
    await _ensurePermissions();
	if (!mounted) return;

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

    await FlutterBluePlus.startScan(
      continuousUpdates: true,
      continuousDivisor: 1,
      androidScanMode: AndroidScanMode.lowLatency,
    );
  }

  Future<void> _stopScan() async {
  _watchdog.stop();
  BeepGuard.killNow();
    await FlutterBluePlus.stopScan();
  }

  Future<void> _toggleScan() async {
  // Taramaya başlamadan hemen önce kontrol et
  if (await Permission.location.isDenied) {
    // Eğer kullanıcı sonradan iptal ettiyse tekrar uyar
	_requestPermissions();    return;
  }
  try {
    if (!isScanning) {

      if (!mounted) return;
      
      await _startScan();

    } else {
      await _stopScan();
    }
  } catch (e) {
    if (!mounted) return;
    setState(() => isScanning = false);
    if (_sweepCtrl.isAnimating) _sweepCtrl.stop();
    if (_pulseCtrl.isAnimating) _pulseCtrl.stop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text("$e")));
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
final now = DateTime.now().millisecondsSinceEpoch;
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
      // 1. KATMAN: Arka Plan Gradient
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

      // 2. KATMAN: App Icon (Logo) Arka Planı
      // Radar efektinin hemen arkasında, çok hafif şeffaflıkla
      Positioned.fill(
        child: Center(
          child: Opacity(
  // 0.05 - 0.20 arası senin ekranına göre ayarla
  // 0.15 genellikle "premium" bir derinlik verir
  opacity: 0.15, 
  child: Image.asset(
    'assets/app_icon.png',
    // Ekranın %85'ini kaplasın ki heybetli dursun
    width: MediaQuery.of(context).size.width * 0.85,
    fit: BoxFit.contain,
    // RENK FİLTRESİNİ SİLDİK, ARTIK SAF HALİYLE GELİYOR
  ),
),
        ),
      ),

      // 3. KATMAN: Ambient radar background while scanning
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: isScanning ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: AnimatedBuilder(
              animation: Listenable.merge([_sweepCtrl, _pulseCtrl]),
              builder: (context, _) {
                return CustomPaint(
                  painter: FullScreenRadarPainter(
                    sweepT: _sweepCtrl.value,
                    pulseT: _pulseCtrl.value,
                    label: '', // Boş label
                  ),
                );
              },
            ),
          ),
        ),
      ),

      // 4. KATMAN: Ana İçerik
      SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: HeaderPlayful(
                isScanning: isScanning,
                deviceCount: visibleResults.length,
              ),
            ),

            // Scan Button Panel
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ScanPanelPlayful(
                isScanning: isScanning,
                onToggle: _toggleScan,
              ),
            ),
            
            const SizedBox(height: 6),

            // Info Row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Tap for details", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Text("•", style: TextStyle(color: Colors.white.withValues(alpha: 0.35))),
                  const SizedBox(width: 8),
                  const Text("Hold to find", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              ),
            ),

            const SizedBox(height: 6),

            // Device List
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: visibleResults.isEmpty
                    ? EmptyStatePlayful(isScanning: isScanning)
                    : ListView(
                        padding: const EdgeInsets.only(top: 6, bottom: 10),
                        children: [
                          if (savedIds.isNotEmpty) ...[
                            const SectionHeader(title: "SAVED"),
                            for (final id in savedIds)
                              _buildDeviceCard(id, visibleResults[id], now),
                          ],
                          if (nearbyIds.isNotEmpty) ...[
                            const SectionHeader(title: "NEARBY"),
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
	if (_isExpired)
      PaywallOverlay(
        onPurchase: () {
          // Ödeme tetiklenecek
          print("Initiating Purchase: \$1.99");
        },
      ),  
	  
    ],
  ),
);

  }
}

// 'const' kelimesini sildik
class PaywallOverlay extends StatelessWidget {
  final VoidCallback onPurchase; // Bu zaten varmış

  PaywallOverlay({super.key, required this.onPurchase}); // const kaldırıldı

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: BackdropFilter(
        // Arkayı tam kıvamında bulandırıyoruz (Rakamlar okunmasın ama hareket görünsün)
        filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
        child: Container(
          color: const Color(0xFF081018).withOpacity(0.88), // Senin o derin koyu tonun
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Ghost Logo (Kilit ikonuyla desteklenmiş)
              Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: 0.1,
                    child: Image.asset('assets/app_icon.png', width: 200),
                  ),
                  const Icon(Icons.lock_outline, color: Colors.white24, size: 80),
                ],
              ),
              const SizedBox(height: 30),
              const Text(
                "TRIAL EXPIRED",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 50, vertical: 15),
                child: Text(
                  "Trial Period Ended. Unlock lifetime access to keep tracking and finding your devices without limits.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                ),
              ),
              const SizedBox(height: 25),
              // O meşhur 1.99$ Butonu
              ElevatedButton(
				  style: ElevatedButton.styleFrom(
					padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
				  ),
				  // home_page.dart içindeki o butonu bul ve onPressed kısmını şöyle güncelle:
onPressed: () async {
  try {
    print("Satın alma başlatılıyor...");
    Offerings offerings = await Purchases.getOfferings();
    
    Package? packageToBuy;

    // 1. Önce 'current' içindeki paketi dene
    if (offerings.current != null && offerings.current!.availablePackages.isNotEmpty) {
      packageToBuy = offerings.current!.availablePackages.first;
      print("Current paketi seçildi: ${packageToBuy.identifier}");
    } 
    // 2. Eğer current boşsa, eldeki tüm tekliflerin içine bak (Zorla bulma)
    else if (offerings.all.isNotEmpty) {
      print("Current boş, tüm listeyi tarıyorum...");
      for (var offering in offerings.all.values) {
        if (offering.availablePackages.isNotEmpty) {
          packageToBuy = offering.availablePackages.first;
          print("Alternatif paket bulundu: ${packageToBuy.identifier}");
          break;
        }
      }
    }

    if (packageToBuy != null) {
      print("Google Play penceresi açılıyor...");
      var result = await Purchases.purchasePackage(packageToBuy);
      
      if (result.customerInfo.entitlements.all["pro"]?.isActive ?? false) {
        onPurchase();
        if (context.mounted) Navigator.pop(context);
      }
    } else {
      print("HATA: RevenueCat'te hiçbir paket bulunamadı! Panelden 'Packages' kısmını kontrol et.");
    }
  } catch (e) {
    print("Hata veya İptal: $e");
  }
},
				  child: const Text(
					"Unlock Lifetime Access - \$1.99",
					style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
				  ),
				),
            ],
          ),
        ),
      ),
    );
  }
}