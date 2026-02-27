# BluetoothFinder – DEV CONTEXT

## Current Branch
feature/playful-ui-stable

## Base Commit
59efb67
Saved/Nearby sections + session-aware labels + UI stabilization

## Status
✅ Stable baseline restored
✅ No Watchdog / Freeze Guard present
✅ Beep system stable
✅ Scan lifecycle stable
✅ Saved devices persistent
✅ Saved / Nearby sections active
✅ Session-aware labels working

## IMPORTANT RULES
- DO NOT introduce Watchdog yet
- Freeze Guard will be added ONLY after clean validation phase
- FindModePage and HomePage scan logic must remain isolated
- Beep stability has absolute priority
- No large refactors without commit checkpoint

## Scan Architecture (Current)
HomePage:
- Controls main BLE scan
- Saved device tracking
- DeviceCard rendering
- EMA RSSI smoothing

FindModePage:
- Independent proximity tracking
- Calibration window
- Beep triggering
- NO watchdog logic

## Next Phase
Phase: Stabilization & Test Preparation

Goals:
1. Validate long-running scan stability
2. Confirm lifecycle behavior (home/background/lock)
3. Memory & callback consistency check
4. Prepare controlled Scan Freeze Guard integration

## Development Principle
Small step → Compile → Test → Commit