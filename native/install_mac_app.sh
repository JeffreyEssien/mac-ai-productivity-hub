#!/bin/bash
# Builds the native AppKit macOS hub using Apple Command Line Tools.
# No SwiftUI macros or full Xcode required. Does not alter launchd jobs or reminders.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/Mac AI Productivity Hub.app"
if [[ "$(uname -s)" != "Darwin" ]]; then echo "Run on macOS." >&2; exit 1; fi
if [[ "$(uname -m)" != "arm64" ]]; then echo "Apple Silicon (arm64) is required." >&2; exit 1; fi
SWIFTC="$(xcrun --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
if [[ ! -d "$SDK" ]]; then echo "Missing macOS SDK; check Command Line Tools." >&2; exit 1; fi
mkdir -p "$HOME/Applications"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Mac AI Productivity Hub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Backend"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
echo "Using Swift: $SWIFTC"
echo "Using SDK: $SDK"
echo "Compiling AppKit (no SwiftUI/macros)…"
"$SWIFTC" -O -parse-as-library -sdk "$SDK" -target arm64-apple-macosx14.0 \
  -framework Foundation -framework AppKit -framework EventKit \
  "$ROOT/native/AppKit/MacAIHub.swift" \
  -o "$APP/Contents/MacOS/MacAIHub"
for f in ai_hub.py storage_manager.py productivity_manager.py performance_monitor.py hub_services.py hub_config.json config.json productivity_config.json; do
  [[ -f "$ROOT/$f" ]] && cp "$ROOT/$f" "$APP/Contents/Resources/Backend/$f"
done
chmod 755 "$APP/Contents/MacOS/MacAIHub"
codesign --force --sign "${MAC_HUB_SIGN_IDENTITY:--}" "$APP"
codesign --verify "$APP"
if [[ -d "$DEST" ]]; then
  OLD="$HOME/Applications/Mac AI Productivity Hub.backup.$(date +%Y%m%d%H%M%S).app"
  mv "$DEST" "$OLD"
  echo "Backed up previous app: $OLD"
fi
mv "$APP" "$DEST"
echo "Installed: $DEST"
echo "Launch with: open \"$DEST\""
echo "Allow Reminders access when requested. Previous iPhone Shortcuts and launchd jobs are unchanged."
