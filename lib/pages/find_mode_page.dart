import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

import '../core/app_settings.dart';
import '../services/audio_service.dart';
import '../services/trial_service.dart';
import '../widgets/radar_painter.dart';
import '../widgets/custom_components.dart';


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
bool _isExpired = false; 

  @override
  void initState() {
    super.initState();
	_checkStatus();
WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now().millisecondsSinceEpoch;

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
  final now = DateTime.now().millisecondsSinceEpoch;
  
  for (final r in results) {
  print("SCAN -> ${r.device.remoteId.str} | target=${widget.deviceId}");
    final id = r.device.remoteId.str;
    if (id != widget.deviceId) continue;

    // EMA smoothing
    const double alpha = 0.25;
    final raw = r.rssi.toDouble();
    _ema = (_ema == null) ? raw : (alpha * raw) + ((1 - alpha) * _ema!);

    _rssi = _ema!.round();
    _lastSeenMs = now;

    // Session info (UI heartbeat)
              
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
      if (!mounted) return;

      final now = DateTime.now().millisecondsSinceEpoch;
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
  
Future<void> _checkStatus() async {
  // Veri gelene kadar bekler (await)
  final expired = await TrialService.isExpired(); 
  
  if (mounted) { // Widget hala ekrandaysa güncelle
    setState(() {
      _isExpired = expired;
    });
  }
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
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
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
        // 1. KATMAN: Playful background (Gradient)
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

        // 2. KATMAN: ARKA PLAN LOGOSU (Efsane dokunuş burası)
        Positioned.fill(
          child: IgnorePointer(
            child: Center(
              child: Opacity(
                opacity: 0.07, // Radar çizgileriyle karışmaması için ideal seviye
                child: Image.asset(
                  'assets/app_icon.png',
                  width: MediaQuery.of(context).size.width * 0.82,
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),

        // 3. KATMAN: Ambient radar
        // Logonun üstünde dönerek "tarama" efekti verecek
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_sweepCtrl, _pulseCtrl]),
              builder: (_, __) {
                return CustomPaint(
                  painter: FullScreenRadarPainter(
                    sweepT: _sweepCtrl.value,
                    pulseT: _pulseCtrl.value,
                  ),
                );
              },
            ),
          ),
        ),

        // 4. KATMAN: Asıl UI İçeriği
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              children: [
                // Header (Geri butonu, cihaz adı, ses butonu)
                Row(
                  children: [
                    IconPill(
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
                        return IconPill(
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

                // Main playful card (RSSI ve Mesafe bilgisi)
                PlayCard(
                  child: Column(
                    children: [
                      // ... (Mevcut PlayCard içeriğin aynen kalıyor) ...
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
                      // ... (Geri kalan bar ve saniye bilgileri) ...
                      Row(
                        children: [
                          Text("$_minRssi", style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11, fontWeight: FontWeight.w700)),
                          const Spacer(),
                          Text("$_calMaxRssi", style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11, fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: double.infinity,
                        height: 18,
                        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: Colors.white.withValues(alpha: 0.08)),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            width: (MediaQuery.of(context).size.width - 64) * fill, // Paddingleri hesaba katarak
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), color: color),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        show ? "Last seen: ${(ageMs / 1000).toStringAsFixed(1)}s" : "Waiting for signal…",
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.55), fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                ValueListenableBuilder<bool>(
                  valueListenable: globalMute,
                  builder: (_, muted, __) {
                    return Text(
                      muted ? "Muted" : "Beep gets faster & louder as you get closer",
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

class PaywallOverlay extends StatelessWidget {
  final VoidCallback onPurchase;

  const PaywallOverlay({super.key, required this.onPurchase});

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
                onPressed: onPurchase,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF007AFF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 35, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  elevation: 10,
                ),
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
