import 'dart:async';
import 'package:flutter/material.dart';

import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';


import '../core/app_settings.dart';

class SectionHeader extends StatelessWidget {
  final String title;
  const SectionHeader({required this.title});

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

// ===================== PLAYFUL UI COMPONENTS =====================

class HeaderPlayful extends StatelessWidget {
  final bool isScanning;
  final int deviceCount;

  const HeaderPlayful({
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

class ScanPanelPlayful extends StatelessWidget {
  final bool isScanning;
  final FutureOr<void> Function() onToggle;

  const ScanPanelPlayful({
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

class EmptyStatePlayful extends StatelessWidget {
  final bool isScanning;

  const EmptyStatePlayful({required this.isScanning});

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

class DeviceCardPlayful extends StatelessWidget {
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
  
  const DeviceCardPlayful({
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

class DeviceDetails extends StatelessWidget {
  final bool connectable;
  final int? txPower;
  final List<Guid> uuids;
  final List<int> manufacturerIds;
  final int lastSeenSeconds;
  final bool isSaved;
  final VoidCallback onToggleSaved;
  
  const DeviceDetails({
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
            "Tap: pin & details • Long-press: Find Mode ",
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

class PlayCard extends StatelessWidget {
  final Widget child;

  const PlayCard({required this.child});

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

class IconPill extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const IconPill({required this.icon, required this.onTap});

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
