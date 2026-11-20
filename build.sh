#!/bin/bash
# Builds build/CallRecorder.app. Usage: ./build.sh [run|install]
# install copies it to /Applications and launches it; the app then opens at every login.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --package-path recorder

APP=build/CallRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp recorder/.build/release/CallRecorder "$APP/Contents/MacOS/"
cp recorder/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp recorder/Resources/AppIcon.icns recorder/Resources/process_call.py "$APP/Contents/Resources/"

# A real signing identity keeps macOS permissions across rebuilds; ad-hoc works but may re-ask.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}' || true)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $(pwd)/$APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "run" ]]; then
  pkill -x CallRecorder 2>/dev/null || true
  open "$APP"
elif [[ "${1:-}" == "install" ]]; then
  pkill -x CallRecorder 2>/dev/null || true
  # Older versions lived in ~/Applications; keep a single copy.
  rm -rf "$HOME/Applications/CallRecorder.app"
  rm -rf "/Applications/Call Recorder.app"
  cp -R "$APP" "/Applications/Call Recorder.app"
  open "/Applications/Call Recorder.app"
  echo "Installed /Applications/Call Recorder.app"
fi
