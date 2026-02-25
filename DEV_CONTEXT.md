# BluetoothFinder – DEV_CONTEXT.md

## Current Stable Base
Branch: feature/playful-ui-log-beep  
Audio: main_audio_fixed2 tabanlı stabil sürüm  
Beep: WAV sonar pulse (B version)  
Beep engine: seek + resume, no play reset  
Lifecycle: Home + Lock → Hard stop (0 trailing beep)

## Product Identity
App type: Personal Device Finder (NOT generic BLE scanner)

Core Philosophy:
- User tracks their own gadgets
- Saved devices are persistent
- Clean, minimal, playful UI
- No background scanning
- Scan only when user presses Start

## UX Rules
- Tap → Toggle details
- Long press → Enter Find Mode
- Saved devices pinned to top
- Saved devices remain in list even if out of range
- 12s stale threshold

## Audio Rules
- Short sonar pulse (≈50ms WAV)
- No overlapping pulses
- No MP3
- Deterministic playback
- Hard stop on lifecycle change

## Tech Stack
- Flutter
- flutter_blue_plus
- shared_preferences
- Single main.dart architecture
- No over-engineering

## Non-Negotiables
- Beep must never randomly break again
- Lifecycle must always hard-stop scan + audio
- No silent refactor without confirmation
- User must explicitly approve structural changes

## Current Goal
Rebuild save system on top of audio-stable base
Step-by-step
No large rewrites
Compile-safe after each step