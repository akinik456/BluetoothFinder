# BluetoothFinder – DEV CONTEXT

## Base
- Branch: feature/playful-ui-log-beep
- Base version: audio-stable (main_audio_fixed2 lineage)
- Beep system is STABLE and must NOT break.

## Core Identity
- App name: Find Lost Gadget
- Playful UI style
- Dark theme (Material3)
- Finder identity preserved
- No unnecessary rewrites

## Current Architecture

### Device Card
- StatelessWidget: _DeviceCardPlayful
- Left accent border when saved
- Bookmark quick-toggle button
- RSSI + distanceLabel fixed width panel
- Playful proximity bar (AnimatedContainer)
- Tap → Details
- Long press → Find mode

### Save System
- Persistent using SharedPreferences
- SavedDevice model
- SavedStore load/save
- Saved devices pinned first in list
- Bookmark icon toggles save state

### UX Rules
- Compile-safe after each step
- No large rewrites
- Minimal layout instability
- Beep must remain untouched

## Next Potential Improvements
- Saved devices persist even when out-of-range
- Subtle typography polish
- RSSI monospace option
- First-run gesture hint fade

## DO NOT TOUCH
- FindModePage audio logic
- Beep timing logic
- Scan lifecycle stability