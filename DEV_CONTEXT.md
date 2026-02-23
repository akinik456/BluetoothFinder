# Find Lost Gadget (BLF) – Dev Context

## Project Identity
- App Name: Find Lost Gadget
- Flutter BLE scanning app
- Android target: Android 12+
- Single-file architecture (lib/main.dart)

---

## Core Purpose
Help user find their own Bluetooth device
(earbuds, watch, tablet, etc.)

NOT a generic BLE scanner.
UX goal: clean, focused, modern.

---

## Current Architecture

### BLE
- flutter_blue_plus
- lowLatency mode
- continuousUpdates: true
- continuousDivisor: 1

### Device List (Home)
- EMA RSSI smoothing (alpha ≈ 0.25)
- If a card is open:
  - Pin to top
  - Disable re-sorting
- Stale devices fade & show OUT OF RANGE
- Drop device after long timeout

---

## Find Mode

### Visual
- Playful modern UI
- Ambient radar background
  - No static rings
  - No crosshair
  - No outer circle
  - Pulse ring active
  - Sweep alpha ≈ 0.05

### Audio
- audioplayers
- asset: assets/beep.mp3
- Beep only when device actively seen
- Global mute (ValueNotifier<bool>)

### RSSI Processing
- EMA smoothing
- Logarithmic mapping:
  - progress = log curve (k ≈ 9.0)
  - interval: 1100ms → 90ms
  - volume: 0.15 → 1.0

---

## Auto Calibration (Important)

### Goal
Best-so-far calibration per device.

If a better (closer) RSSI is observed:
→ Update reference.
If worse:
→ Do NOT downgrade reference.

### Config
- minRssi = -85
- calibration window ≈ 2000ms
- margin ≈ +6dB
- max clamp: -45 .. -30
- cache: calibratedMaxById[deviceId]

### UX Intent
Once device seen very close (e.g. -30),
that becomes permanent reference
unless an even better value is seen.

---

## Design Philosophy
- No "DOS style" borders
- Section separation via tone & depth
- Playful but premium
- Clean scanning experience

---

## Known Tunables
- EMA alpha
- log curve k
- calibration margin
- interval range
- volume range

---

## Next Phase (To Decide)
- Filtering strategy for noisy environments
- Performance optimization
- Store preparation
- Advanced distance modeling