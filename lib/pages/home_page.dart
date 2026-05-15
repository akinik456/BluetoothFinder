import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:bluetoothfinder/core/scan_watchdog.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_settings.dart';
import '../services/storage_service.dart';
import '../models/device_model.dart';
import '../widgets/radar_painter.dart';
import '../widgets/custom_components.dart';
import '../services/audio_service.dart';

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
	
	StreamSubscription<List<PurchaseDetails>>? _purchaseSub;
	bool _isPremium = false;
	bool _trialActive = false;
	bool get _hasFullAccess => _isPremium || _trialActive;
	int _trialDaysLeft = 0;
	
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
	StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
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
	String _appVersion = '';

@override
  void initState() {
    super.initState();
		_purchaseSub = InAppPurchase.instance.purchaseStream.listen((purchases) async {
	for (final purchase in purchases) {
    //print("PURCHASE STATUS: ${purchase.status}");

    if (purchase.status == PurchaseStatus.purchased ||
        purchase.status == PurchaseStatus.restored) {
				await PremiumStore.setPremium(true);
      //print("PURCHASE OK: ${purchase.productID}");
			
			if (mounted) {
				setState(() {
					_isPremium = true;
				});
			}
			
    }

    if (purchase.pendingCompletePurchase) {
      await InAppPurchase.instance.completePurchase(purchase);
    }
  }
});

unawaited(_restorePurchases());
		
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
		if (_isPremium) {
  _watchdog.markSeen();
}

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
		
		_adapterStateSub = FlutterBluePlus.adapterState.listen((state) async {
  if (!mounted) return;

  if (state == BluetoothAdapterState.on) {
    // Bluetooth geri açıldı → gerçek durumu tekrar al
    final scanning = FlutterBluePlus.isScanningNow;
    setState(() => isScanning = scanning);
  } else {
    // Bluetooth kapandı → UI'ı stop konumuna çek
    setState(() => isScanning = false);
  }
});

    _tick = Timer.periodic(const Duration(milliseconds: 700), (_) {
      if (!mounted) return;
      if (!isScanning) return;
      setState(() {});
    });
	
  unawaited(_loadSaved());	
	unawaited(_initTrial());
	unawaited(_loadVersion());
	unawaited(_checkForUpdate());
  
  // Play Store kuralı: Açılışta bilgilendirip izin iste
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissions();
    });
	_watchdog = ScanWatchdog(
  stallThreshold: const Duration(seconds: 20),
  onRecover: () async {
    if (!_hasFullAccess) return;

    print("WATCHDOG: recovery start");
    await _stopScan();
    await Future.delayed(const Duration(milliseconds: 2000));
    await _startScan();
    print("WATCHDOG: recovery done");
  },
);
Future.delayed(const Duration(seconds: 1), () {
  if (mounted) setState(() {});
});
  }
Future<void> _initTrial() async {
  final prefs = await SharedPreferences.getInstance();

  const key = 'trialStartMs';
  final now = DateTime.now().millisecondsSinceEpoch;

  int start = prefs.getInt(key) ?? 0;

  if (start == 0) {
    start = now;
    await prefs.setInt(key, start);
  }

  const trialDurationMs = 7 * 24 * 60 * 60 * 1000;//15 * 24 * 60 * 60 * 1000; // 15 gün

  final active = (now - start) < trialDurationMs;
	final remainingMs = trialDurationMs - (now - start);
  final daysLeft = (remainingMs / (24 * 60 * 60 * 1000)).ceil();
	
  if (!mounted) return;
  setState(() {
    _trialActive = active;
		_trialDaysLeft = active ? daysLeft : 0;
  });
}	

Future<void> _checkForUpdate() async {
  try {
    final info = await InAppUpdate.checkForUpdate();

    if (!mounted) return;

    if (info.updateAvailability == UpdateAvailability.updateAvailable &&
        info.flexibleUpdateAllowed) {
      _showUpdateDialog();
    }
  } catch (_) {
    // Debug APK, sideload veya Play Store dışı kurulumda hata verebilir.
    // Sessiz geçiyoruz.
  }
}
void _showUpdateDialog() {
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return AlertDialog(
        title: const Text("Update Available"),
        content: const Text(
          "A new version is available. Update now for the best experience.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("LATER"),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await InAppUpdate.startFlexibleUpdate();
                await InAppUpdate.completeFlexibleUpdate();
              } catch (_) {}
            },
            child: const Text("UPDATE"),
          ),
        ],
      );
    },
  );
}
Future<void> _loadVersion() async {
  final info = await PackageInfo.fromPlatform();

  if (!mounted) return;
  setState(() {
    _appVersion = "${info.version}+${info.buildNumber}";
  });
}	
  
  Future<void> _checkStatus() async {
  final cached = await PremiumStore.getPremium();
	if (cached && mounted) {
		setState(() {
			_isPremium = true;
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
		_purchaseSub?.cancel();
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
    //print("İzinler zaten tam, diyalog tetiklenmiyor.");
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
	final deviceInfo = DeviceInfoPlugin();
	final androidInfo = await deviceInfo.androidInfo;
	final sdk = androidInfo.version.sdkInt;
	if (sdk <= 30) {
		final serviceEnabled = await Permission.location.serviceStatus.isEnabled;
		if (!serviceEnabled) {
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(
					content: Text("Konum servisini açmadan tarama yapılamaz"),
				),
			);
			return;
		}
	}	
		if (_hasFullAccess) {
		_watchdog.resetSession();
		_watchdog.start();
	}
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
		await FlutterBluePlus.stopScan();
		await Future.delayed(const Duration(milliseconds: 300));
		await FlutterBluePlus.startScan(
			continuousUpdates: true,
			continuousDivisor: 1,
			androidScanMode: AndroidScanMode.lowLatency,
		);		
		Future.delayed(const Duration(seconds: 15), () async {
			if (isScanning && !_hasFullAccess) {
			await _stopScan();
			}
		});
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

		final sortedIds = visibleResults.keys.toList();

if (_expandedId == null) {
  sortedIds.sort((a, b) {
    final aSaved = _saved.containsKey(a);
    final bSaved = _saved.containsKey(b);

    // 1 Saved üstte
    if (aSaved != bSaved) {
      return aSaved ? -1 : 1;
    }

    // 2 RSSI varsa güçlü olan üste
    final aRssi = visibleResults[a]?.rssi ?? -999;
    final bRssi = visibleResults[b]?.rssi ?? -999;

    return bRssi.compareTo(aRssi);
  });
}

final savedIds = sortedIds.where((id) => _saved.containsKey(id)).toList();
final nearbyIds = sortedIds.where((id) => !_saved.containsKey(id)).toList();
final limitedNearbyIds = _hasFullAccess
    ? nearbyIds
    : nearbyIds.take(2).toList();
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
																for (final id in limitedNearbyIds)
																	_buildDeviceCard(id, visibleResults[id], now),
															],
														],
													),
									),
								),
								Padding(
									padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
									child: Container(
										padding: const EdgeInsets.all(14),
										decoration: BoxDecoration(
											color: Colors.white.withValues(alpha: 0.08),
											borderRadius: BorderRadius.circular(18),
											border: Border.all(
												color: Colors.white.withValues(alpha: 0.12),
											),
											
										),
										child: Row(
  children: [
    Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isPremium
                ? "Premium active • unlimited scan and devices"
                : (_trialActive
                    ? "Free trial • unlimited scan and devices • $_trialDaysLeft days left"
                    : "Free mode • limited scan and devices"),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 2),

          Row(
            children: [
              if (_appVersion.isNotEmpty)
                Text(
                  "Version $_appVersion",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),

              const SizedBox(width: 10),

              InkWell(
                onTap: () {
                  openFeedbackMenu();
                },
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 13,
                        color: const Color(0xFF8FD8FF).withOpacity(0.50),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        "Feedback",
                        style: TextStyle(
                          color: const Color(0xFF8FD8FF).withOpacity(0.50),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),

    const SizedBox(width: 12),

    if (!_isPremium)
      ElevatedButton(
        onPressed: _buy,
        child: const Text("Go Premium"),
      ),
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
	
	Future<void> _testIap() async {
		final bool available = await InAppPurchase.instance.isAvailable();
		//print("IAP available: $available");

		const ids = <String>{'premium_unlock'};
		final response = await InAppPurchase.instance.queryProductDetails(ids);

		//print("Found products: ${response.productDetails.length}");
		for (var p in response.productDetails) {
			//print("Product: ${p.id} - ${p.price}");
		}

		if (response.notFoundIDs.isNotEmpty) {
			//print("Not found: ${response.notFoundIDs}");
		}
	}	

	Future<void> _buy() async {
		const ids = <String>{'premium_unlock'};
		final response = await InAppPurchase.instance.queryProductDetails(ids);

		if (response.productDetails.isEmpty) {
			//print("Product not found");
			return;
		}

		final product = response.productDetails.first;

		final purchaseParam = PurchaseParam(productDetails: product);

		await InAppPurchase.instance.buyNonConsumable(
			purchaseParam: purchaseParam,
		);
	}
	Future<void> _restorePurchases() async {
  await InAppPurchase.instance.restorePurchases();
	}
	
void openFeedbackMenu() {
  showModalBottomSheet(
    context: context,
    backgroundColor: const Color(0xFF111827),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(24),
      ),
    ),
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _FeedbackItem(
                icon: Icons.star_rounded,
                title: "Rate on Play Store",
                onTap: () async {
  Navigator.pop(context);

  final Uri url = Uri.parse(
    //"https://play.google.com/store/apps/details?id=com.akinik.findlostgadget",
		
		"https://play.google.com/store/apps/details?id=com.akinik.findlostgadget.app&pli=1",
  );

  await launchUrl(
    url,
    mode: LaunchMode.externalApplication,
  );
},
              ),

              const SizedBox(height: 12),

              _FeedbackItem(
                icon: Icons.mail_outline_rounded,
                title: "Send Feedback",
                onTap: () async {
                  Navigator.pop(context);
                  openFeedback();
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}
	
Future<void> openFeedback() async {
	String _appVersion = '';
	final infoapp = await PackageInfo.fromPlatform();
	_appVersion = "${infoapp.version}+${infoapp.buildNumber}";
	
  final info = await DeviceInfoPlugin().androidInfo;


  final body = '''
Message:

---

App version: $_appVersion
Android: ${info.version.release}
Device: ${info.manufacturer} ${info.model}
''';

  final uri = Uri(
    scheme: 'mailto',
    path: 'lynra.dev@gmail.com',
    queryParameters: {
      'subject': 'Lynra FindLostGadget Feedback',
      'body': body,
    },
  );

  await launchUrl(uri);
}	
	
}

class _FeedbackItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _FeedbackItem({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Colors.white.withOpacity(0.08),
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: const Color(0xFF8FD8FF).withOpacity(0.85),
              size: 22,
            ),
            const SizedBox(width: 14),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}