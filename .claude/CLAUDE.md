# Call Recorder

Ugur's personal tool for recording his own calls on the Mac (Zoom, Telegram, WhatsApp desktop, iPhone calls through Continuity), transcribing them locally and getting a Claude summary. Personal use only, not a product.

## Plan (approved 2026-11-21)

1. Recorder - Swift menu bar app, two tracks: `me.wav` (mic) and `them.wav` (Mac output). DONE; handles AirPods and output device switches mid-call.
2. Transcript - DONE (2026-11-21): `recorder/Resources/process_call.py` runs after every call: whisper.cpp `ggml-large-v3-turbo-q5_0` (in `~/.cache/whisper.cpp`, faster than full large-v3 with near-equal Russian quality) with Silero VAD, Russian, merged "Я / Собеседник" `transcript.txt` + `transcript.srt`.
3. Summary - DONE (2026-11-21): `claude -p` (Ugur's subscription, no API key) writes `summary.md` in Russian with 4 parts: short summary, decisions and action items, key quotes with timestamps, follow-up message draft. The tool never sends anything. Runs as `claude -p --tools "" --strict-mcp-config --no-session-persistence`.
4. Polish - rename a call, recent calls list, optional delete audio after transcription.

## Decisions

- Start/stop is manual: menu bar button or Control+Option+Command+R. No auto-detect in v1.
- System audio uses a Core Audio process tap (`CATapDescription`), not ScreenCaptureKit or BlackHole. Checked with REA on Granola 7.786.3: it enables Chromium's `MacCatapSystemAudioLoopbackCapture` (Core Audio tap) with ScreenCaptureKit only as fallback, and asks for `NSAudioCaptureUsageDescription`.
- Mic uses Apple voice processing (echo cancellation) by default, toggle in the menu; falls back to plain mic if it fails. Granola also records mic with echoCancellation on.
- It is a normal Dock app (2026-11-21, Ugur: "I wanna see it as actual application"): Dock icon, a white/blue window (record button, timer, recent calls, settings), plus the menu bar item and hotkey. At login it starts quietly without the window.
- App icon: white squircle with a blue #1150F4 record dot and sound wave, made with Codex. Source and .icns in `ugur-studio/4-personal/graphics/app-icons/`, copy in `recorder/Resources/AppIcon.icns`. Ugur's style is white background with blue, not dark green.
- Native Swift instead of the default web stack: Mac audio capture needs native code; no web UI or database in v1.
- Recordings: `~/Documents/ugur-ai/ugur-studio/4-personal/calls/<YYYY-MM-DD HH-mm-ss>/` (override: `defaults write com.ugur.callrecorder recordingsRoot <path>`). Never committed.
- Ideas from Granola for later: FluidAudio (on-device CoreML diarization) to split "them" into several speakers in group calls; mic-in-use detection for auto-start.

## Build

`./build.sh install` - builds, signs with Ugur's Apple Development identity, copies to `/Applications/Call Recorder.app` (removes the old `~/Applications` copy) and launches it. The app opens at every login (menu switch "Open at login"). `./build.sh run` only runs the build/ copy for quick tests.
